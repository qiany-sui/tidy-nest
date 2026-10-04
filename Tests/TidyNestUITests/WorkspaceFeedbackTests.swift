import Foundation
import XCTest
@testable import TidyNest
@testable import TidyNestCore
import TidyNestProtocol

@MainActor
final class WorkspaceFeedbackTests: XCTestCase {
    func testApplicationReadRemainsVisibleAndCancellableFromAnotherPage() async {
        let gate = FeedbackGate()
        let model = WorkspaceModel(detect: { feedbackInstallation }, applications: { _ in
            await gate.wait()
            return []
        })
        model.start()
        await settle(model)
        model.loadApplications()
        await gate.waitUntilStarted()
        XCTAssertTrue(model.backgroundReadStatuses.isEmpty)
        model.page = .disk
        XCTAssertEqual(model.backgroundReadStatuses.map(\.page), [.applications])
        XCTAssertFalse(model.canAnalyzeDisk)
        XCTAssertNotNil(model.maintenanceWaitingMessage)
        model.cancelRead(on: .applications)
        XCTAssertEqual(model.backgroundReadStatuses.first?.isCancelling, true)
        XCTAssertFalse(model.canAnalyzeDisk)
        await gate.release()
        await settle(model)
        XCTAssertTrue(model.backgroundReadStatuses.isEmpty)
        XCTAssertNil(model.maintenanceWaitingMessage)
        XCTAssertTrue(model.canAnalyzeDisk)
    }

    func testDiskAndHistoryReadsHaveIndependentCrossPageCancellation() async throws {
        let disk = FeedbackGate()
        let history = FeedbackGate()
        let report = try feedbackReport()
        let maintenance = MaintenanceModel(actions: feedbackActions(history: history))
        let model = WorkspaceModel(detect: { feedbackInstallation }, analyze: { _, _ in
            await disk.wait()
            return report
        }, maintenance: maintenance)
        model.start()
        await settle(model)
        model.analyze(directory: URL(fileURLWithPath: "/fixture/disk"))
        maintenance.reloadHistory()
        await disk.waitUntilStarted()
        await history.waitUntilStarted()
        XCTAssertEqual(model.backgroundReadStatuses.map(\.page), [.disk, .history])
        model.cancelRead(on: .history)
        XCTAssertEqual(maintenance.historyPhase, .cancelling)
        XCTAssertEqual(model.diskPhase, .loading)
        await history.release()
        await maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.backgroundReadStatuses.map(\.page), [.disk])
        model.cancelRead(on: .disk)
        XCTAssertEqual(model.diskPhase, .cancelling)
        await disk.release()
        await settle(model)
        XCTAssertNil(model.diskReport)
        XCTAssertTrue(model.backgroundReadStatuses.isEmpty)
    }

    func testSingleApplicationRefreshNamesItsTargetAcrossPages() async {
        let gate = FeedbackGate()
        let app = MoleApplication(name: "示例应用", bundleIdentifier: "org.example.fixture", source: "App", uninstallName: "示例应用", path: "/fixture/示例.app", displaySize: "1 MB")
        let model = WorkspaceModel(detect: { feedbackInstallation }, applications: { _ in [app] }, refreshApplication: { original in
            await gate.wait()
            return original
        })
        model.start()
        await settle(model)
        model.loadApplications()
        await settle(model)
        model.refreshApplication(app)
        await gate.waitUntilStarted()
        model.page = .clean
        XCTAssertTrue(model.backgroundReadStatuses.first?.message.contains(app.name) == true)
        XCTAssertTrue(model.maintenanceWaitingMessage?.contains(app.name) == true)
        await gate.release()
        await settle(model)
        XCTAssertNil(model.maintenanceWaitingMessage)
    }

    private func settle(_ model: WorkspaceModel) async {
        for _ in 0..<10_000 {
            if !model.isBusy { return }
            await Task.yield()
        }
        XCTFail("隔离查询未收尾")
    }
}

@MainActor
final class DiskBrowsingTests: XCTestCase {
    func testLargeFilesUseTheirOwnSelectionAndSwitchWithoutQueryingAgain() async throws {
        let report = try feedbackReport()
        let queries = FeedbackCounter()
        let model = WorkspaceModel(detect: { feedbackInstallation }, analyze: { _, _ in
            await queries.increment()
            return report
        })
        model.start()
        await settle(model)
        model.analyze(directory: URL(fileURLWithPath: report.path))
        await settle(model)
        model.selectedDiskEntryID = "/fixture/disk/nested"
        model.diskResultMode = .largeFiles
        XCTAssertNil(model.selectedDiskEntryID)
        XCTAssertEqual(model.visibleDiskEntries.map(\.path), ["/fixture/disk/nested/large.bin", "/fixture/disk/small.bin"])
        model.selectedDiskEntryID = "/fixture/disk/nested/large.bin"
        XCTAssertEqual(model.selectedDiskEntry?.size, 90)
        XCTAssertEqual(model.selectedDiskEntry?.isDirectory, false)
        model.diskResultMode = .directory
        XCTAssertNil(model.selectedDiskEntryID)
        XCTAssertEqual(model.visibleDiskEntries.map(\.path), ["/fixture/disk/nested"])
        let count = await queries.value
        XCTAssertEqual(count, 1, "切换显示模式不能触发新读取")
    }

    func testFailedAndCancelledRefreshKeepLargeFilesModeAndSelection() async throws {
        let original = try feedbackReport()
        let gate = FeedbackGate()
        let model = WorkspaceModel(detect: { feedbackInstallation }, analyze: { directory, _ in
            if directory.path == original.path { return original }
            if directory.lastPathComponent == "cancel" { await gate.wait(); return original }
            throw NSError(domain: "fixture", code: 1)
        })
        model.start()
        await settle(model)
        model.analyze(directory: URL(fileURLWithPath: original.path))
        await settle(model)
        model.diskResultMode = .largeFiles
        model.selectedDiskEntryID = "/fixture/disk/nested/large.bin"
        model.analyze(directory: URL(fileURLWithPath: "/fixture/failure"))
        await settle(model)
        XCTAssertEqual(model.diskResultMode, .largeFiles)
        XCTAssertEqual(model.selectedDiskEntry?.size, 90)
        model.analyze(directory: URL(fileURLWithPath: "/fixture/cancel"))
        await gate.waitUntilStarted()
        model.cancelOperation()
        await gate.release()
        await settle(model)
        XCTAssertEqual(model.diskResultMode, .largeFiles)
        XCTAssertEqual(model.selectedDiskEntry?.path, "/fixture/disk/nested/large.bin")
    }

    func testSuccessfulRefreshRetainsLargeSelectionThenFallsBackWhenLargeFilesAbsent() async throws {
        let original = try feedbackReport()
        let empty = try feedbackReport(includeLargeFiles: false)
        let model = WorkspaceModel(detect: { feedbackInstallation }, analyze: { directory, _ in
            directory.lastPathComponent == "empty" ? empty : original
        })
        model.start()
        await settle(model)
        model.analyze(directory: URL(fileURLWithPath: original.path))
        await settle(model)
        model.diskResultMode = .largeFiles
        model.selectedDiskEntryID = "/fixture/disk/nested/large.bin"
        model.analyze(directory: URL(fileURLWithPath: original.path))
        await settle(model)
        XCTAssertEqual(model.diskResultMode, .largeFiles)
        XCTAssertEqual(model.selectedDiskEntry?.size, 90)
        model.analyze(directory: URL(fileURLWithPath: "/fixture/empty"))
        await settle(model)
        XCTAssertEqual(model.diskResultMode, .directory)
        XCTAssertNil(model.selectedDiskEntryID)
    }

    private func settle(_ model: WorkspaceModel) async {
        for _ in 0..<10_000 {
            if !model.isBusy { return }
            await Task.yield()
        }
        XCTFail("隔离读取未收尾")
    }
}

private let feedbackInstallation = MoleInstallation(executableURL: URL(fileURLWithPath: "/fixture/mole"), version: "1.56.1")

private func feedbackReport(includeLargeFiles: Bool = true) throws -> MoleDiskReport {
    var value: [String: Any] = ["path": "/fixture/disk", "overview": false, "total_size": 120, "total_files": 2,
        "entries": [["name": "nested", "path": "/fixture/disk/nested", "size": 100, "is_dir": true]]]
    if includeLargeFiles {
        value["large_files"] = [["name": "small.bin", "path": "/fixture/disk/small.bin", "size": 10],
            ["name": "large.bin", "path": "/fixture/disk/nested/large.bin", "size": 90]]
    }
    return try JSONDecoder().decode(MoleDiskReport.self, from: JSONSerialization.data(withJSONObject: value))
}

private func feedbackActions(history: FeedbackGate) -> MaintenanceActions {
    MaintenanceActions(capabilities: { throw CancellationError() }, scanClean: { _ in throw CancellationError() },
        planUninstall: { _, _ in throw CancellationError() }, apply: { _, _, _ in throw CancellationError() },
        history: { await history.wait(); return [] }, protections: { [] }, protect: { _ in }, unprotect: { _ in }, forceEnd: {})
}

private actor FeedbackCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor FeedbackGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        for _ in 0..<10_000 {
            if started { return }
            await Task.yield()
        }
        XCTFail("隔离任务未开始")
    }
    func release() { continuation?.resume(); continuation = nil }
}
