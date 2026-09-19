import Foundation
import Observation
import TidyNestCore
import TidyNestProtocol

struct MaintenanceActions: Sendable {
    let capabilities: @Sendable () async throws -> EngineCapabilities
    let scanClean: @Sendable (@escaping @Sendable (MaintenanceEvent) -> Void) async throws -> MaintenancePlan
    let planUninstall: @Sendable (MoleApplication, @escaping @Sendable (MaintenanceEvent) -> Void) async throws -> MaintenancePlan
    let apply: @Sendable (String, [String], @escaping @Sendable (MaintenanceEvent) -> Void) async throws -> MaintenanceResult
    let history: @Sendable () async throws -> [MaintenanceResult]
    let protections: @Sendable () async throws -> [String]
    let protect: @Sendable (String) async throws -> Void
    let unprotect: @Sendable (String) async throws -> Void
    let forceEnd: @Sendable () -> Void

    static func live() -> Self {
        // 检查和执行共用一个客户端；记录读取独立，取消时不会结束另一边的 Bridge。
        let service = MaintenanceService()
        let historyService = MaintenanceService()
        return Self(
            capabilities: { try await service.capabilities() },
            scanClean: { try await service.scanClean(onEvent: $0) },
            planUninstall: { try await service.planUninstall(application: $0, onEvent: $1) },
            apply: { try await service.apply(planID: $0, selectedItemIDs: $1, onEvent: $2) },
            history: { try await historyService.history() },
            protections: { try await service.protections() },
            protect: { _ = try await service.protect(path: $0) },
            unprotect: { _ = try await service.unprotect(path: $0) },
            forceEnd: { service.forceEndCurrentTask() }
        )
    }
}

enum MaintenancePhase: Equatable {
    case idle, scanning, ready, applying, cancelling, finished, cancelled
    case failed(String)
}

struct MaintenanceConfirmation: Identifiable {
    let id = UUID()
    let planID: String
    let title: String
    let items: [MaintenanceItem]
    var itemIDs: [String] { items.map(\.itemID) }
}

@MainActor @Observable
final class MaintenanceModel {
    private(set) var phase: MaintenancePhase = .idle
    private(set) var plan: MaintenancePlan?
    private(set) var plannedApplication: MoleApplication?
    private(set) var planExpired = false
    private(set) var selectedItemIDs: Set<String> = []
    private(set) var confirmation: MaintenanceConfirmation?
    private(set) var result: MaintenanceResult?
    private(set) var itemResults: [MaintenanceItemResult] = []
    private(set) var executionUncertain = false
    private(set) var progressMessage = ""
    private(set) var engineCapabilities: EngineCapabilities?
    private(set) var history: [MaintenanceResult] = []
    private(set) var historyPhase: QueryPhase = .idle
    private(set) var protectedPaths: [String] = []
    private(set) var protectionsPhase: QueryPhase = .idle
    private(set) var notice: String?
    var searchText = ""
    var focusedItemID: String?
    @ObservationIgnored var canStartRequest: @MainActor () -> Bool = { true }
    @ObservationIgnored var canScanConcurrently: @MainActor () -> Bool = { false }
    @ObservationIgnored var beforeRequest: @MainActor () async -> Void = {}
    @ObservationIgnored var onApplicationsTrashed: @MainActor (Set<String>) -> Void = { _ in }
    @ObservationIgnored private let actions: MaintenanceActions
    @ObservationIgnored private var operation: Task<Void, Never>?
    private var operationID: UUID?
    @ObservationIgnored private var historyOperation: Task<Void, Never>?
    private var historyOperationID: UUID?
    let operationHistory: OperationHistoryModel
    private var executionRunID: String?
    private var applying = false
    private var stopping = false

    init(actions: MaintenanceActions = .live(), operationHistory: OperationHistoryModel = OperationHistoryModel()) {
        self.actions = actions
        self.operationHistory = operationHistory
    }

    var isBusy: Bool { operationID != nil }
    var isReadingHistory: Bool { historyOperationID != nil }
    var canReloadHistory: Bool { !isReadingHistory && !isExecuting && !stopping }
    var isExecuting: Bool { isBusy && applying }
    var processedItemCount: Int { Set(itemResults.map(\.itemID)).intersection(selectedItemIDs).count }
    var executionProgress: Double? {
        guard isExecuting, !selectedItemIDs.isEmpty else { return nil }
        return Double(processedItemCount) / Double(selectedItemIDs.count)
    }
    var canStart: Bool { !isBusy && !isReadingHistory && !stopping && canStartRequest() }
    var canScan: Bool { !isBusy && !stopping && (canStartRequest() || canScanConcurrently()) }
    var selectedItems: [MaintenanceItem] { plan?.items.filter { selectedItemIDs.contains($0.itemID) } ?? [] }
    var selectedBytes: UInt64 { selectedItems.compactMap(\.estimatedBytes).reduce(0, +) }
    var unknownSizeCount: Int { selectedItems.filter { $0.estimatedBytes == nil }.count }
    var focusedItem: MaintenanceItem? { plan?.items.first { $0.itemID == focusedItemID } }
    var normalizedSearchText: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    var filteredItems: [MaintenanceItem] {
        let search = normalizedSearchText
        return (plan?.items ?? []).filter {
            search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)
        }
    }
    var canConfirm: Bool {
        guard canStart, let plan, plan.scanComplete, !planExpired, !selectedItemIDs.isEmpty else { return false }
        let required = Set(plan.items.filter { $0.selection == .required }.map(\.itemID))
        return required.isSubset(of: selectedItemIDs) && selectedItems.count == selectedItemIDs.count && selectedItems.allSatisfy {
            $0.selection != .blocked && Set($0.dependsOnItemIDs).isSubset(of: selectedItemIDs)
        }
    }

    func canSelect(_ item: MaintenanceItem) -> Bool {
        // “必选”约束执行清单，不应禁止用户撤回本次选择。
        canStart && !planExpired && item.selection != .blocked && Set(item.dependsOnItemIDs).isSubset(of: selectedItemIDs)
    }

    func setSelected(_ id: String, selected: Bool) {
        guard let item = plan?.items.first(where: { $0.itemID == id }), canSelect(item) else { return }
        confirmation = nil
        if selected { selectedItemIDs.insert(id) }
        else {
            selectedItemIDs.remove(id)
            // 取消父项目时同步取消依赖项，避免确认清单包含无法独立执行的残留。
            var changed = true
            while changed {
                let invalid = selectedItems.filter { !Set($0.dependsOnItemIDs).isSubset(of: selectedItemIDs) }.map(\.itemID)
                changed = !invalid.isEmpty
                selectedItemIDs.subtract(invalid)
            }
        }
    }

    func setFilteredItemsSelected(_ selected: Bool) {
        for item in filteredItems { setSelected(item.itemID, selected: selected) }
    }

    func scanClean() { startPlan(application: nil) }
    func planUninstall(_ application: MoleApplication) { startPlan(application: application) }
    func recheckApplication() {
        guard let application = plannedApplication else { return }
        startPlan(application: application)
    }

    private func startPlan(application: MoleApplication?) {
        guard let id = begin(scanning: true) else { return }
        let activity = OperationActivity(
            kind: application == nil ? .cleanScan : .uninstallPlan,
            title: application.map { "检查移除计划：\($0.name)" } ?? "检查缓存与日志",
            targetPath: application?.path
        )
        plannedApplication = application
        plan = nil
        confirmation = nil
        selectedItemIDs = []
        focusedItemID = nil
        result = nil
        itemResults = []
        planExpired = false
        executionUncertain = false
        searchText = ""
        phase = .scanning
        progressMessage = application == nil ? "正在检查缓存与日志…" : "正在检查应用与相关文件…"
        operation = Task {
            // 检查不修改目标文件，已获准并行后不再等待磁盘任务或其取消收尾。
            do {
                try Task.checkCancellation()
                let capabilities = try await actions.capabilities()
                guard capabilities.supportedActions.contains(.trashItem) else { throw MaintenanceUIError.unsupportedEngine }
                engineCapabilities = capabilities
                let callback = eventHandler(id)
                let value: MaintenancePlan
                if let application { value = try await actions.planUninstall(application, callback) }
                else { value = try await actions.scanClean(callback) }
                try Task.checkCancellation()
                guard operationID == id else { return }
                plan = value
                selectedItemIDs = Set(value.items.filter { $0.selection == .required }.map(\.itemID))
                phase = .ready
                progressMessage = ""
                let available = value.items.filter { $0.selection != .blocked }.count
                operationHistory.record(activity.finished(value.scanComplete ? .completed : .partial,
                    summary: "发现 \(value.items.count) 个项目，其中 \(available) 个可选，\(value.scanIssues.count) 项检查提示。仅生成检查计划，未执行移除。"))
            } catch {
                guard operationID == id else { return }
                let cancelled = error is CancellationError || Task.isCancelled
                phase = cancelled ? .cancelled : .failed(error.localizedDescription)
                operationHistory.record(activity.finished(cancelled ? .cancelled : .failed,
                    summary: cancelled ? "检查已取消，未执行移除。" : error.localizedDescription))
            }
            finish(id)
        }
    }

    func requestConfirmation() {
        guard canConfirm, let plan else { return }
        confirmation = MaintenanceConfirmation(planID: plan.planID, title: plan.title, items: selectedItems)
    }

    func dismissConfirmation() { confirmation = nil }

    func confirmExecution() {
        guard canConfirm, let confirmation, let plan,
              confirmation.planID == plan.planID, Set(confirmation.itemIDs) == selectedItemIDs,
              let id = begin() else { return }
        let activity = OperationActivity(kind: .execution, title: confirmation.title, targetPath: plannedApplication?.path)
        self.confirmation = nil
        executionRunID = nil
        historyPhase = .idle
        applying = true
        planExpired = true
        result = nil
        itemResults = []
        executionUncertain = false
        phase = .applying
        progressMessage = "正在重新核对选中项目…"
        operation = Task {
            await beforeRequest()
            var dispatched = false
            do {
                try Task.checkCancellation()
                dispatched = true
                let value = try await actions.apply(confirmation.planID, confirmation.itemIDs, eventHandler(id))
                guard operationID == id else { return }
                // apply 的正常取消仍返回最终记录，不能用 Task.isCancelled 丢弃已经发生的结果。
                result = value
                operationHistory.record(OperationRecord(execution: value))
                itemResults = value.items
                // 执行收尾后同步已确认移除的本体；整体取消、部分失败或通信中断不抹掉已确认的逐项结果。
                if plan.kind == .uninstall, value.planID == plan.planID {
                    let removedPaths = Set(confirmation.items.filter { item in
                        item.kind == .application && value.items.contains {
                            $0.itemID == item.itemID && $0.path == item.path && $0.outcome == .trashed
                        }
                    }.map(\.path))
                    if !removedPaths.isEmpty { onApplicationsTrashed(removedPaths) }
                }
                executionUncertain = value.status == .unknown
                phase = .finished
            } catch {
                guard operationID == id else { return }
                if !dispatched && error is CancellationError {
                    executionUncertain = false
                    phase = .cancelled
                    operationHistory.record(activity.finished(.cancelled, summary: "执行开始前已取消，未移除任何项目。"))
                } else {
                    executionUncertain = true
                    let message = "未收到完整执行结果，请在操作记录中核对。\(error.localizedDescription)"
                    phase = .failed(message)
                    operationHistory.record(activity.finished(.unknown, summary: message, executionRunID: executionRunID))
                }
            }
            finish(id)
        }
    }

    func cancel() {
        guard isBusy else { return }
        if applying || phase == .scanning { phase = .cancelling }
        progressMessage = isExecuting ? "正在取消剩余操作，等待当前项目收尾…" : "正在取消，等待任务收尾…"
        operation?.cancel()
    }

    func forceEndConfirmed() {
        guard isBusy else { return }
        executionUncertain = isExecuting
        phase = .cancelling
        progressMessage = "正在强制结束，本次结果可能需要核对…"
        actions.forceEnd()
    }

    func reloadHistory() {
        guard canReloadHistory else { return }
        operationHistory.load()
        let id = UUID()
        historyOperationID = id
        historyPhase = .loading
        historyOperation = Task {
            do {
                try Task.checkCancellation()
                let values = try await actions.history()
                try Task.checkCancellation()
                history = values.sorted { $0.finishedAt > $1.finishedAt }
                operationHistory.mergeExecutions(values)
                historyPhase = .loaded
            } catch {
                historyPhase = error is CancellationError || Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            guard historyOperationID == id else { return }
            historyOperationID = nil
            historyOperation = nil
        }
    }

    func cancelHistory() {
        guard isReadingHistory else { return }
        historyPhase = .cancelling
        historyOperation?.cancel()
    }

    func reloadProtections() {
        guard let id = begin() else { return }
        protectionsPhase = .loading
        operation = Task {
            await beforeRequest()
            do {
                try Task.checkCancellation()
                protectedPaths = try await actions.protections()
                protectionsPhase = .loaded
            } catch { protectionsPhase = error is CancellationError ? .cancelled : .failed(error.localizedDescription) }
            finish(id)
        }
    }

    func changeProtection(path: String, protected: Bool) {
        guard let id = begin() else { return }
        confirmation = nil
        protectionsPhase = .loading
        operation = Task {
            await beforeRequest()
            do {
                try Task.checkCancellation()
                if protected { try await actions.protect(path) }
                else { try await actions.unprotect(path) }
                planExpired = plan != nil
                selectedItemIDs = []
                notice = protected ? "已长期保护此项目。当前计划已失效，请重新扫描。" : "已取消长期保护。当前计划已失效，请重新扫描。"
                protectedPaths = try await actions.protections()
                protectionsPhase = .loaded
            } catch {
                protectionsPhase = .failed(error.localizedDescription)
                notice = "保护设置未能完整更新：\(error.localizedDescription)"
            }
            finish(id)
        }
    }

    func waitForCurrentOperation() async {
        await operation?.value
        await historyOperation?.value
    }

    func stopRequests(cancelMaintenance: Bool) {
        stopping = true
        if cancelMaintenance { cancel() }
        cancelHistory()
    }

    func prepareToTerminate(cancel: Bool) async {
        stopRequests(cancelMaintenance: cancel)
        await waitForCurrentOperation()
    }

    func resumeAfterWindowClose() { stopping = false }

    private func begin(scanning: Bool = false) -> UUID? {
        guard (scanning ? canScan : canStart) else { return nil }
        let id = UUID()
        operationID = id
        notice = nil
        return id
    }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        operation = nil
        applying = false
    }

    private func eventHandler(_ id: UUID) -> @Sendable (MaintenanceEvent) -> Void {
        { [weak self] event in
            Task { @MainActor in
                guard let self, self.operationID == id else { return }
                if self.applying { self.executionRunID = event.runID }
                if let message = event.message, self.phase != .cancelling { self.progressMessage = message }
                if let item = event.itemResult {
                    self.itemResults.removeAll { $0.itemID == item.itemID }
                    self.itemResults.append(item)
                }
            }
        }
    }
}

private enum MaintenanceUIError: LocalizedError {
    case unsupportedEngine
    var errorDescription: String? { "随包维护引擎不支持移入废纸篓，请检查 App 构建。" }
}
