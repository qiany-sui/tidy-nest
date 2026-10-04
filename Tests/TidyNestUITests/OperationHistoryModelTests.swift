import Foundation
import XCTest
@testable import TidyNestCore
import TidyNestProtocol
@testable import TidyNest

@MainActor
final class OperationHistoryModelTests: XCTestCase {
    func testRecordingShowsResultBeforeStartingDiskPersistence() async throws {
        let url = try historyStoreURL()
        let log = OperationHistoryModel(store: OperationHistoryStore(fileURL: url))
        log.record(historyRecord("background"))
        XCTAssertEqual(log.records.map(\.id), ["background"])
        // 入口返回前不能在主线程完成文件编码和同步落盘。
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        await log.waitForPersistence()
        XCTAssertEqual(try OperationHistoryStore(fileURL: url).load().records.map(\.id), ["background"])
    }

    func testLoadingSavedHistoryReturnsBeforeReadingSnapshot() async throws {
        let store = OperationHistoryStore(fileURL: try historyStoreURL())
        try store.save(OperationHistorySnapshot(records: [historyRecord("saved")]))
        let log = OperationHistoryModel(store: store)
        log.load()
        XCTAssertTrue(log.records.isEmpty)
        XCTAssertFalse(log.canDelete)
        XCTAssertTrue(log.isLoading)
        log.record(historyRecord("session"))
        await log.waitForPersistence()
        XCTAssertEqual(Set(log.records.map(\.id)), ["saved", "session"])
        XCTAssertEqual(Set(try store.load().records.map(\.id)), ["saved", "session"])
        XCTAssertTrue(log.canDelete)
        XCTAssertFalse(log.isLoading)
    }

    func testQueuedRecordsImportsAndDeletionKeepLateResultsAndTombstones() async throws {
        let store = OperationHistoryStore(fileURL: try historyStoreURL())
        let log = OperationHistoryModel(store: store)
        log.record(historyRecord("confirmed"))
        log.mergeExecutions([historyResult()])
        let deletion = Task { await log.removeRecords(["confirmed", "execution:history-run"]) }
        // 删除保存还未收尾时，继续收到其他只读任务的结果和重复引擎记录。
        await Task.yield()
        for index in 0..<40 {
            log.record(historyRecord("late-\(index)"))
            await Task.yield()
        }
        log.mergeExecutions([historyResult()])
        let deleted = await deletion.value
        XCTAssertTrue(deleted)
        await log.waitForPersistence()
        let saved = try store.load()
        XCTAssertEqual(Set(saved.records.map(\.id)), Set((0..<40).map { "late-\($0)" }))
        XCTAssertEqual(saved.deletedExecutionRunIDs, ["history-run"])
        let reopened = OperationHistoryModel(store: store)
        reopened.load()
        reopened.mergeExecutions([historyResult()])
        await reopened.waitForPersistence()
        XCTAssertEqual(reopened.records.count, 40)
        XCTAssertFalse(reopened.records.contains { $0.kind == .execution })
    }

    func testCancelledPersistenceWaitStillDrainsAllQueuedRecords() async throws {
        let store = OperationHistoryStore(fileURL: try historyStoreURL())
        let log = OperationHistoryModel(store: store)
        for index in 0..<12 { log.record(historyRecord("finish-\(index)")) }
        let exiting = Task { await log.waitForPersistence() }
        exiting.cancel()
        await exiting.value
        XCTAssertEqual(Set(try store.load().records.map(\.id)), Set((0..<12).map { "finish-\($0)" }))
    }

    func testHistorySelectionSurvivesPageChangesAndOnlyClearsAfterSelectedDeletion() async {
        let log = OperationHistoryModel()
        let workspace = WorkspaceModel(maintenance: MaintenanceModel(actions: historyActions(), operationHistory: log))
        log.record(historyRecord("selected"))
        log.record(historyRecord("other"))
        log.selectedRecordID = "selected"
        workspace.page = .history
        workspace.page = .applications
        workspace.page = .history
        XCTAssertEqual(log.selectedRecordID, "selected")
        let deletedOther = await log.removeRecords(["other"])
        XCTAssertTrue(deletedOther)
        XCTAssertEqual(log.selectedRecordID, "selected")
        let deletedSelected = await log.removeRecords(["selected"])
        XCTAssertTrue(deletedSelected)
        XCTAssertNil(log.selectedRecordID)
    }

    func testQueryResultsAreRecordedButStartupAndSelectionAreNot() async {
        let app = historyApp()
        let model = WorkspaceModel(detect: { historyInstallation() }, applications: { _ in [app] }, refreshApplication: { $0 }, analyze: { directory, _ in try historyDisk(directory) })
        model.start()
        await historySettle(model)
        XCTAssertTrue(model.operationHistory.records.isEmpty)
        model.loadApplications()
        await historySettle(model)
        model.selectedApplicationID = app.id
        model.searchText = app.name
        model.page = .applications
        XCTAssertEqual(model.operationHistory.records.count, 1)
        model.refreshApplication(app)
        await historySettle(model)
        model.analyze(directory: URL(fileURLWithPath: "/fixture/磁盘"))
        await historySettle(model)
        let records = model.operationHistory.records
        XCTAssertEqual(Set(records.map(\.kind)), [.applicationList, .applicationRefresh, .diskAnalysis])
        XCTAssertTrue(records.allSatisfy { $0.status == .completed && $0.finishedAt >= $0.startedAt })
        XCTAssertEqual(records.first { $0.kind == .applicationRefresh }?.targetPath, app.path)
        XCTAssertEqual(records.first { $0.kind == .diskAnalysis }?.targetPath, "/fixture/磁盘")
    }

    func testFailedQueriesRecordFailureWithoutInventingSuccess() async {
        let model = WorkspaceModel(detect: { historyInstallation() }, applications: { _ in throw HistoryTestFailure.expected }, analyze: { _, _ in throw HistoryTestFailure.expected })
        model.start()
        await historySettle(model)
        model.loadApplications()
        await historySettle(model)
        model.analyze(directory: URL(fileURLWithPath: "/fixture/failure"))
        await historySettle(model)
        XCTAssertEqual(model.operationHistory.records.count, 2)
        XCTAssertTrue(model.operationHistory.records.allSatisfy { $0.status == .failed && !$0.summary.isEmpty })
    }

    func testCancelledLateQueryCreatesExactlyOneCancellationRecord() async {
        let gate = HistoryQueryGate()
        let model = WorkspaceModel(detect: { historyInstallation() }, applications: { _ in await gate.wait() })
        model.start()
        await historySettle(model)
        model.loadApplications()
        await gate.waitUntilStarted()
        model.cancelOperation()
        model.loadApplications()
        await gate.finish()
        await historySettle(model)
        XCTAssertEqual(model.operationHistory.records.count, 1)
        XCTAssertEqual(model.operationHistory.records.first?.status, .cancelled)
        XCTAssertTrue(model.applications.isEmpty)
    }

    func testPlanChecksAndExecutionHaveDistinctRecordsAndNoDuplicateImport() async {
        let result = historyResult()
        let log = OperationHistoryModel()
        let model = MaintenanceModel(actions: historyActions(result: result), operationHistory: log)
        model.planUninstall(historyApp())
        await model.waitForCurrentOperation()
        XCTAssertEqual(log.records.first?.kind, .uninstallPlan)
        XCTAssertEqual(log.records.first?.targetPath, historyApp().path)
        model.setSelected("cache", selected: true)
        model.requestConfirmation()
        model.dismissConfirmation()
        XCTAssertEqual(log.records.count, 1)
        model.requestConfirmation()
        model.confirmExecution()
        await model.waitForCurrentOperation()
        XCTAssertEqual(log.records.filter { $0.kind == .execution }.map(\.execution), [result])
        model.reloadHistory()
        await model.waitForCurrentOperation()
        XCTAssertEqual(log.records.count, 2)
        XCTAssertEqual(log.records.filter { $0.kind == .execution }.count, 1)
    }

    func testCancellationBeforeExecutionDispatchIsRecordedAsCancelled() async {
        let model = MaintenanceModel(actions: historyActions())
        model.scanClean()
        await model.waitForCurrentOperation()
        model.setSelected("cache", selected: true)
        model.requestConfirmation()
        model.confirmExecution()
        model.cancel()
        await model.waitForCurrentOperation()
        XCTAssertEqual(model.operationHistory.records.first { $0.kind == .execution }?.status, .cancelled)
        XCTAssertFalse(model.executionUncertain)
    }

    func testMissingExecutionResultRemainsUnknown() async {
        let model = MaintenanceModel(actions: historyActions(applyError: true))
        model.scanClean()
        await model.waitForCurrentOperation()
        model.setSelected("cache", selected: true)
        model.requestConfirmation()
        model.confirmExecution()
        await model.waitForCurrentOperation()
        XCTAssertEqual(model.operationHistory.records.first { $0.kind == .execution }?.status, .unknown)
        XCTAssertTrue(model.executionUncertain)
    }

    func testIncompleteCheckIsNotReportedAsComplete() async {
        let model = MaintenanceModel(actions: historyActions(complete: false))
        model.scanClean()
        await model.waitForCurrentOperation()
        XCTAssertEqual(model.operationHistory.records.first?.kind, .cleanScan)
        XCTAssertEqual(model.operationHistory.records.first?.status, .partial)
        XCTAssertFalse(model.canConfirm)
    }

    func testCancelledPlanIsLoggedOnce() async {
        let model = MaintenanceModel(actions: historyActions(scanError: true))
        model.scanClean()
        await model.waitForCurrentOperation()
        XCTAssertEqual(model.operationHistory.records.count, 1)
        XCTAssertEqual(model.operationHistory.records.first?.status, .cancelled)
    }

    func testDeleteExactSnapshotPersistsAndDoesNotReimportExecution() async throws {
        let store = OperationHistoryStore(fileURL: try historyStoreURL())
        let log = OperationHistoryModel(store: store)
        let first = historyRecord("first")
        let execution = historyResult()
        log.record(first)
        log.mergeExecutions([execution, execution])
        let confirmedIDs = Set(log.records.map(\.id))
        log.record(historyRecord("new-after-confirmation"))
        let removed = await log.removeRecords(confirmedIDs)
        XCTAssertTrue(removed)
        XCTAssertEqual(log.records.map(\.id), ["new-after-confirmation"])
        let reopened = OperationHistoryModel(store: store)
        reopened.load()
        reopened.mergeExecutions([execution])
        await reopened.waitForPersistence()
        XCTAssertEqual(reopened.records.map(\.id), ["new-after-confirmation"])
        let clearedRecords = await reopened.removeRecords(["new-after-confirmation"])
        XCTAssertTrue(clearedRecords)
        let cleared = OperationHistoryModel(store: store)
        cleared.load()
        cleared.mergeExecutions([execution])
        await cleared.waitForPersistence()
        XCTAssertTrue(cleared.records.isEmpty)
    }

    func testSingleDeletionKeepsOtherRecordsAndUnknownSizes() async throws {
        let store = OperationHistoryStore(fileURL: try historyStoreURL())
        let log = OperationHistoryModel(store: store)
        let result = historyResult()
        log.record(historyRecord("one"))
        log.mergeExecutions([result])
        let removed = await log.removeRecords(["one"])
        XCTAssertTrue(removed)
        let reopened = OperationHistoryModel(store: store)
        reopened.load()
        await reopened.waitForPersistence()
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertNil(reopened.records.first?.execution?.items.first?.estimatedBytes)
    }

    func testDamagedStoreIsNotOverwrittenAndDeletionIsRefused() async throws {
        let url = try historyStoreURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data("damaged history".utf8)
        try damaged.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let log = OperationHistoryModel(store: OperationHistoryStore(fileURL: url))
        log.load()
        log.record(historyRecord("new"))
        await log.waitForPersistence()
        XCTAssertNotNil(log.notice)
        XCTAssertFalse(log.canDelete)
        XCTAssertFalse(log.isLoading)
        let removed = await log.removeRecords(["new"])
        XCTAssertFalse(removed)
        XCTAssertEqual(log.records.map(\.id), ["new"])
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testSuccessfulReloadPersistsSessionRecordsAfterDamagedFileRecovery() async throws {
        let url = try historyStoreURL()
        let store = OperationHistoryStore(fileURL: url)
        try Data("damaged history".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let log = OperationHistoryModel(store: store)
        log.load()
        log.record(historyRecord("session"))
        await log.waitForPersistence()
        XCTAssertFalse(log.canDelete)
        XCTAssertNotNil(log.notice)

        // 只修复本测试创建的隔离快照，不绕过正式存储对损坏文件的保护。
        try FileManager.default.removeItem(at: url)
        try store.save(OperationHistorySnapshot(records: [historyRecord("repaired")]))
        log.load()
        log.mergeExecutions([])
        await log.waitForPersistence()
        XCTAssertNil(log.notice)
        XCTAssertTrue(log.canDelete)
        XCTAssertEqual(Set(log.records.map(\.id)), ["session", "repaired"])
        XCTAssertEqual(Set(try store.load().records.map(\.id)), ["session", "repaired"])

        let reopened = OperationHistoryModel(store: store)
        reopened.load()
        await reopened.waitForPersistence()
        XCTAssertEqual(Set(reopened.records.map(\.id)), ["session", "repaired"])
    }

    func testDeleteWriteFailureKeepsVisibleRecord() async throws {
        let url = try historyStoreURL()
        let log = OperationHistoryModel(store: OperationHistoryStore(fileURL: url))
        log.record(historyRecord("keep"))
        await log.waitForPersistence()
        log.selectedRecordID = "keep"
        // 仅替换本测试创建的隔离记录文件，模拟保存目标变为目录。
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let removed = await log.removeRecords(["keep"])
        XCTAssertFalse(removed)
        XCTAssertEqual(log.records.map(\.id), ["keep"])
        XCTAssertNotNil(log.notice)
        XCTAssertEqual(log.selectedRecordID, "keep")
    }

    func testSaveFailureKeepsSessionResultsAndDoesNotOverwriteDamagedFile() async throws {
        let url = try historyStoreURL()
        let log = OperationHistoryModel(store: OperationHistoryStore(fileURL: url))
        log.record(historyRecord("previous"))
        await log.waitForPersistence()
        // 只损坏本测试建立的快照，模拟已加载之后保存遇到变更。
        let damaged = Data("damaged after load".utf8)
        try damaged.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        log.record(historyRecord("session"))
        await log.waitForPersistence()
        XCTAssertEqual(Set(log.records.map(\.id)), ["previous", "session"])
        XCTAssertNotNil(log.notice)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testHistoryRefreshFailureDoesNotEraseLocalQueryRecords() async {
        let log = OperationHistoryModel()
        log.record(historyRecord("query"))
        let model = MaintenanceModel(actions: historyActions(historyError: true), operationHistory: log)
        model.reloadHistory()
        await model.waitForCurrentOperation()
        guard case .failed = model.historyPhase else { return XCTFail("读取失败仍应明确显示") }
        XCTAssertEqual(log.records.map(\.id), ["query"])
    }
}

private enum HistoryTestFailure: Error { case expected }
private func historyApp() -> MoleApplication {
    MoleApplication(name: "示例应用", bundleIdentifier: "com.example.history", source: "App", uninstallName: "示例应用", path: "/fixture/示例应用.app", displaySize: "12 MB")
}
private func historyInstallation() -> MoleInstallation {
    MoleInstallation(executableURL: URL(fileURLWithPath: "/fixture/mole"), version: "1.53.0")
}
private func historyDisk(_ directory: URL) throws -> MoleDiskReport {
    let data = try JSONSerialization.data(withJSONObject: ["path": directory.path, "overview": false, "total_size": 12, "total_files": 1, "entries": []])
    return try JSONDecoder().decode(MoleDiskReport.self, from: data)
}
private func historyRecord(_ id: String) -> OperationRecord {
    OperationRecord(id: id, kind: .diskAnalysis, status: .completed, title: "读取磁盘", targetPath: "/fixture/\(id)", startedAt: Date(), summary: "读取完成，未修改文件。")
}
private func historyStoreURL() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("work/operation-history-model-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("operations.json")
}
private func historyResult() -> MaintenanceResult {
    let item = MaintenanceItemResult(itemID: "cache", path: "/fixture/cache", outcome: .skipped, reason: "隔离样本", trashPath: nil, retainedPath: nil, estimatedBytes: nil)
    return MaintenanceResult(planID: "history-plan", runID: "history-run", title: "维护结果", status: .blocked, startedAt: Date(timeIntervalSince1970: 1_700_000_000), finishedAt: Date(timeIntervalSince1970: 1_700_000_001), items: [item], selectedBytes: 0, trashedBytes: 0, freeBytesDelta: nil, message: "测试不移动文件")
}
private func historyActions(result: MaintenanceResult = historyResult(), complete: Bool = true, scanError: Bool = false, historyError: Bool = false, applyError: Bool = false) -> MaintenanceActions {
    let scan: @Sendable (@escaping @Sendable (MaintenanceEvent) -> Void) async throws -> MaintenancePlan = { _ in
        if scanError { throw CancellationError() }
        let item = MaintenanceItem(itemID: "cache", ruleID: "cache", path: "/fixture/cache", displayName: "缓存样本", kind: .file, action: .trashItem, estimatedBytes: nil, reason: "隔离检查", impact: "未执行移除", selection: .optional, blockedReason: nil, dependsOnItemIDs: [])
        return MaintenancePlan(schemaVersion: 1, planID: "history-plan", runID: "history-scan", kind: .clean, title: "检查计划", engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", configurationDigest: "fixture", createdAt: Date(), scopeRoots: ["/fixture"], scanComplete: complete, scanIssues: [], items: [item])
    }
    return MaintenanceActions(capabilities: { EngineCapabilities(schemaVersion: 1, engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", supportedRuleIDs: [], supportedActions: [.trashItem]) }, scanClean: scan, planUninstall: { _, callback in try await scan(callback) }, apply: { _, _, _ in if applyError { throw HistoryTestFailure.expected }; return result }, history: { if historyError { throw HistoryTestFailure.expected }; return [result] }, protections: { [] }, protect: { _ in }, unprotect: { _ in }, forceEnd: {})
}
@MainActor private func historySettle(_ model: WorkspaceModel) async {
    for _ in 0..<10000 { if !model.isBusy { return }; await Task.yield() }
    XCTFail("操作未完成收尾")
}
private actor HistoryQueryGate {
    private var continuation: CheckedContinuation<[MoleApplication], Never>?
    func wait() async -> [MoleApplication] { await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { for _ in 0..<10000 { if continuation != nil { return }; await Task.yield() } }
    func finish() { continuation?.resume(returning: [historyApp()]); continuation = nil }
}
