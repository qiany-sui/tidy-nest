import Foundation
import XCTest
import TidyNestProtocol
@testable import TidyNest
@testable import TidyNestCore

@MainActor
final class SingleApplicationRefreshTests: XCTestCase {
    func testSingleRefreshPersistsOnlyTargetAndCachedRowsRemainAvailableForPlan() async throws {
        let first = singleApplication("First", path: "/fixture/first.app")
        let second = singleApplication("Second", path: "/fixture/second.app")
        let updated = singleApplication("First Updated", path: first.path)
        let cache = try singleRefreshCache([first, second])
        let gate = SingleApplicationRefreshGate()
        let model = singleRefreshWorkspace(cache: cache, detect: { throw MoleError.notInstalled }, refresh: { try await gate.next($0) })
        model.start()
        await settle(model)
        XCTAssertFalse(model.canQuery, "原生单项查询不依赖 Mole 连接")
        XCTAssertTrue(model.canPlanUninstall(first))
        model.page = .applications
        model.selectedApplicationID = first.id
        model.searchText = "First"
        model.refreshApplication(first)
        await gate.waitForRequests(1)
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.applicationRefreshTarget, first)
        XCTAssertEqual(model.applicationRefreshPhase, .loading)
        XCTAssertEqual(model.applications, [first, second])
        await gate.finish(0, with: .success(updated))
        await settle(model)
        XCTAssertEqual(model.applications, [updated, second])
        XCTAssertEqual(model.selectedApplication, updated)
        XCTAssertEqual(model.searchText, "First")
        XCTAssertEqual(model.applicationRefreshPhase, .loaded)
        XCTAssertEqual(model.applicationsPhase, .idle, "单项成功不能冒充全量查询成功")
        XCTAssertEqual(model.applicationsUpdatedAt, singleSnapshotDate)
        XCTAssertTrue(model.canPlanUninstall(updated))
        XCTAssertFalse(model.canPlanUninstall(first), "已被新记录替换的旧参数不能启动检查")
        XCTAssertTrue(model.canPlanUninstall(second))
        model.openUninstallPlan(first)
        XCTAssertEqual(model.page, .applications)
        model.maintenance.canStartRequest = { false }
        XCTAssertFalse(model.canPlanUninstall(updated), "直接检查也必须服从维护互斥")
        model.openUninstallPlan(updated)
        XCTAssertEqual(model.page, .applications)
        XCTAssertEqual(cache.load(), ApplicationListSnapshot(applications: [updated, second], updatedAt: singleSnapshotDate))

        let reopened = singleRefreshWorkspace(cache: cache, refresh: { _ in XCTFail("缓存恢复不能自动核验"); throw SingleRefreshError.failed })
        reopened.start()
        await settle(reopened)
        XCTAssertEqual(reopened.applications, [updated, second])
        XCTAssertEqual(reopened.applicationsUpdatedAt, singleSnapshotDate)
        XCTAssertTrue(reopened.canPlanUninstall(updated))
        XCTAssertTrue(reopened.canPlanUninstall(second))
    }

    func testCachedApplicationOpensPlanWithoutRefreshingListOrTarget() async throws {
        let first = singleApplication("First", path: "/fixture/first.app")
        let second = singleApplication("Second", path: "/fixture/second.app")
        let cache = try singleRefreshCache([first, second])
        let snapshot = cache.load()
        let recorder = SingleRefreshPlanRecorder()
        let plan = MaintenancePlan(schemaVersion: 1, planID: "fixture-cached-plan", runID: "fixture-scan", kind: .uninstall, title: "隔离检查", engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", configurationDigest: "fixture", createdAt: singleSnapshotDate, scopeRoots: [first.path], scanComplete: true, scanIssues: [], items: [])
        let maintenance = MaintenanceModel(actions: MaintenanceActions(
            capabilities: { EngineCapabilities(schemaVersion: 1, engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", supportedRuleIDs: ["fixture"], supportedActions: [.trashItem]) },
            scanClean: { _ in XCTFail("不能转为全局清理扫描"); throw SingleRefreshError.failed },
            planUninstall: { application, _ in await recorder.record(application); return plan },
            apply: { _, _, _ in XCTFail("只检查，不能执行移除"); throw SingleRefreshError.failed },
            history: { [] }, protections: { [] }, protect: { _ in }, unprotect: { _ in }, forceEnd: {}
        ))
        let model = singleRefreshWorkspace(cache: cache, maintenance: maintenance, refresh: { _ in
            XCTFail("检查不能额外触发单项刷新"); throw SingleRefreshError.failed
        })
        model.start()
        XCTAssertFalse(model.canPlanUninstall(first), "检测进行中仍然互斥")
        await settle(model)
        XCTAssertTrue(model.canPlanUninstall(first), "从缓存恢复后无需先刷新")
        model.searchText = "First"
        model.selectedApplicationID = first.id
        model.openUninstallPlan(first)
        XCTAssertEqual(model.page, .clean)
        XCTAssertFalse(model.canPlanUninstall(second), "不能在检查进行中重复启动")
        model.openUninstallPlan(second)
        await maintenance.waitForCurrentOperation()
        let requests = await recorder.applications
        XCTAssertEqual(requests, [first])
        XCTAssertEqual(maintenance.phase, .ready)
        XCTAssertEqual(model.applications, [first, second])
        XCTAssertEqual(model.applicationsPhase, .idle)
        XCTAssertEqual(model.applicationRefreshPhase, .idle)
        XCTAssertEqual(model.searchText, "First")
        XCTAssertEqual(model.selectedApplicationID, first.id)
        XCTAssertEqual(cache.load(), snapshot)
        XCTAssertNil(maintenance.confirmation)
        XCTAssertNil(maintenance.result)
        await model.prepareToTerminate()
        XCTAssertFalse(model.canPlanUninstall(first), "退出收尾中不得启动检查")
    }

    func testSingleRefreshPassesLatestRecordToUninstallPlan() async throws {
        let first = singleApplication("First", path: "/fixture/first.app")
        let second = singleApplication("Second", path: "/fixture/second.app")
        let updated = singleApplication("First Updated", path: first.path)
        let recorder = SingleRefreshPlanRecorder()
        let plan = MaintenancePlan(schemaVersion: 1, planID: "fixture-single-refresh-plan", runID: "fixture-scan", kind: .uninstall, title: "隔离检查", engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", configurationDigest: "fixture", createdAt: singleSnapshotDate, scopeRoots: ["/fixture"], scanComplete: true, scanIssues: [], items: [])
        let maintenance = MaintenanceModel(actions: MaintenanceActions(
            capabilities: { EngineCapabilities(schemaVersion: 1, engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", supportedRuleIDs: ["fixture"], supportedActions: [.trashItem]) },
            scanClean: { _ in XCTFail("应用检查不能启动清理扫描"); throw SingleRefreshError.failed },
            planUninstall: { application, _ in await recorder.record(application); return plan },
            apply: { _, _, _ in XCTFail("只生成检查结果，不执行移除"); throw SingleRefreshError.failed },
            history: { [] }, protections: { [] }, protect: { _ in }, unprotect: { _ in }, forceEnd: {}
        ))
        let model = singleRefreshWorkspace(cache: try singleRefreshCache([first, second]), maintenance: maintenance, refresh: { _ in updated })
        model.start()
        await settle(model)
        model.refreshApplication(first)
        await settle(model)
        model.page = .applications
        model.openUninstallPlan(first)
        await settle(model)
        let rejectedRequests = await recorder.applications
        XCTAssertTrue(rejectedRequests.isEmpty, "已被刷新结果替换的旧记录不能进入检查")
        XCTAssertEqual(model.page, .applications)
        model.openUninstallPlan(updated)
        XCTAssertEqual(model.page, .clean)
        await maintenance.waitForCurrentOperation()
        let acceptedRequests = await recorder.applications
        XCTAssertEqual(acceptedRequests, [updated], "检查必须收到刷新后的完整记录")
        XCTAssertEqual(maintenance.phase, .ready)
        XCTAssertEqual(maintenance.plan?.planID, plan.planID)
        XCTAssertNil(maintenance.confirmation)
        XCTAssertNil(maintenance.result)
    }

    func testSelectionChangeCannotRedirectSingleRefreshResult() async throws {
        let first = singleApplication("First", path: "/fixture/first.app")
        let second = singleApplication("Second", path: "/fixture/second.app")
        let updated = singleApplication("First Updated", path: first.path)
        let gate = SingleApplicationRefreshGate()
        let model = singleRefreshWorkspace(cache: try singleRefreshCache([first, second]), refresh: { try await gate.next($0) })
        model.start()
        await settle(model)
        model.selectedApplicationID = first.id
        model.refreshApplication(first)
        await gate.waitForRequests(1)
        model.selectedApplicationID = second.id
        model.searchText = "Second"
        XCTAssertEqual(model.applicationRefreshTarget, first)
        await gate.finish(0, with: .success(updated))
        await settle(model)
        let requests = await gate.requests
        XCTAssertEqual(requests, [first])
        XCTAssertEqual(model.applications, [updated, second])
        XCTAssertEqual(model.selectedApplication, second)
        XCTAssertEqual(model.searchText, "Second")
    }

    func testFailedSingleRefreshKeepsListAndAllowsIndependentPlan() async throws {
        let first = singleApplication("First", path: "/fixture/first.app")
        let second = singleApplication("Second", path: "/fixture/second.app")
        let cache = try singleRefreshCache([first, second])
        let model = singleRefreshWorkspace(cache: cache, applications: { _ in [first, second] }, refresh: { _ in throw SingleRefreshError.failed })
        model.start()
        await settle(model)
        model.loadApplications()
        await settle(model)
        XCTAssertTrue(model.canPlanUninstall(first))
        XCTAssertTrue(model.canPlanUninstall(second))
        let snapshot = cache.load()
        model.refreshApplication(first)
        await settle(model)
        guard case .failed = model.applicationRefreshPhase else { return XCTFail("单项失败应有独立错误状态") }
        XCTAssertEqual(model.applications, [first, second])
        XCTAssertEqual(model.applicationsPhase, .loaded)
        XCTAssertEqual(model.applicationsUpdatedAt, snapshot?.updatedAt)
        XCTAssertEqual(cache.load(), snapshot)
        XCTAssertTrue(model.canPlanUninstall(first))
        XCTAssertTrue(model.canPlanUninstall(second), "单项刷新失败不影响其他记录的独立检查")
    }

    func testCancelledSingleRefreshWaitsForCleanupAndDiscardsLateResult() async throws {
        let first = singleApplication("First", path: "/fixture/first.app")
        let second = singleApplication("Second", path: "/fixture/second.app")
        let late = singleApplication("Late", path: first.path)
        let cache = try singleRefreshCache([first, second])
        let gate = SingleApplicationRefreshGate()
        let model = singleRefreshWorkspace(cache: cache, applications: { _ in [first, second] }, refresh: { try await gate.next($0) })
        model.start()
        await settle(model)
        model.loadApplications()
        await settle(model)
        let snapshot = cache.load()
        model.refreshApplication(first)
        await gate.waitForRequests(1)
        model.cancelOperation()
        XCTAssertEqual(model.applicationRefreshPhase, .cancelling)
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canPlanUninstall(second), "取消收尾前不能启动维护")
        model.refreshApplication(second)
        let requestsDuringCleanup = await gate.requests
        XCTAssertEqual(requestsDuringCleanup, [first])
        await gate.finish(0, with: .success(late))
        await settle(model)
        XCTAssertEqual(model.applicationRefreshPhase, .cancelled)
        XCTAssertEqual(model.applications, [first, second])
        XCTAssertEqual(cache.load(), snapshot)
        XCTAssertTrue(model.canPlanUninstall(first))
        XCTAssertTrue(model.canPlanUninstall(second))
        model.refreshApplication(second)
        await gate.waitForRequests(2)
        await gate.finish(1, with: .success(second))
        await settle(model)
        XCTAssertTrue(model.canPlanUninstall(second), "收尾后仍可手动刷新其他记录")
    }

    func testSingleRefreshRejectsResultForAnotherPath() async throws {
        let first = singleApplication("First", path: "/fixture/first.app")
        let second = singleApplication("Second", path: "/fixture/second.app")
        let cache = try singleRefreshCache([first, second])
        let model = singleRefreshWorkspace(cache: cache, refresh: { _ in second })
        model.start()
        await settle(model)
        model.refreshApplication(first)
        await settle(model)
        guard case .failed = model.applicationRefreshPhase else { return XCTFail("返回路径不匹配时必须拒绝更新") }
        XCTAssertEqual(model.applications, [first, second])
        XCTAssertEqual(cache.load()?.applications, [first, second])
        XCTAssertEqual(model.applicationsUpdatedAt, singleSnapshotDate)
        XCTAssertTrue(model.canPlanUninstall(first))
        XCTAssertTrue(model.canPlanUninstall(second))
    }

    func testFullRefreshReplacesRowsAndFailureKeepsIndependentPlanAvailable() async throws {
        let first = singleApplication("First", path: "/fixture/first.app")
        let second = singleApplication("Second", path: "/fixture/second.app")
        let updated = singleApplication("First Updated", path: first.path)
        let cache = try singleRefreshCache([first, second])
        let gate = FullApplicationRefreshGate()
        let model = singleRefreshWorkspace(cache: cache, applications: { _ in try await gate.next() }, refresh: { _ in updated })
        model.start()
        await settle(model)
        model.refreshApplication(first)
        await settle(model)
        model.loadApplications()
        await gate.waitForRequests(1)
        XCTAssertTrue(model.canPlanUninstall(updated), "应用列表刷新与独立检查可并行")
        await gate.finish(0, with: .success([first, second]))
        await settle(model)
        XCTAssertTrue(model.canPlanUninstall(first))
        XCTAssertTrue(model.canPlanUninstall(second))
        let snapshot = cache.load()
        model.loadApplications()
        await gate.waitForRequests(2)
        XCTAssertTrue(model.canPlanUninstall(first))
        XCTAssertTrue(model.canPlanUninstall(second))
        await gate.finish(1, with: .failure(.failed))
        await settle(model)
        guard case .failed = model.applicationsPhase else { return XCTFail("全量失败应保留错误状态") }
        XCTAssertEqual(model.applications, [first, second])
        XCTAssertEqual(cache.load(), snapshot)
        XCTAssertTrue(model.canPlanUninstall(first))
        XCTAssertTrue(model.canPlanUninstall(second))
    }

    func testCancelledFullRefreshPreservesRowsWithoutSavingLateList() async throws {
        let first = singleApplication("First", path: "/fixture/first.app")
        let second = singleApplication("Second", path: "/fixture/second.app")
        let updated = singleApplication("First Updated", path: first.path)
        let cache = try singleRefreshCache([first, second])
        let gate = FullApplicationRefreshGate()
        let model = singleRefreshWorkspace(cache: cache, applications: { _ in try await gate.next() }, refresh: { _ in updated })
        model.start()
        await settle(model)
        model.refreshApplication(first)
        await settle(model)
        XCTAssertTrue(model.canPlanUninstall(updated))
        let snapshot = cache.load()
        model.loadApplications()
        await gate.waitForRequests(1)
        model.cancelOperation()
        XCTAssertTrue(model.isBusy)
        await gate.finish(0, with: .success([first, second]))
        await settle(model)
        XCTAssertEqual(model.applicationsPhase, .cancelled)
        XCTAssertEqual(model.applications, [updated, second])
        XCTAssertEqual(cache.load(), snapshot)
        XCTAssertTrue(model.canPlanUninstall(updated))
        XCTAssertTrue(model.canPlanUninstall(second))
    }

    func testSingleRefreshAndDetectionOrOtherQueriesRemainMutuallyExclusive() async throws {
        let first = singleApplication("First", path: "/fixture/first.app")
        let detection = SingleRefreshDetectionGate()
        let refresh = SingleApplicationRefreshGate()
        let model = singleRefreshWorkspace(cache: try singleRefreshCache([first]), detect: { await detection.next() }, refresh: { try await refresh.next($0) })
        model.start()
        await detection.waitForRequests(1)
        model.refreshApplication(first)
        let requestsDuringDetection = await refresh.requests
        XCTAssertTrue(requestsDuringDetection.isEmpty)
        XCTAssertEqual(model.applicationRefreshPhase, .idle)
        await detection.finish(0)
        await settle(model)
        model.refreshApplication(first)
        await refresh.waitForRequests(1)
        XCTAssertFalse(model.canQuery)
        XCTAssertFalse(model.maintenance.canStart)
        model.detectInstallation()
        model.loadApplications()
        model.analyze(directory: URL(fileURLWithPath: "/fixture"))
        XCTAssertTrue(model.maintenance.canScan, "检查可以独立进行，查询之间仍不重入")
        let detectionCount = await detection.count
        XCTAssertEqual(detectionCount, 1)
        XCTAssertEqual(model.maintenance.phase, .idle)
        await refresh.finish(0, with: .success(first))
        await settle(model)
        XCTAssertTrue(model.canPlanUninstall(first))
    }

    func testSingleRefreshCacheFailureKeepsResultAndSuccessfulRetryClearsNotice() async throws {
        let first = singleApplication("First", path: "/fixture/first.app")
        let second = singleApplication("Second", path: "/fixture/second.app")
        let updated = singleApplication("Updated", path: first.path)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cacheURL = root.appendingPathComponent("work/single-application-refresh-tests/\(UUID().uuidString)/applications.json")
        let cache = ApplicationListCache(fileURL: cacheURL)
        try cache.save(ApplicationListSnapshot(applications: [first, second], updatedAt: singleSnapshotDate))
        let model = singleRefreshWorkspace(cache: cache, refresh: { _ in updated })
        model.start()
        await settle(model)
        let backupURL = cacheURL.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: cacheURL, to: backupURL)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: false)
        model.refreshApplication(first)
        await settle(model)
        XCTAssertEqual(model.applicationRefreshPhase, .loaded)
        XCTAssertEqual(model.applications, [updated, second])
        XCTAssertEqual(model.applicationsUpdatedAt, singleSnapshotDate)
        XCTAssertEqual(model.applicationCacheNotice, "应用已刷新，但未能保存；下次打开仍需重新读取。")
        XCTAssertEqual(model.operationHistory.records.first?.status, .completed)
        XCTAssertEqual(ApplicationListCache(fileURL: backupURL).load()?.applications, [first, second])

        try FileManager.default.moveItem(at: cacheURL, to: cacheURL.appendingPathExtension("blocked-directory"))
        model.refreshApplication(updated)
        await settle(model)
        XCTAssertNil(model.applicationCacheNotice)
        XCTAssertEqual(cache.load(), ApplicationListSnapshot(applications: [updated, second], updatedAt: singleSnapshotDate))
    }

    private func settle(_ model: WorkspaceModel) async {
        for _ in 0..<2_000 {
            if !model.isBusy { return }
            await Task.yield()
        }
        XCTFail("状态操作没有完成")
    }
}

private let singleSnapshotDate = Date(timeIntervalSince1970: 100)
private enum SingleRefreshError: Error { case failed }

private func singleApplication(_ name: String, path: String) -> MoleApplication {
    MoleApplication(name: name, bundleIdentifier: "fixture.application", source: "App", uninstallName: name, path: path, displaySize: "24 MB")
}

private func singleRefreshInstallation() -> MoleInstallation {
    MoleInstallation(executableURL: URL(fileURLWithPath: "/fixture/mole"), version: "1.53.0")
}

private func singleRefreshCache(_ applications: [MoleApplication]) throws -> ApplicationListCache {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let cache = ApplicationListCache(fileURL: root.appendingPathComponent("work/single-application-refresh-tests/\(UUID().uuidString)/applications.json"))
    try cache.save(ApplicationListSnapshot(applications: applications, updatedAt: singleSnapshotDate))
    return cache
}

@MainActor
private func singleRefreshWorkspace(
    cache: ApplicationListCache,
    detect: @escaping @Sendable () async throws -> MoleInstallation = { singleRefreshInstallation() },
    applications: @escaping @Sendable (MoleInstallation) async throws -> [MoleApplication] = { _ in XCTFail("未授权全量查询"); throw SingleRefreshError.failed },
    maintenance: MaintenanceModel? = nil,
    refresh: @escaping @Sendable (MoleApplication) async throws -> MoleApplication
) -> WorkspaceModel {
    WorkspaceModel(
        detect: detect,
        applications: applications,
        refreshApplication: refresh,
        analyze: { _, _ in XCTFail("不应执行磁盘查询"); throw SingleRefreshError.failed },
        install: { _ in XCTFail("不应安装 Mole"); throw SingleRefreshError.failed },
        maintenance: maintenance ?? MaintenanceModel(actions: MaintenanceActions(
            capabilities: { XCTFail("被拦截的检查不得启动维护引擎"); throw SingleRefreshError.failed },
            scanClean: { _ in XCTFail("不应扫描真实缓存"); throw SingleRefreshError.failed },
            planUninstall: { _, _ in XCTFail("不应检查真实应用"); throw SingleRefreshError.failed },
            apply: { _, _, _ in XCTFail("不应执行移除"); throw SingleRefreshError.failed },
            history: { [] }, protections: { [] }, protect: { _ in }, unprotect: { _ in }, forceEnd: {}
        )),
        applicationCache: cache
    )
}

private actor SingleApplicationRefreshGate {
    private(set) var requests: [MoleApplication] = []
    private var pending: [CheckedContinuation<MoleApplication, any Error>] = []
    func next(_ application: MoleApplication) async throws -> MoleApplication {
        requests.append(application)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func waitForRequests(_ count: Int) async {
        for _ in 0..<2_000 {
            if pending.count >= count { return }
            await Task.yield()
        }
        XCTFail("单项查询没有按预期开始")
    }
    func finish(_ index: Int, with result: Result<MoleApplication, SingleRefreshError>) {
        pending[index].resume(with: result.mapError { $0 as any Error })
    }
}

private actor FullApplicationRefreshGate {
    private var pending: [CheckedContinuation<[MoleApplication], any Error>] = []
    func next() async throws -> [MoleApplication] { try await withCheckedThrowingContinuation { pending.append($0) } }
    func waitForRequests(_ count: Int) async {
        for _ in 0..<2_000 {
            if pending.count >= count { return }
            await Task.yield()
        }
        XCTFail("全量查询没有按预期开始")
    }
    func finish(_ index: Int, with result: Result<[MoleApplication], SingleRefreshError>) {
        pending[index].resume(with: result.mapError { $0 as any Error })
    }
}

private actor SingleRefreshDetectionGate {
    private var pending: [CheckedContinuation<MoleInstallation, Never>] = []
    var count: Int { pending.count }
    func next() async -> MoleInstallation { await withCheckedContinuation { pending.append($0) } }
    func waitForRequests(_ count: Int) async {
        for _ in 0..<2_000 {
            if pending.count >= count { return }
            await Task.yield()
        }
        XCTFail("Mole 检测没有按预期开始")
    }
    func finish(_ index: Int) { pending[index].resume(returning: singleRefreshInstallation()) }
}

private actor SingleRefreshPlanRecorder {
    private(set) var applications: [MoleApplication] = []
    func record(_ application: MoleApplication) { applications.append(application) }
}
