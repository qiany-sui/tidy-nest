import Foundation
import XCTest
import TidyNestCore
import TidyNestProtocol
@testable import TidyNest

@MainActor
final class MaintenanceModelTests: XCTestCase {
    func testCleanScanStartsWithNoOptionalSelections() async {
        let model = MaintenanceModel(actions: fixtureActions())
        model.scanClean()
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertNil(model.executionProgress, "扫描没有已知项目总数，不能显示确定百分比")
        XCTAssertEqual(model.processedItemCount, 0)
        await model.waitForCurrentOperation()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.executionProgress)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        XCTAssertFalse(model.canConfirm)
    }

    func testRequiredApplicationCannotBeUncheckedAndBlockedRemainsUnselected() async {
        let plan = fixturePlan(kind: .uninstall, items: [fixtureItem("app", selection: .required, kind: .application), fixtureItem("cache", dependencies: ["app"]), fixtureItem("blocked", selection: .blocked)])
        let model = MaintenanceModel(actions: fixtureActions(scan: { _ in plan }))
        model.scanClean()
        await model.waitForCurrentOperation()
        XCTAssertEqual(model.selectedItemIDs, ["app"])
        model.setSelected("app", selected: false)
        model.setSelected("blocked", selected: true)
        model.setSelected("cache", selected: true)
        XCTAssertEqual(model.selectedItemIDs, ["app", "cache"])
    }

    func testSelectingDependencyWithoutParentIsRejectedAndRemovingParentDropsDependents() async {
        let plan = fixturePlan(items: [fixtureItem("parent"), fixtureItem("child", dependencies: ["parent"])])
        let model = MaintenanceModel(actions: fixtureActions(scan: { _ in plan }))
        model.scanClean()
        await model.waitForCurrentOperation()
        model.setSelected("child", selected: true)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        model.setSelected("parent", selected: true)
        model.setSelected("child", selected: true)
        model.setSelected("parent", selected: false)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
    }

    func testOnlyFinalConfirmationSendsExactSelectedIDsOnce() async {
        let recorder = ApplyRecorder()
        let model = MaintenanceModel(actions: fixtureActions(apply: { planID, ids, _ in await recorder.record(planID, ids: ids); return fixtureResult() }))
        model.scanClean()
        await model.waitForCurrentOperation()
        model.setSelected("cache", selected: true)
        model.confirmExecution()
        let initialCount = await recorder.count()
        XCTAssertEqual(initialCount, 0)
        model.requestConfirmation()
        XCTAssertEqual(model.confirmation?.itemIDs, ["cache"])
        let confirmationCount = await recorder.count()
        XCTAssertEqual(confirmationCount, 0)
        model.confirmExecution()
        model.confirmExecution()
        await model.waitForCurrentOperation()
        let finalCount = await recorder.count()
        let finalIDs = await recorder.ids()
        XCTAssertEqual(finalCount, 1)
        XCTAssertEqual(finalIDs, ["cache"])
        XCTAssertEqual(model.result?.status, .completed)
    }

    func testSelectionChangeAndNewScanInvalidateConfirmation() async {
        let model = MaintenanceModel(actions: fixtureActions())
        model.scanClean()
        await model.waitForCurrentOperation()
        model.setSelected("cache", selected: true)
        model.requestConfirmation()
        XCTAssertNotNil(model.confirmation)
        model.setSelected("cache", selected: false)
        XCTAssertNil(model.confirmation)
        model.setSelected("cache", selected: true)
        model.requestConfirmation()
        model.scanClean()
        XCTAssertNil(model.confirmation)
        await model.waitForCurrentOperation()
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
    }

    func testIncompletePlanCannotBeConfirmed() async {
        let model = MaintenanceModel(actions: fixtureActions(scan: { _ in fixturePlan(complete: false) }))
        model.scanClean()
        await model.waitForCurrentOperation()
        model.setSelected("cache", selected: true)
        model.requestConfirmation()
        XCTAssertNil(model.confirmation)
        XCTAssertFalse(model.canConfirm)
    }

    func testCancellingApplyWaitsAndPreservesFinalCancelledResult() async {
        let gate = ApplyGate()
        let model = MaintenanceModel(actions: fixtureActions(apply: { _, _, _ in await gate.wait() }))
        model.scanClean()
        await model.waitForCurrentOperation()
        model.setSelected("cache", selected: true)
        model.requestConfirmation()
        model.confirmExecution()
        await gate.waitUntilStarted()
        model.cancel()
        XCTAssertEqual(model.phase, .cancelling)
        XCTAssertTrue(model.isBusy)
        XCTAssertNil(model.result)
        await gate.finish(fixtureResult(status: .cancelled))
        await model.waitForCurrentOperation()
        XCTAssertEqual(model.result?.status, .cancelled)
        XCTAssertFalse(model.isBusy)
    }

    func testExecutionProgressCountsDistinctSelectedResultsAndWaitsForFinalResult() async {
        let gate = ApplyGate()
        let plan = fixturePlan(items: [fixtureItem("first"), fixtureItem("second"), fixtureItem("unselected")])
        let model = MaintenanceModel(actions: fixtureActions(scan: { _ in plan }, apply: { _, _, callback in await gate.wait(onEvent: callback) }))
        model.scanClean()
        await model.waitForCurrentOperation()
        model.setSelected("first", selected: true)
        model.setSelected("second", selected: true)
        model.requestConfirmation()
        XCTAssertNil(model.executionProgress, "确认清单还不是执行进度")
        model.confirmExecution()
        await gate.waitUntilStarted()
        XCTAssertTrue(model.isExecuting)
        XCTAssertEqual(model.processedItemCount, 0)
        XCTAssertEqual(model.executionProgress, 0)

        await gate.emit(fixtureProgressEvent(1, message: "未选项目结果", item: fixtureItemResult("unselected", outcome: .trashed)))
        await waitForProgressMessage("未选项目结果", in: model)
        XCTAssertEqual(model.processedItemCount, 0, "未选项目不计入本次执行进度")
        let failed = fixtureItemResult("first", outcome: .failed)
        await gate.emit(fixtureProgressEvent(2, message: "第一项处理完成", item: failed))
        await waitForProgressMessage("第一项处理完成", in: model)
        XCTAssertEqual(model.processedItemCount, 1)
        XCTAssertEqual(model.executionProgress, 0.5, "失败项目也已处理，进度不能冒充成功率")
        await gate.emit(fixtureProgressEvent(3, message: "重复第一项结果", item: failed))
        await waitForProgressMessage("重复第一项结果", in: model)
        XCTAssertEqual(model.processedItemCount, 1)
        XCTAssertEqual(model.executionProgress, 0.5)
        let skipped = fixtureItemResult("second", outcome: .skipped)
        await gate.emit(fixtureProgressEvent(4, message: "第二项处理完成", item: skipped))
        await waitForProgressMessage("第二项处理完成", in: model)
        XCTAssertEqual(model.processedItemCount, 2)
        XCTAssertEqual(model.executionProgress, 1)
        XCTAssertTrue(model.isExecuting, "项目结果齐全后仍须等待最终结果")
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.phase, .applying)
        XCTAssertNil(model.result)
        await gate.finish(fixtureResult(status: .partial, items: [failed, skipped]))
        await model.waitForCurrentOperation()
        XCTAssertFalse(model.isExecuting)
        XCTAssertNil(model.executionProgress)
        XCTAssertEqual(model.result?.status, .partial)
        XCTAssertEqual(model.result?.items.map(\.outcome), [.failed, .skipped])
    }

    func testCancellationPreservesProgressAndIgnoresLateProgressMessage() async {
        let gate = ApplyGate()
        let plan = fixturePlan(items: [fixtureItem("first"), fixtureItem("second")])
        let model = MaintenanceModel(actions: fixtureActions(scan: { _ in plan }, apply: { _, _, callback in await gate.wait(onEvent: callback) }))
        model.scanClean()
        await model.waitForCurrentOperation()
        model.setSelected("first", selected: true)
        model.setSelected("second", selected: true)
        model.requestConfirmation()
        model.confirmExecution()
        await gate.waitUntilStarted()
        let finished = fixtureItemResult("first", outcome: .trashed)
        await gate.emit(fixtureProgressEvent(1, message: "第一项处理完成", item: finished))
        await waitForProgressMessage("第一项处理完成", in: model)
        model.cancel()
        let cancellationMessage = model.progressMessage
        XCTAssertEqual(model.phase, .cancelling)
        XCTAssertTrue(model.isExecuting)
        XCTAssertEqual(model.processedItemCount, 1)
        XCTAssertEqual(model.executionProgress, 0.5)
        XCTAssertTrue(cancellationMessage.contains("正在取消"))
        await gate.emit(fixtureProgressEvent(2, message: "迟到的正常执行进度"))
        let cancelled = fixtureItemResult("second", outcome: .cancelled)
        await gate.emit(fixtureProgressEvent(3, item: cancelled))
        for _ in 0..<2_000 {
            if model.itemResults.contains(cancelled) { break }
            await Task.yield()
        }
        XCTAssertTrue(model.itemResults.contains(cancelled), "取消期间仍应接收实际项目结果")
        XCTAssertEqual(model.progressMessage, cancellationMessage)
        XCTAssertEqual(model.processedItemCount, 2)
        XCTAssertEqual(model.executionProgress, 1)
        XCTAssertTrue(model.isExecuting)
        XCTAssertNil(model.result)
        await gate.finish(fixtureResult(status: .cancelled, items: [finished, cancelled]))
        await model.waitForCurrentOperation()
        XCTAssertFalse(model.isExecuting)
        XCTAssertNil(model.executionProgress)
        XCTAssertEqual(model.result?.status, .cancelled)
    }

    func testFailedHistoryDoesNotShowStaleSuccess() async {
        let model = MaintenanceModel(actions: fixtureActions(history: { throw FixtureError.failed }))
        model.reloadHistory()
        await model.waitForCurrentOperation()
        XCTAssertTrue(model.history.isEmpty)
        guard case .failed = model.historyPhase else { return XCTFail("记录读取失败应显示错误") }
    }

    func testProtectionChangeExpiresCurrentPlanAndClearsConfirmation() async {
        let model = MaintenanceModel(actions: fixtureActions())
        model.scanClean()
        await model.waitForCurrentOperation()
        model.setSelected("cache", selected: true)
        model.requestConfirmation()
        model.changeProtection(path: "/fixture/cache", protected: true)
        await model.waitForCurrentOperation()
        XCTAssertTrue(model.planExpired)
        XCTAssertNil(model.confirmation)
        XCTAssertFalse(model.canConfirm)
    }

    func testM1RequestsStayBlockedUntilMaintenanceApplyFinishes() async {
        let gate = ApplyGate()
        let maintenance = MaintenanceModel(actions: fixtureActions(apply: { _, _, _ in await gate.wait() }))
        let applicationQueries = MaintenanceApplicationQueries()
        let workspace = WorkspaceModel(detect: { MoleInstallation(executableURL: URL(fileURLWithPath: "/fixture/mole"), version: "1.53.0") }, applications: { _ in await applicationQueries.next() }, analyze: { _, _ in XCTFail("维护执行期间不能启动磁盘查询"); throw CancellationError() }, maintenance: maintenance)
        workspace.start()
        for _ in 0..<2000 { if !workspace.isBusy { break }; await Task.yield() }
        workspace.loadApplications()
        for _ in 0..<2000 { if !workspace.isBusy { break }; await Task.yield() }
        maintenance.scanClean()
        await maintenance.waitForCurrentOperation()
        maintenance.setSelected("cache", selected: true)
        maintenance.requestConfirmation()
        maintenance.confirmExecution()
        await gate.waitUntilStarted()
        XCTAssertFalse(workspace.canQuery)
        workspace.loadApplications()
        workspace.analyze(directory: URL(fileURLWithPath: "/fixture"))
        let queryCount = await applicationQueries.count
        XCTAssertEqual(queryCount, 1, "只允许维护前手动读取，维护期间不能新增查询")
        await gate.finish(fixtureResult())
        await maintenance.waitForCurrentOperation()
        XCTAssertTrue(workspace.canQuery)
    }

    func testTerminationWaitsForMaintenanceFinalResult() async {
        let gate = ApplyGate()
        let maintenance = MaintenanceModel(actions: fixtureActions(apply: { _, _, _ in await gate.wait() }))
        let workspace = WorkspaceModel(maintenance: maintenance)
        maintenance.scanClean()
        await maintenance.waitForCurrentOperation()
        maintenance.setSelected("cache", selected: true)
        maintenance.requestConfirmation()
        maintenance.confirmExecution()
        await gate.waitUntilStarted()
        var completed = false
        let shutdown = Task { await workspace.prepareToTerminate(cancelMaintenance: true); completed = true }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(completed)
        XCTAssertEqual(maintenance.phase, .cancelling)
        await gate.finish(fixtureResult(status: .partial))
        await shutdown.value
        XCTAssertTrue(completed)
        XCTAssertEqual(maintenance.result?.status, .partial)
    }

    func testFailureAfterApplyStartsIsPendingReviewInsteadOfSuccess() async {
        let model = MaintenanceModel(actions: fixtureActions(apply: { _, _, _ in throw FixtureError.failed }))
        model.scanClean()
        await model.waitForCurrentOperation()
        model.setSelected("cache", selected: true)
        model.requestConfirmation()
        model.confirmExecution()
        await model.waitForCurrentOperation()
        XCTAssertNil(model.result)
        XCTAssertTrue(model.executionUncertain)
        XCTAssertTrue(model.planExpired)
    }

    private func waitForProgressMessage(_ message: String, in model: MaintenanceModel) async {
        for _ in 0..<2_000 {
            if model.progressMessage == message { return }
            await Task.yield()
        }
        XCTFail("维护进度事件没有按预期送达")
    }
}

private enum FixtureError: Error { case failed }

private func fixtureActions(
    scan: @escaping @Sendable (@escaping @Sendable (MaintenanceEvent) -> Void) async throws -> MaintenancePlan = { _ in fixturePlan() },
    apply: @escaping @Sendable (String, [String], @escaping @Sendable (MaintenanceEvent) -> Void) async throws -> MaintenanceResult = { _, _, _ in fixtureResult() },
    history: @escaping @Sendable () async throws -> [MaintenanceResult] = { [] }
) -> MaintenanceActions {
    MaintenanceActions(
        capabilities: { EngineCapabilities(schemaVersion: 1, engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", supportedRuleIDs: ["cache"], supportedActions: [.trashItem]) },
        scanClean: scan,
        planUninstall: { _, callback in try await scan(callback) },
        apply: apply,
        history: history,
        protections: { [] },
        protect: { _ in },
        unprotect: { _ in },
        forceEnd: {}
    )
}

private func fixtureItem(_ id: String, selection: PlanSelection = .optional, kind: MaintenanceItemKind = .file, dependencies: [String] = []) -> MaintenanceItem {
    MaintenanceItem(itemID: id, ruleID: "cache", path: "/fixture/\(id)", displayName: id, kind: kind, action: .trashItem, estimatedBytes: 12, reason: "隔离测试", impact: "移入废纸篓", selection: selection, blockedReason: selection == .blocked ? "受保护" : nil, dependsOnItemIDs: dependencies)
}

private func fixturePlan(kind: MaintenanceKind = .clean, items: [MaintenanceItem] = [fixtureItem("cache")], complete: Bool = true) -> MaintenancePlan {
    MaintenancePlan(schemaVersion: 1, planID: "fixture-plan", runID: "fixture-scan", kind: kind, title: "隔离计划", engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", configurationDigest: "fixture", createdAt: Date(), scopeRoots: ["/fixture"], scanComplete: complete, scanIssues: [], items: items)
}

private func fixtureResult(status: MaintenanceStatus = .completed, items: [MaintenanceItemResult] = []) -> MaintenanceResult {
    MaintenanceResult(planID: "fixture-plan", runID: "fixture-run", title: "隔离结果", status: status, startedAt: Date(), finishedAt: Date(), items: items, selectedBytes: 12, trashedBytes: 0, freeBytesDelta: nil, message: nil)
}

private func fixtureItemResult(_ id: String, outcome: ItemOutcome) -> MaintenanceItemResult {
    MaintenanceItemResult(itemID: id, path: "/fixture/\(id)", outcome: outcome, reason: nil, trashPath: nil, retainedPath: nil, estimatedBytes: 12)
}

private func fixtureProgressEvent(_ sequence: Int, message: String? = nil, item: MaintenanceItemResult? = nil) -> MaintenanceEvent {
    MaintenanceEvent(schemaVersion: 1, runID: "fixture-run", sequence: sequence, type: item == nil ? .progress : .itemResult, message: message, candidate: nil, itemResult: item, plan: nil, applyResult: nil, error: nil)
}

private actor ApplyRecorder {
    private var calls: [(String, [String])] = []
    func record(_ plan: String, ids: [String]) { calls.append((plan, ids)) }
    func count() -> Int { calls.count }
    func ids() -> [String] { calls.first?.1 ?? [] }
}

private actor ApplyGate {
    private var continuation: CheckedContinuation<MaintenanceResult, Never>?
    private var onEvent: (@Sendable (MaintenanceEvent) -> Void)?
    func wait(onEvent: (@Sendable (MaintenanceEvent) -> Void)? = nil) async -> MaintenanceResult {
        self.onEvent = onEvent
        return await withCheckedContinuation { continuation = $0 }
    }
    func emit(_ event: MaintenanceEvent) { onEvent?(event) }
    func waitUntilStarted() async { for _ in 0..<2000 { if continuation != nil { return }; await Task.yield() } }
    func finish(_ result: MaintenanceResult) { continuation?.resume(returning: result); continuation = nil }
}

private actor MaintenanceApplicationQueries {
    private(set) var count = 0
    func next() -> [MoleApplication] { count += 1; return [] }
}
