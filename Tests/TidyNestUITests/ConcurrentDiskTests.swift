import Foundation
import XCTest
@testable import TidyNestCore
import TidyNestProtocol
@testable import TidyNest

@MainActor
final class ConcurrentDiskTests: XCTestCase {
    func testDiskReadCompletesWhileCleanScanKeepsRunning() async {
        let scan = ConcurrentReadGate()
        let disk = ConcurrentReadGate()
        let model = await workspace(scan: scan, disk: disk)
        model.maintenance.scanClean()
        await scan.waitUntilStarted()
        model.analyze(directory: concurrentDirectory)
        XCTAssertEqual(model.diskPhase, .loading, "清理检查不能禁用磁盘读取")
        await disk.release()
        await waitForDisk(model)
        XCTAssertEqual(model.diskReport?.totalSize, 120)
        XCTAssertEqual(model.maintenance.phase, .scanning)
        XCTAssertTrue(model.isBusy)
        await scan.release()
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.maintenance.phase, .ready)
        XCTAssertEqual(Set(model.operationHistory.records.map(\.kind)), [.diskAnalysis, .cleanScan])
        XCTAssertEqual(model.operationHistory.records.count, 2)
        XCTAssertFalse(model.isBusy)
    }

    func testCleanScanStartsWhileDiskReadKeepsRunning() async {
        let scan = ConcurrentReadGate()
        let disk = ConcurrentReadGate()
        let model = await workspace(scan: scan, disk: disk)
        model.analyze(directory: concurrentDirectory)
        await disk.waitUntilStarted()
        model.maintenance.scanClean()
        XCTAssertEqual(model.maintenance.phase, .scanning, "先读取磁盘，也应能开始清理检查")
        await scan.release()
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.maintenance.phase, .ready)
        XCTAssertEqual(model.diskPhase, .loading)
        model.analyze(directory: URL(fileURLWithPath: "/fixture/another"))
        XCTAssertEqual(model.requestedDirectory, concurrentDirectory, "同一磁盘任务收尾前不能重复查询")
        await disk.release()
        await waitForDisk(model)
        XCTAssertEqual(model.operationHistory.records.count, 2)
    }

    func testCachedApplicationCanBeCheckedDuringDiskRead() async {
        let scan = ConcurrentReadGate()
        let disk = ConcurrentReadGate()
        let model = await workspace(scan: scan, disk: disk)
        model.loadApplications()
        for _ in 0..<2000 { if model.applicationsPhase != .loading { break }; await Task.yield() }
        model.analyze(directory: concurrentDirectory)
        await disk.waitUntilStarted()
        XCTAssertTrue(model.canPlanUninstall(concurrentApplication))
        model.openUninstallPlan(concurrentApplication)
        XCTAssertEqual(model.page, .clean)
        XCTAssertEqual(model.maintenance.plannedApplication, concurrentApplication)
        await scan.release()
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.maintenance.plan?.kind, .uninstall)
        XCTAssertEqual(model.diskPhase, .loading)
        await disk.release()
        await waitForDisk(model)
        XCTAssertEqual(model.operationHistory.records.filter { $0.kind == .uninstallPlan }.count, 1)
    }

    func testCancellingDiskDoesNotCancelScanOrAcceptLateDiskResult() async {
        let scan = ConcurrentReadGate()
        let disk = ConcurrentReadGate()
        let model = await workspace(scan: scan, disk: disk)
        model.maintenance.scanClean()
        await scan.waitUntilStarted()
        model.analyze(directory: concurrentDirectory)
        XCTAssertEqual(model.diskPhase, .loading)
        model.cancelOperation()
        XCTAssertEqual(model.diskPhase, .cancelling)
        XCTAssertEqual(model.maintenance.phase, .scanning)
        await disk.release()
        await waitForDisk(model)
        XCTAssertEqual(model.diskPhase, .cancelled)
        XCTAssertNil(model.diskReport)
        XCTAssertTrue(model.maintenance.isBusy)
        await scan.release()
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.maintenance.phase, .ready)
        XCTAssertEqual(model.operationHistory.records.filter { $0.kind == .diskAnalysis }.first?.status, .cancelled)
        XCTAssertEqual(model.operationHistory.records.count, 2)
    }

    func testCancellingScanDoesNotCancelDiskOrAcceptLatePlan() async {
        let scan = ConcurrentReadGate()
        let disk = ConcurrentReadGate()
        let model = await workspace(scan: scan, disk: disk)
        model.analyze(directory: concurrentDirectory)
        await disk.waitUntilStarted()
        model.maintenance.scanClean()
        XCTAssertEqual(model.maintenance.phase, .scanning)
        model.maintenance.cancel()
        await scan.release()
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.maintenance.phase, .cancelled)
        XCTAssertNil(model.maintenance.plan)
        XCTAssertEqual(model.diskPhase, .loading)
        await disk.release()
        await waitForDisk(model)
        XCTAssertEqual(model.diskReport?.totalSize, 120)
        XCTAssertEqual(model.operationHistory.records.filter { $0.kind == .cleanScan }.first?.status, .cancelled)
        XCTAssertEqual(model.operationHistory.records.count, 2)
    }

    func testDiskCancellationBeforeScanDispatchDoesNotDelayScan() async {
        let scan = ConcurrentReadGate()
        let disk = ConcurrentReadGate()
        let model = await workspace(scan: scan, disk: disk)
        model.analyze(directory: concurrentDirectory)
        await disk.waitUntilStarted()
        model.maintenance.scanClean()
        model.cancelOperation()
        await scan.release()
        for _ in 0..<2000 { if model.maintenance.phase == .ready { break }; await Task.yield() }
        XCTAssertEqual(model.maintenance.phase, .ready, "已获准的独立检查不应等待磁盘取消收尾")
        XCTAssertEqual(model.diskPhase, .cancelling)
        await disk.release()
        await waitForDisk(model)
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.diskPhase, .cancelled)
    }

    func testScanFailureKeepsSuccessfulDiskResultAndBothRecords() async {
        let scan = ConcurrentReadGate()
        let disk = ConcurrentReadGate()
        let model = await workspace(scan: scan, disk: disk, scanFails: true)
        model.maintenance.scanClean()
        await scan.waitUntilStarted()
        model.analyze(directory: concurrentDirectory)
        await disk.release()
        await waitForDisk(model)
        await scan.release()
        await model.maintenance.waitForCurrentOperation()
        guard case .failed = model.maintenance.phase else { return XCTFail("检查应报告失败") }
        XCTAssertEqual(model.diskReport?.totalSize, 120)
        XCTAssertEqual(model.operationHistory.records.filter { $0.kind == .cleanScan }.first?.status, .failed)
        XCTAssertEqual(model.operationHistory.records.filter { $0.kind == .diskAnalysis }.first?.status, .completed)
    }

    func testExecutionWaitsForDiskIncludingCancellationCleanup() async {
        let scan = ConcurrentReadGate()
        let disk = ConcurrentReadGate()
        await scan.release()
        let model = await workspace(scan: scan, disk: disk)
        let maintenance = model.maintenance
        maintenance.scanClean()
        await maintenance.waitForCurrentOperation()
        maintenance.setSelected("cache", selected: true)
        maintenance.requestConfirmation()
        XCTAssertNotNil(maintenance.confirmation)
        model.analyze(directory: concurrentDirectory)
        await disk.waitUntilStarted()
        XCTAssertFalse(maintenance.canConfirm)
        maintenance.confirmExecution()
        XCTAssertFalse(maintenance.isExecuting)
        model.cancelOperation()
        XCTAssertFalse(maintenance.canConfirm, "取消磁盘读取后仍应等待进程收尾")
        maintenance.confirmExecution()
        XCTAssertNil(maintenance.result)
        await disk.release()
        await waitForDisk(model)
        XCTAssertTrue(maintenance.canConfirm)
        maintenance.confirmExecution()
        await maintenance.waitForCurrentOperation()
        XCTAssertEqual(maintenance.result?.status, .completed)
    }

    func testNewScanRemainsBlockedUntilCancelledDiskFinishesCleanup() async {
        let scan = ConcurrentReadGate()
        let disk = ConcurrentReadGate()
        let model = await workspace(scan: scan, disk: disk)
        model.analyze(directory: concurrentDirectory)
        await disk.waitUntilStarted()
        model.cancelOperation()
        model.maintenance.scanClean()
        XCTAssertEqual(model.maintenance.phase, .idle)
        await disk.release()
        await waitForDisk(model)
        model.maintenance.scanClean()
        XCTAssertEqual(model.maintenance.phase, .scanning)
        await scan.release()
        await model.maintenance.waitForCurrentOperation()
    }

    func testTerminationCancelsBothBeforeWaitingForCleanup() async {
        let scan = ConcurrentReadGate()
        let disk = ConcurrentReadGate()
        let model = await workspace(scan: scan, disk: disk)
        model.maintenance.scanClean()
        await scan.waitUntilStarted()
        model.analyze(directory: concurrentDirectory)
        XCTAssertEqual(model.diskPhase, .loading)
        var completed = false
        let shutdown = Task { await model.prepareToTerminate(); completed = true }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(model.diskPhase, .cancelling)
        XCTAssertEqual(model.maintenance.phase, .cancelling, "退出时应同时发出取消，不等待磁盘后才取消检查")
        XCTAssertFalse(completed)
        model.analyze(directory: URL(fileURLWithPath: "/fixture/rejected"))
        model.maintenance.scanClean()
        XCTAssertEqual(model.requestedDirectory, concurrentDirectory)
        await scan.release()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(completed, "还需等待磁盘任务收尾")
        await disk.release()
        await shutdown.value
        XCTAssertTrue(completed)
        XCTAssertEqual(model.diskPhase, .cancelled)
        XCTAssertEqual(model.maintenance.phase, .cancelled)
        XCTAssertEqual(model.operationHistory.records.count, 2)
    }

    private func workspace(scan: ConcurrentReadGate, disk: ConcurrentReadGate, scanFails: Bool = false) async -> WorkspaceModel {
        let actions = MaintenanceActions(
            capabilities: { EngineCapabilities(schemaVersion: 1, engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", supportedRuleIDs: ["cache"], supportedActions: [.trashItem]) },
            scanClean: { _ in
                await scan.wait()
                if scanFails { throw ConcurrentReadFailure.expected }
                return concurrentPlan(.clean)
            },
            planUninstall: { application, _ in
                XCTAssertEqual(application, concurrentApplication)
                await scan.wait()
                return concurrentPlan(.uninstall)
            },
            apply: { planID, ids, _ in
                XCTAssertEqual(planID, "concurrent-plan")
                XCTAssertEqual(ids, ["cache"])
                return MaintenanceResult(planID: planID, runID: "concurrent-apply", title: "隔离执行结果", status: .completed, startedAt: Date(), finishedAt: Date(), items: [], selectedBytes: 12, trashedBytes: 0, freeBytesDelta: nil, message: nil)
            },
            history: { [] }, protections: { [] }, protect: { _ in }, unprotect: { _ in }, forceEnd: {}
        )
        let model = WorkspaceModel(
            detect: { MoleInstallation(executableURL: URL(fileURLWithPath: "/fixture/mole"), version: "1.53.0") },
            applications: { _ in [concurrentApplication] },
            analyze: { directory, _ in
                XCTAssertEqual(directory, concurrentDirectory)
                await disk.wait()
                return try JSONDecoder().decode(MoleDiskReport.self, from: Data(#"{"path":"/fixture/disk","overview":false,"total_size":120,"total_files":1,"entries":[]}"#.utf8))
            },
            maintenance: MaintenanceModel(actions: actions)
        )
        model.start()
        for _ in 0..<2000 { if !model.isBusy { break }; await Task.yield() }
        XCTAssertEqual(model.connectionPhase, .loaded)
        return model
    }

    private func waitForDisk(_ model: WorkspaceModel) async {
        for _ in 0..<2000 {
            if model.diskPhase != .loading && model.diskPhase != .cancelling { return }
            await Task.yield()
        }
        XCTFail("磁盘读取没有按预期结束")
    }
}

private let concurrentDirectory = URL(fileURLWithPath: "/fixture/disk")
private let concurrentApplication = MoleApplication(name: "示例应用", bundleIdentifier: "com.example.concurrent", source: "App", uninstallName: "示例应用", path: "/fixture/Example.app", displaySize: "1 MB")
private enum ConcurrentReadFailure: Error { case expected }

private func concurrentPlan(_ kind: MaintenanceKind) -> MaintenancePlan {
    let item = MaintenanceItem(itemID: "cache", ruleID: "cache", path: "/fixture/cache", displayName: "隔离缓存", kind: .file, action: .trashItem, estimatedBytes: 12, reason: "隔离并发测试", impact: "只使用注入结果", selection: .optional, blockedReason: nil, dependsOnItemIDs: [])
    return MaintenancePlan(schemaVersion: 1, planID: "concurrent-plan", runID: "concurrent-scan", kind: kind, title: "隔离检查", engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", configurationDigest: "fixture", createdAt: Date(), scopeRoots: ["/fixture"], scanComplete: true, scanIssues: [], items: [item])
}

private actor ConcurrentReadGate {
    private var started = false
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations = []
    }

    func waitUntilStarted() async {
        for _ in 0..<2000 { if started { return }; await Task.yield() }
        XCTFail("隔离读取任务未启动")
    }
}
