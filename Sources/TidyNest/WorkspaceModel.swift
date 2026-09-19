import AppKit
import Foundation
import Observation
import TidyNestCore

enum QueryPhase: Equatable {
    case idle, loading, loaded, cancelling, cancelled
    case failed(String)
}

enum WorkspacePage: String, CaseIterable, Identifiable {
    case applications, clean, disk, history
    var id: Self { self }
    var title: String {
        switch self { case .clean: "清理"; case .applications: "应用"; case .disk: "磁盘"; case .history: "操作记录" }
    }
    var symbol: String {
        switch self { case .clean: "sparkles"; case .applications: "square.grid.2x2"; case .disk: "internaldrive"; case .history: "clock.arrow.circlepath" }
    }
}

@MainActor @Observable
final class WorkspaceModel {
    var page: WorkspacePage = .applications
    var searchText = ""
    var selectedApplicationID: String?
    var selectedDiskEntryID: String?
    private(set) var installation: MoleInstallation?
    private(set) var connectionPhase: QueryPhase = .idle
    private(set) var installPhase: QueryPhase = .idle
    private(set) var installProgress: MoleInstallPhase?
    private(set) var applicationsPhase: QueryPhase = .idle
    private(set) var applicationRefreshPhase: QueryPhase = .idle
    private(set) var applicationRefreshTarget: MoleApplication?
    private(set) var diskPhase: QueryPhase = .idle
    private(set) var applications: [MoleApplication] = []
    private(set) var applicationsUpdatedAt: Date?
    private(set) var applicationCacheNotice: String?
    private(set) var diskReport: MoleDiskReport?
    private(set) var requestedDirectory: URL?
    private(set) var isTerminating = false
    let maintenance: MaintenanceModel

    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    private var queryActivity: OperationActivity?
    private var operationID: UUID?
    private var cleanupID: UUID?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private let applicationCache: ApplicationListCache?
    @ObservationIgnored private let detectQuery: @Sendable () async throws -> MoleInstallation
    @ObservationIgnored private let applicationQuery: @Sendable (MoleInstallation) async throws -> [MoleApplication]
    @ObservationIgnored private let singleApplicationQuery: @Sendable (MoleApplication) async throws -> MoleApplication
    @ObservationIgnored private let diskQuery: @Sendable (URL, MoleInstallation) async throws -> MoleDiskReport
    @ObservationIgnored private let installQuery: @Sendable (@escaping @Sendable (MoleInstallPhase) -> Void) async throws -> MoleInstallation
    private(set) var moleNotInstalled = false

    init(
        detect: @escaping @Sendable () async throws -> MoleInstallation = { try await MoleService().detect() },
        applications: @escaping @Sendable (MoleInstallation) async throws -> [MoleApplication] = { try await MoleService().applications(using: $0) },
        refreshApplication: @escaping @Sendable (MoleApplication) async throws -> MoleApplication = { try await ApplicationRefreshService().refresh($0) },
        analyze: @escaping @Sendable (URL, MoleInstallation) async throws -> MoleDiskReport = { try await MoleService().analyze(directory: $0, using: $1) },
        install: @escaping @Sendable (@escaping @Sendable (MoleInstallPhase) -> Void) async throws -> MoleInstallation = { try await MoleInstaller().install(onProgress: $0) },
        maintenance: MaintenanceModel? = nil,
        applicationCache: ApplicationListCache? = nil
    ) {
        self.applicationCache = applicationCache
        detectQuery = detect
        applicationQuery = applications
        singleApplicationQuery = refreshApplication
        diskQuery = analyze
        installQuery = install
        self.maintenance = maintenance ?? MaintenanceModel()
        self.maintenance.canStartRequest = { [weak self] in
            guard let self else { return false }
            return self.operationID == nil && self.cleanupID == nil && !self.isTerminating
        }
        self.maintenance.canScanConcurrently = { [weak self] in
            guard let self else { return false }
            let reading = [self.diskPhase, self.applicationsPhase, self.applicationRefreshPhase].contains(.loading)
            return self.operationID != nil && reading && self.cleanupID == nil && !self.isTerminating
        }
        self.maintenance.onApplicationsTrashed = { [weak self] paths in
            self?.removeTrashedApplications(at: paths)
        }
        self.maintenance.beforeRequest = { [weak self] in
            // 执行和保护设置仍须等待查询收尾；只读检查可与应用、磁盘查询并行。
            await self?.cleanupTask?.value
            self?.cleanupTask = nil
        }
    }

    var operationHistory: OperationHistoryModel { maintenance.operationHistory }
    var isBusy: Bool { operationID != nil || cleanupID != nil || maintenance.isBusy || maintenance.isReadingHistory }
    var hasApplicationSnapshot: Bool { applicationsUpdatedAt != nil }
    var canQuery: Bool { installation?.isSupported == true && canReadWorkspace }
    var canAnalyzeDisk: Bool { canQuery }
    private var canReadWorkspace: Bool {
        operationID == nil && cleanupID == nil && !isTerminating
            && (!maintenance.isBusy || maintenance.phase == .scanning)
    }
    var canInstallMole: Bool { moleNotInstalled && !isBusy && !isTerminating }
    var showsMoleInstallation: Bool { moleNotInstalled || installPhase != .idle }
    var isDetectingMole: Bool {
        !showsMoleInstallation && (connectionPhase == .loading || connectionPhase == .cancelling)
    }
    var showsConnectionNotice: Bool {
        guard installation?.isSupported != true else { return false }
        // 普通连接进度留在侧栏；安装复检仍需保留安装进度和取消入口。
        return showsMoleInstallation || (!isDetectingMole && connectionPhase != .idle)
    }
    var filteredApplications: [MoleApplication] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return applications.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var selectedApplication: MoleApplication? {
        filteredApplications.first { $0.id == selectedApplicationID }
    }
    var sortedDiskEntries: [MoleDiskEntry] {
        (diskReport?.entries ?? []).sorted { $0.size == $1.size ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.size > $1.size }
    }
    var selectedDiskEntry: MoleDiskEntry? { diskReport?.entries.first { $0.id == selectedDiskEntryID } }
    var connectionLabel: String {
        if installPhase == .loading { return "正在安装 Mole" }
        if installPhase == .cancelling { return "正在取消安装" }
        return switch connectionPhase {
        case .loading: "正在检测 Mole"
        case .failed: "Mole 未连接"
        case .cancelling: "正在取消检测"
        case .cancelled: "检测已取消"
        default: installation.map { $0.isSupported ? "Mole 已连接" : "Mole 版本未验证" } ?? "等待检测 Mole"
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        operationHistory.load()
        if let snapshot = applicationCache?.load() {
            applications = snapshot.applications
            applicationsUpdatedAt = snapshot.updatedAt
        }
        detectInstallation()
    }

    func detectInstallation() {
        guard !isTerminating, !isBusy else { return }
        cancelOperation()
        installation = nil
        moleNotInstalled = false
        installPhase = .idle
        installProgress = nil
        connectionPhase = .loading
        let id = UUID()
        operationID = id
        operation = Task {
            do {
                let result = try await detectQuery()
                guard operationID == id, !Task.isCancelled else { return }
                installation = result
                connectionPhase = .loaded
            } catch {
                guard operationID == id else { return }
                moleNotInstalled = Self.isMissingMole(error)
                connectionPhase = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
            }
            finish(id)
        }
    }

    func installMole() {
        guard canInstallMole else { return }
        installPhase = .loading
        installProgress = .preparing
        let id = UUID()
        operationID = id
        operation = Task {
            var checkingInstallation = false
            do {
                _ = try await installQuery { [weak self] phase in
                    Task { @MainActor in
                        guard let self, self.operationID == id, self.installPhase == .loading,
                              self.connectionPhase != .loading else { return }
                        self.installProgress = phase
                    }
                }
                try Task.checkCancellation()
                guard operationID == id else { return }
                // 安装器返回成功不代表当前检测入口可用，必须走同一检测链重新确认。
                checkingInstallation = true
                installProgress = .checking
                connectionPhase = .loading
                let result = try await detectQuery()
                try Task.checkCancellation()
                guard operationID == id else { return }
                installation = result
                moleNotInstalled = false
                connectionPhase = .loaded
                installPhase = result.isSupported ? .loaded : .failed(MoleError.unsupportedVersion(result.version).localizedDescription)
            } catch {
                guard operationID == id else { return }
                installation = nil
                if checkingInstallation {
                    moleNotInstalled = Self.isMissingMole(error)
                    connectionPhase = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
                }
                installPhase = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
            }
            finish(id)
        }
    }

    func loadApplications() {
        guard canQuery, let installation else { return }
        cancelOperation()
        applicationsPhase = .loading
        applicationRefreshPhase = .idle
        applicationRefreshTarget = nil
        let activity = OperationActivity(kind: .applicationList, title: hasApplicationSnapshot ? "刷新应用列表" : "读取应用列表", targetPath: nil)
        queryActivity = activity
        let id = UUID()
        operationID = id
        operation = Task {
            do {
                let result = try await applicationQuery(installation)
                guard operationID == id, !Task.isCancelled else { return }
                applications = result
                if let selectedApplicationID, !result.contains(where: { $0.id == selectedApplicationID }) {
                    self.selectedApplicationID = nil
                }
                applicationsPhase = .loaded
                operationHistory.record(activity.finished(.completed, summary: "已读取 \(result.count) 个应用。"))
                applicationsUpdatedAt = Date()
                persistApplicationSnapshot(failureNotice: "列表已更新，但未能保存；下次打开仍需重新读取。")
            } catch {
                guard operationID == id else { return }
                applicationsPhase = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
                operationHistory.record(activity.finished(error is CancellationError ? .cancelled : .failed,
                    summary: error is CancellationError ? "读取已取消，保留上次列表。" : error.localizedDescription))
            }
            finish(id)
        }
    }

    private func removeTrashedApplications(at paths: Set<String>) {
        guard applications.contains(where: { paths.contains($0.path) }) else { return }
        applications.removeAll { paths.contains($0.path) }
        if let selectedApplicationID, paths.contains(selectedApplicationID) {
            self.selectedApplicationID = nil
        }
        if let applicationRefreshTarget, paths.contains(applicationRefreshTarget.path) {
            self.applicationRefreshTarget = nil
            applicationRefreshPhase = .idle
        }
        persistApplicationSnapshot(failureNotice: "应用已移除，但列表未能保存；下次打开请刷新列表。")
    }

    private func persistApplicationSnapshot(failureNotice: String) {
        applicationCacheNotice = nil
        // 单项刷新和移除同步沿用完整列表时间；只有全量读取成功才更新该时间。
        guard let updatedAt = applicationsUpdatedAt else { return }
        do {
            try applicationCache?.save(ApplicationListSnapshot(applications: applications, updatedAt: updatedAt))
        } catch {
            applicationCacheNotice = failureNotice
        }
    }

    func canPlanUninstall(_ application: MoleApplication) -> Bool {
        applications.contains(application) && maintenance.canScan
    }

    func canRefreshApplication(_ application: MoleApplication) -> Bool {
        canReadWorkspace && applications.contains(application)
    }

    func refreshApplication(_ application: MoleApplication) {
        guard canRefreshApplication(application) else { return }
        cancelOperation()
        applicationRefreshTarget = application
        applicationRefreshPhase = .loading
        let activity = OperationActivity(kind: .applicationRefresh, title: "刷新应用：\(application.name)", targetPath: application.path)
        queryActivity = activity
        let id = UUID()
        operationID = id
        operation = Task {
            do {
                let result = try await singleApplicationQuery(application)
                guard operationID == id, !Task.isCancelled else { return }
                guard result.path == application.path, let index = applications.firstIndex(of: application) else {
                    throw MoleError.invalidResponse("单个应用路径")
                }
                applications[index] = result
                applicationRefreshPhase = .loaded
                operationHistory.record(activity.finished(.completed, summary: "已更新名称、Bundle ID 与占用信息（\(result.displaySize)）。"))
                persistApplicationSnapshot(failureNotice: "应用已刷新，但未能保存；下次打开仍需重新读取。")
            } catch {
                guard operationID == id else { return }
                applicationRefreshPhase = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
                operationHistory.record(activity.finished(error is CancellationError ? .cancelled : .failed,
                    summary: error is CancellationError ? "刷新已取消，保留原信息。" : error.localizedDescription))
            }
            finish(id)
        }
    }

    func analyze(directory: URL) {
        guard canAnalyzeDisk, let installation else { return }
        cancelOperation()
        requestedDirectory = directory.standardizedFileURL
        diskReport = nil
        selectedDiskEntryID = nil
        diskPhase = .loading
        let activity = OperationActivity(kind: .diskAnalysis, title: "读取文件夹：\(directory.lastPathComponent)", targetPath: directory.standardizedFileURL.path)
        queryActivity = activity
        let id = UUID()
        operationID = id
        operation = Task {
            do {
                let result = try await diskQuery(directory, installation)
                guard operationID == id, !Task.isCancelled else { return }
                diskReport = result
                diskPhase = .loaded
                operationHistory.record(activity.finished(.completed,
                    summary: "共 \(result.totalFiles) 个文件，占用 \(formattedBytes(result.totalSize))。仅读取占用，未执行移除。"))
            } catch {
                guard operationID == id else { return }
                diskPhase = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
                operationHistory.record(activity.finished(error is CancellationError ? .cancelled : .failed,
                    summary: error is CancellationError ? "读取已取消，未执行移除。" : error.localizedDescription))
            }
            finish(id)
        }
    }

    func chooseDirectory() {
        guard canAnalyzeDisk else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要查看的文件夹"
        panel.prompt = "查看占用"
        panel.message = "拾净会读取所选文件夹的磁盘占用。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { analyze(directory: url) }
    }

    func goUp() {
        guard canAnalyzeDisk, let directory = requestedDirectory, directory.path != "/" else { return }
        analyze(directory: directory.deletingLastPathComponent())
    }

    func cancelOperation() {
        // 先使身份失效；取消返回后仍保留 busy，直到本次进程完成回收。
        operationID = nil
        guard let operation else { return }
        let cancelledActivity = queryActivity
        queryActivity = nil
        operation.cancel()
        self.operation = nil
        let id = UUID()
        cleanupID = id
        if connectionPhase == .loading { connectionPhase = .cancelling }
        if applicationsPhase == .loading { applicationsPhase = .cancelling }
        if applicationRefreshPhase == .loading { applicationRefreshPhase = .cancelling }
        if diskPhase == .loading { diskPhase = .cancelling }
        if installPhase == .loading { installPhase = .cancelling }
        cleanupTask = Task {
            await operation.value
            guard cleanupID == id else { return }
            if let cancelledActivity {
                operationHistory.record(cancelledActivity.finished(.cancelled, summary: "操作已取消，未更新查询结果。"))
            }
            cleanupID = nil
            cleanupTask = nil
            if connectionPhase == .cancelling { connectionPhase = .cancelled }
            if applicationsPhase == .cancelling { applicationsPhase = .cancelled }
            if applicationRefreshPhase == .cancelling { applicationRefreshPhase = .cancelled }
            if diskPhase == .cancelling { diskPhase = .cancelled }
            if installPhase == .cancelling { installPhase = .cancelled; installProgress = nil }
        }
    }

    func prepareToTerminate(cancelMaintenance: Bool = true) async {
        isTerminating = true
        // 先禁止新请求并取消所有只读任务，再等待各自收尾。
        maintenance.stopRequests(cancelMaintenance: cancelMaintenance)
        cancelOperation()
        await cleanupTask?.value
        cleanupTask = nil
        await maintenance.prepareToTerminate(cancel: cancelMaintenance)
    }

    func prepareToCloseWindow(cancelMaintenance: Bool) async {
        await prepareToTerminate(cancelMaintenance: cancelMaintenance)
        maintenance.resumeAfterWindowClose()
        isTerminating = false
    }

    func openUninstallPlan(_ application: MoleApplication) {
        // 列表仅用于选择目标；维护引擎会独立核验当前路径、标识与安装集合。
        guard canPlanUninstall(application) else { return }
        page = .clean
        maintenance.planUninstall(application)
    }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        operation = nil
        queryActivity = nil
    }

    private static func isMissingMole(_ error: any Error) -> Bool {
        guard let error = error as? MoleError else { return false }
        if case .notInstalled = error { return true }
        return false
    }

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
