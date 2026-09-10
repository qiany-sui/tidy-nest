import Foundation
import XCTest
@testable import TidyNestCore
import TidyNestProtocol
@testable import TidyNest

@MainActor
final class ConcurrentApplicationHistoryTests: XCTestCase {
    func testFullRefreshCompletesDuringScanWithoutReplacingPlanTarget() async {
        let fixture = await workspace()
        let model = fixture.model
        model.selectedApplicationID = parallelApp.id
        model.searchText = parallelApp.name
        model.openUninstallPlan(parallelApp)
        await fixture.scan.started()
        XCTAssertTrue(model.canQuery)
        model.loadApplications()
        XCTAssertEqual(model.applicationsPhase, .loading)
        await fixture.apps.release()
        await waitUntil { model.applicationsPhase != .loading }
        XCTAssertEqual(model.applications.first?.displaySize, "24 MB")
        XCTAssertEqual(model.selectedApplicationID, parallelApp.id)
        XCTAssertEqual(model.searchText, parallelApp.name)
        XCTAssertEqual(model.maintenance.plannedApplication, parallelApp)
        XCTAssertEqual(model.maintenance.phase, .scanning)
        await fixture.scan.release()
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.operationHistory.records.filter { $0.kind == .applicationList }.count, 2)
        XCTAssertEqual(model.operationHistory.records.filter { $0.kind == .uninstallPlan }.count, 1)
    }

    func testSingleRefreshCompletesDuringScanAndPreservesFullListDate() async {
        let fixture = await workspace()
        let model = fixture.model
        let date = model.applicationsUpdatedAt
        model.maintenance.scanClean()
        await fixture.scan.started()
        model.refreshApplication(parallelApp)
        XCTAssertEqual(model.applicationRefreshPhase, .loading)
        await fixture.apps.release()
        await waitUntil { model.applicationRefreshPhase != .loading }
        XCTAssertEqual(model.applications.first?.displaySize, "36 MB")
        XCTAssertEqual(model.applicationsUpdatedAt, date)
        XCTAssertEqual(model.maintenance.phase, .scanning)
        await fixture.scan.release()
        await model.maintenance.waitForCurrentOperation()
    }

    func testScanStartsWhileFullApplicationRefreshIsRunning() async {
        let fixture = await workspace()
        let model = fixture.model
        model.loadApplications()
        await fixture.apps.started()
        model.maintenance.scanClean()
        XCTAssertEqual(model.maintenance.phase, .scanning)
        await fixture.scan.release()
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.applicationsPhase, .loading)
        await fixture.apps.release()
        await waitUntil { model.applicationsPhase != .loading }
    }

    func testScanStartsWhileSingleApplicationRefreshIsRunning() async {
        let fixture = await workspace()
        let model = fixture.model
        model.refreshApplication(parallelApp)
        await fixture.apps.started()
        model.maintenance.scanClean()
        XCTAssertEqual(model.maintenance.phase, .scanning)
        await fixture.scan.release()
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.applicationRefreshPhase, .loading)
        await fixture.apps.release()
        await waitUntil { model.applicationRefreshPhase != .loading }
    }

    func testCancellingApplicationRefreshKeepsScanAndOldDisplay() async {
        let fixture = await workspace()
        let model = fixture.model
        model.maintenance.scanClean()
        model.refreshApplication(parallelApp)
        XCTAssertEqual(model.applicationRefreshPhase, .loading)
        model.cancelOperation()
        XCTAssertEqual(model.applicationRefreshPhase, .cancelling)
        XCTAssertEqual(model.maintenance.phase, .scanning)
        await fixture.apps.release()
        await waitUntil { model.applicationRefreshPhase != .cancelling }
        XCTAssertEqual(model.applications.first, parallelApp)
        XCTAssertEqual(model.operationHistory.records.first { $0.kind == .applicationRefresh }?.status, .cancelled)
        await fixture.scan.release()
        await model.maintenance.waitForCurrentOperation()
    }

    func testHistoryCompletesDuringScanAndKeepsNewQueryRecords() async {
        let fixture = await workspace()
        let model = fixture.model
        model.maintenance.scanClean()
        await fixture.scan.started()
        model.maintenance.reloadHistory()
        XCTAssertEqual(model.maintenance.historyPhase, .loading)
        await fixture.history.release()
        await waitUntil { model.maintenance.historyPhase != .loading }
        XCTAssertEqual(model.maintenance.historyPhase, .loaded)
        XCTAssertEqual(model.maintenance.phase, .scanning)
        XCTAssertEqual(model.operationHistory.records.filter { $0.kind == .execution }.count, 1)
        XCTAssertEqual(model.operationHistory.records.filter { $0.kind == .applicationList }.count, 1)
        await fixture.scan.release()
        await model.maintenance.waitForCurrentOperation()
    }

    func testHistoryReadDoesNotBlockScanOrApplicationRefresh() async {
        let fixture = await workspace()
        let model = fixture.model
        model.maintenance.reloadHistory()
        await fixture.history.started()
        model.maintenance.scanClean()
        model.refreshApplication(parallelApp)
        XCTAssertEqual(model.maintenance.phase, .scanning)
        XCTAssertEqual(model.applicationRefreshPhase, .loading)
        await fixture.apps.release()
        await waitUntil { model.applicationRefreshPhase != .loading }
        XCTAssertEqual(model.maintenance.historyPhase, .loading)
        await fixture.scan.release()
        await fixture.history.release()
        await model.maintenance.waitForCurrentOperation()
    }

    func testCancellingScanDoesNotCancelHistoryImport() async {
        let fixture = await workspace()
        let model = fixture.model
        model.maintenance.scanClean()
        await fixture.scan.started()
        model.maintenance.reloadHistory()
        XCTAssertEqual(model.maintenance.historyPhase, .loading)
        model.maintenance.cancel()
        await fixture.scan.release()
        await waitUntil { model.maintenance.phase != .cancelling }
        XCTAssertEqual(model.maintenance.phase, .cancelled)
        XCTAssertEqual(model.maintenance.historyPhase, .loading)
        await fixture.history.release()
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.maintenance.historyPhase, .loaded)
        XCTAssertEqual(model.operationHistory.records.first { $0.kind == .execution }?.execution?.runID, "parallel-history")
    }

    func testHistoryFailureKeepsLocalRecordsAndScanRunning() async {
        let fixture = await workspace(historyFails: true)
        let model = fixture.model
        model.maintenance.scanClean()
        model.maintenance.reloadHistory()
        XCTAssertEqual(model.maintenance.historyPhase, .loading)
        await fixture.history.release()
        await waitUntil { model.maintenance.historyPhase != .loading }
        if case .failed = model.maintenance.historyPhase {} else { XCTFail("记录读取失败应显示错误") }
        XCTAssertEqual(model.operationHistory.records.count, 1)
        XCTAssertEqual(model.maintenance.phase, .scanning)
        await fixture.scan.release()
        await model.maintenance.waitForCurrentOperation()
    }

    func testExecutionWaitsForHistoryReadAndBlocksNewQueries() async {
        let fixture = await workspace()
        let model = fixture.model
        let maintenance = model.maintenance
        await fixture.scan.release()
        maintenance.scanClean()
        await maintenance.waitForCurrentOperation()
        maintenance.setSelected("cache", selected: true)
        maintenance.requestConfirmation()
        maintenance.reloadHistory()
        XCTAssertFalse(maintenance.canConfirm)
        maintenance.confirmExecution()
        XCTAssertFalse(maintenance.isExecuting)
        await fixture.history.release()
        await maintenance.waitForCurrentOperation()
        XCTAssertTrue(maintenance.canConfirm)
        maintenance.confirmExecution()
        await fixture.apply.started()
        XCTAssertFalse(model.canQuery)
        model.refreshApplication(parallelApp)
        maintenance.reloadHistory()
        XCTAssertEqual(model.applicationRefreshPhase, .idle)
        XCTAssertEqual(maintenance.historyPhase, .idle, "执行中不能读取尚未写完的事务结果")
        await fixture.apply.release()
        await maintenance.waitForCurrentOperation()
        XCTAssertEqual(maintenance.result?.runID, "parallel-apply")
    }

    func testHistoryCancellationDoesNotCancelScanOrImportLateResult() async {
        let fixture = await workspace()
        let model = fixture.model
        model.maintenance.scanClean()
        model.maintenance.reloadHistory()
        await fixture.history.started()
        model.maintenance.cancelHistory()
        XCTAssertEqual(model.maintenance.historyPhase, .cancelling)
        XCTAssertEqual(model.maintenance.phase, .scanning)
        XCTAssertFalse(model.maintenance.canReloadHistory)
        model.maintenance.reloadHistory()
        let requests = await fixture.history.count
        XCTAssertEqual(requests, 1, "取消收尾前不能重复派发记录读取")
        await fixture.history.release()
        await waitUntil { model.maintenance.historyPhase == .cancelled }
        XCTAssertTrue(model.operationHistory.records.allSatisfy { $0.kind != .execution })
        XCTAssertTrue(model.maintenance.canReloadHistory)
        await fixture.scan.release()
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.maintenance.phase, .ready)
    }

    func testImmediateHistoryCancellationPreventsDispatch() async {
        let fixture = await workspace()
        let maintenance = fixture.model.maintenance
        maintenance.reloadHistory()
        maintenance.cancelHistory()
        await fixture.history.release()
        await maintenance.waitForCurrentOperation()
        let requests = await fixture.history.count
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(maintenance.historyPhase, .cancelled)
    }

    func testConfirmedHistoryIDsExcludeNewResultsAndDeletedExecutionsStayDeleted() async {
        let fixture = await workspace()
        let model = fixture.model
        let log = model.operationHistory
        log.record(OperationRecord(execution: parallelResult("parallel-history")))
        let confirmedIDs = Set(log.records.map(\.id))
        model.maintenance.scanClean()
        model.maintenance.reloadHistory()
        model.refreshApplication(parallelApp)
        await fixture.apps.release()
        await waitUntil { model.applicationRefreshPhase == .loaded }
        XCTAssertTrue(log.removeRecords(confirmedIDs))
        XCTAssertEqual(log.records.map(\.kind), [.applicationRefresh])
        await fixture.history.release()
        await waitUntil { model.maintenance.historyPhase == .loaded }
        XCTAssertEqual(log.records.map(\.kind), [.applicationRefresh], "旧执行结果不能在刷新后重新出现")
        await fixture.scan.release()
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(Set(log.records.map(\.kind)), [.applicationRefresh, .cleanScan])
    }

    func testTerminationCancelsAllThreeTasksBeforeWaitingAndRejectsNewHistory() async {
        let fixture = await workspace()
        let model = fixture.model
        model.maintenance.scanClean()
        await fixture.scan.started()
        model.refreshApplication(parallelApp)
        await fixture.apps.started()
        model.maintenance.reloadHistory()
        await fixture.history.started()
        var completed = false
        let shutdown = Task { await model.prepareToTerminate(); completed = true }
        await waitUntil { model.isTerminating }
        XCTAssertEqual(model.applicationRefreshPhase, .cancelling)
        XCTAssertEqual(model.maintenance.phase, .cancelling)
        XCTAssertEqual(model.maintenance.historyPhase, .cancelling)
        XCTAssertFalse(model.canRefreshApplication(parallelApp))
        XCTAssertFalse(model.maintenance.canReloadHistory)
        await fixture.history.release()
        await waitUntil { model.maintenance.historyPhase == .cancelled }
        model.maintenance.reloadHistory()
        XCTAssertEqual(model.maintenance.historyPhase, .cancelled, "退出等待其他任务时也不能重新读记录")
        XCTAssertFalse(completed)
        await fixture.scan.release()
        await fixture.apps.release()
        await shutdown.value
        XCTAssertTrue(completed)
        XCTAssertEqual(model.applicationRefreshPhase, .cancelled)
        XCTAssertEqual(model.maintenance.phase, .cancelled)
        XCTAssertFalse(model.isBusy)
    }

    private func workspace(historyFails: Bool = false) async -> ParallelFixture {
        let fixture = ParallelFixture(historyFails: historyFails)
        fixture.model.start()
        await waitUntil { fixture.model.connectionPhase == .loaded }
        fixture.model.loadApplications()
        await waitUntil { fixture.model.applicationsPhase == .loaded }
        return fixture
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<3000 { if predicate() { return }; await Task.yield() }
        XCTFail("并发任务未在预期阶段结束")
    }
}

@MainActor private struct ParallelFixture {
    let model: WorkspaceModel
    let scan = ParallelGate()
    let apps = ParallelGate()
    let history = ParallelGate()
    let apply = ParallelGate()

    init(historyFails: Bool) {
        let scan = self.scan, apps = self.apps, history = self.history, apply = self.apply
        let list = ParallelList()
        model = WorkspaceModel(
            detect: { MoleInstallation(executableURL: URL(fileURLWithPath: "/fixture/mole"), version: "1.53.0") },
            applications: { _ in
                if await list.isFirst() { return [parallelApp] }
                await apps.wait()
                return [parallelApplication(size: "24 MB")]
            },
            refreshApplication: { _ in await apps.wait(); return parallelApplication(size: "36 MB") },
            maintenance: MaintenanceModel(actions: MaintenanceActions(
                capabilities: { EngineCapabilities(schemaVersion: 1, engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", supportedRuleIDs: [], supportedActions: [.trashItem]) },
                scanClean: { _ in await scan.wait(); return parallelPlan(.clean) },
                planUninstall: { _, _ in await scan.wait(); return parallelPlan(.uninstall) },
                apply: { _, _, _ in await apply.wait(); return parallelResult("parallel-apply") },
                history: {
                    await history.wait()
                    if historyFails { throw ParallelFailure.expected }
                    return [parallelResult("parallel-history")]
                },
                protections: { [] }, protect: { _ in }, unprotect: { _ in }, forceEnd: {}
            ))
        )
    }
}

private enum ParallelFailure: Error { case expected }
private let parallelApp = parallelApplication(size: "12 MB")
private func parallelApplication(size: String) -> MoleApplication {
    MoleApplication(name: "示例应用", bundleIdentifier: "com.example.parallel", source: "App", uninstallName: "示例应用", path: "/fixture/Example.app", displaySize: size)
}
private func parallelPlan(_ kind: MaintenanceKind) -> MaintenancePlan {
    let item = MaintenanceItem(itemID: "cache", ruleID: "cache", path: "/fixture/cache", displayName: "隔离缓存", kind: .file, action: .trashItem, estimatedBytes: 12, reason: "并发测试", impact: "注入数据，不移动文件", selection: .optional, blockedReason: nil, dependsOnItemIDs: [])
    return MaintenancePlan(schemaVersion: 1, planID: "parallel-plan", runID: "parallel-scan", kind: kind, title: "隔离检查", engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", configurationDigest: "fixture", createdAt: Date(), scopeRoots: ["/fixture"], scanComplete: true, scanIssues: [], items: [item])
}
private func parallelResult(_ runID: String) -> MaintenanceResult {
    MaintenanceResult(planID: "parallel-plan", runID: runID, title: "隔离执行记录", status: .completed, startedAt: Date(), finishedAt: Date(), items: [], selectedBytes: 0, trashedBytes: 0, freeBytesDelta: nil, message: "仅注入结果")
}
private actor ParallelList {
    private var count = 0
    func isFirst() -> Bool { count += 1; return count == 1 }
}
private actor ParallelGate {
    private(set) var count = 0
    private var began = false
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        count += 1
        began = true
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations = []
    }
    func started() async {
        for _ in 0..<3000 { if began { return }; await Task.yield() }
        XCTFail("预期的隔离请求没有开始")
    }
}
