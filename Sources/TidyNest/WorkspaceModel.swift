import AppKit
import Foundation
import Observation
import TidyNestCore

enum QueryPhase: Equatable {
    case idle, loading, loaded, cancelling, cancelled
    case failed(String)
}

enum WorkspacePage: String, CaseIterable, Identifiable {
    case clean, applications, disk, history
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
    var page: WorkspacePage = .clean
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
    private var refreshedApplications: Set<MoleApplication> = []
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
        self.maintenance.beforeRequest = { [weak self] in
            // M1 取消后可能仍在回收子进程；维护任务必须等它收尾，避免后台请求重叠。
            await self?.cleanupTask?.value
            self?.cleanupTask = nil
        }
    }

    var isBusy: Bool { operationID != nil || cleanupID != nil || maintenance.isBusy }
    var hasApplicationSnapshot: Bool { applicationsUpdatedAt != nil }
    var canQuery: Bool { installation?.isSupported == true && !isBusy && !isTerminating }
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
        guard !isTerminating, !isBusy, let installation, installation.isSupported else { return }
        cancelOperation()
        applicationsPhase = .loading
        applicationRefreshPhase = .idle
        applicationRefreshTarget = nil
        refreshedApplications.removeAll()
        let id = UUID()
        operationID = id
        operation = Task {
            do {
                let result = try await applicationQuery(installation)
                guard operationID == id, !Task.isCancelled else { return }
                applications = result
                refreshedApplications = Set(result)
                if let selectedApplicationID, !result.contains(where: { $0.id == selectedApplicationID }) {
                    self.selectedApplicationID = nil
                }
                applicationsPhase = .loaded
                let updatedAt = Date()
                applicationsUpdatedAt = updatedAt
                applicationCacheNotice = nil
                do {
                    try applicationCache?.save(ApplicationListSnapshot(applications: result, updatedAt: updatedAt))
                } catch {
                    applicationCacheNotice = "列表已更新，但未能保存；下次打开仍需重新读取。"
                }
            } catch {
                guard operationID == id else { return }
                applicationsPhase = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
            }
            finish(id)
        }
    }

    func isApplicationRefreshed(_ application: MoleApplication) -> Bool {
        applications.contains(application) && refreshedApplications.contains(application)
    }

    func canPlanUninstall(_ application: MoleApplication) -> Bool {
        isApplicationRefreshed(application) && maintenance.canStart
    }

    func refreshApplication(_ application: MoleApplication) {
        guard !isTerminating, !isBusy, applications.contains(application) else { return }
        cancelOperation()
        refreshedApplications.remove(application)
        applicationRefreshTarget = application
        applicationRefreshPhase = .loading
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
                refreshedApplications.insert(result)
                applicationRefreshPhase = .loaded
                applicationCacheNotice = nil
                do {
                    // 单项刷新不冒充整张列表已更新，也不把本会话的核验标记写入缓存。
                    if let updatedAt = applicationsUpdatedAt {
                        try applicationCache?.save(ApplicationListSnapshot(applications: applications, updatedAt: updatedAt))
                    }
                } catch {
                    applicationCacheNotice = "应用已刷新，但未能保存；下次打开仍需重新读取。"
                }
            } catch {
                guard operationID == id else { return }
                applicationRefreshPhase = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
            }
            finish(id)
        }
    }

    func analyze(directory: URL) {
        guard !isTerminating, !isBusy, let installation, installation.isSupported else { return }
        cancelOperation()
        requestedDirectory = directory.standardizedFileURL
        diskReport = nil
        selectedDiskEntryID = nil
        diskPhase = .loading
        let id = UUID()
        operationID = id
        operation = Task {
            do {
                let result = try await diskQuery(directory, installation)
                guard operationID == id, !Task.isCancelled else { return }
                diskReport = result
                diskPhase = .loaded
            } catch {
                guard operationID == id else { return }
                diskPhase = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
            }
            finish(id)
        }
    }

    func chooseDirectory() {
        guard canQuery else { return }
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
        guard canQuery, let directory = requestedDirectory, directory.path != "/" else { return }
        analyze(directory: directory.deletingLastPathComponent())
    }

    func cancelOperation() {
        // 先使身份失效；取消返回后仍保留 busy，直到本次进程完成回收。
        operationID = nil
        guard let operation else { return }
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
        // 单项或完整刷新只放行本会话已核验的具体记录，移除引擎仍会独立复核。
        guard canPlanUninstall(application) else { return }
        page = .clean
        maintenance.planUninstall(application)
    }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        operation = nil
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
