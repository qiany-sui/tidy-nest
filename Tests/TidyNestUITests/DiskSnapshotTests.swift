import Foundation
import XCTest
@testable import TidyNest
@testable import TidyNestCore

@MainActor
final class DiskSnapshotTests: XCTestCase {
    func testRefreshKeepsReportAndSelectionUntilSuccessfulReplacement() async throws {
        let gate = DiskSnapshotGate()
        let model = await workspace(gate)
        try await loadOriginal(model, gate)
        model.analyze(directory: URL(fileURLWithPath: "/fixture/original"))
        await gate.waitForRequests(2)
        XCTAssertEqual(model.diskPhase, .loading)
        XCTAssertEqual(model.diskReport?.totalSize, 12)
        XCTAssertEqual(model.selectedDiskEntry?.name, "notes.txt")
        XCTAssertFalse(model.canAnalyzeDisk)
        await gate.finish(1, report: try report("/fixture/original", size: 24))
        await settle(model)
        XCTAssertEqual(model.diskReport?.totalSize, 24)
        XCTAssertEqual(model.selectedDiskEntry?.size, 24, "同目录刷新保留仍存在的选中项")
    }

    func testCancelledNavigationKeepsOriginalReportAndRejectsLateResult() async throws {
        let gate = DiskSnapshotGate()
        let model = await workspace(gate)
        try await loadOriginal(model, gate)
        model.analyze(directory: URL(fileURLWithPath: "/fixture/other"))
        await gate.waitForRequests(2)
        model.cancelOperation()
        XCTAssertEqual(model.diskPhase, .cancelling)
        XCTAssertEqual(model.diskReport?.path, "/fixture/original")
        XCTAssertEqual(model.selectedDiskEntry?.name, "notes.txt")
        XCTAssertFalse(model.canAnalyzeDisk)
        await gate.finish(1, report: try report("/fixture/other", size: 99))
        await settle(model)
        XCTAssertEqual(model.diskPhase, .cancelled)
        XCTAssertEqual(model.diskReport?.path, "/fixture/original")
        XCTAssertEqual(model.selectedDiskEntry?.size, 12)
        XCTAssertEqual(model.requestedDirectory?.path, "/fixture/other")
        XCTAssertTrue(model.canAnalyzeDisk)
        XCTAssertEqual(model.operationHistory.records.first?.status, .cancelled)
    }

    func testSuccessfulNavigationReplacesReportAndClearsOldSelection() async throws {
        let gate = DiskSnapshotGate()
        let model = await workspace(gate)
        try await loadOriginal(model, gate)
        model.analyze(directory: URL(fileURLWithPath: "/fixture/other"))
        await gate.waitForRequests(2)
        await gate.finish(1, report: try report("/fixture/other", size: 40))
        await settle(model)
        XCTAssertEqual(model.diskReport?.path, "/fixture/other")
        XCTAssertEqual(model.diskReport?.totalSize, 40)
        XCTAssertNil(model.selectedDiskEntryID)
        XCTAssertEqual(model.diskPhase, .loaded)
    }

    func testGoUpUsesDisplayedReportAfterFailedNavigation() async throws {
        let gate = DiskSnapshotGate()
        let model = await workspace(gate)
        try await loadOriginal(model, gate)
        model.analyze(directory: URL(fileURLWithPath: "/unreadable/deep/child"))
        await gate.waitForRequests(2)
        await gate.fail(1)
        await settle(model)
        model.goUp()
        await gate.waitForRequests(3)
        XCTAssertEqual(model.requestedDirectory?.path, "/fixture", "向上应基于仍显示的原目录，不能跳到失败目标的父目录")
        await gate.finish(2, report: try report("/fixture", size: 100))
        await settle(model)
    }

    func testRefreshDropsSelectionOnlyIfEntryDisappears() async throws {
        let gate = DiskSnapshotGate()
        let model = await workspace(gate)
        try await loadOriginal(model, gate)
        model.analyze(directory: URL(fileURLWithPath: "/fixture/original"))
        await gate.waitForRequests(2)
        let empty = try JSONDecoder().decode(MoleDiskReport.self, from: Data(#"{"path":"/fixture/original","overview":false,"entries":[],"total_size":0,"total_files":0}"#.utf8))
        await gate.finish(1, report: empty)
        await settle(model)
        XCTAssertEqual(model.diskReport?.entries.count, 0)
        XCTAssertNil(model.selectedDiskEntryID)
    }

    func testFirstReadFailureKeepsRequestedDirectoryWithoutInventingReport() async {
        let gate = DiskSnapshotGate()
        let model = await workspace(gate)
        model.analyze(directory: URL(fileURLWithPath: "/fixture/unreadable"))
        await gate.waitForRequests(1)
        await gate.fail(0)
        await settle(model)
        XCTAssertNil(model.diskReport)
        XCTAssertEqual(model.displayedDiskDirectory?.path, "/fixture/unreadable")
        guard case .failed = model.diskPhase else { return XCTFail("首次失败必须显示读取错误") }
    }

    func testRetainedRootReportKeepsUpNavigationDisabledAfterChildFailure() async throws {
        let gate = DiskSnapshotGate()
        let model = await workspace(gate)
        model.analyze(directory: URL(fileURLWithPath: "/"))
        await gate.waitForRequests(1)
        await gate.finish(0, report: try report("/", size: 12))
        await settle(model)
        model.analyze(directory: URL(fileURLWithPath: "/unreadable/child"))
        await gate.waitForRequests(2)
        XCTAssertEqual(model.displayedDiskDirectory?.path, "/")
        await gate.fail(1)
        await settle(model)
        XCTAssertEqual(model.displayedDiskDirectory?.path, "/")
        model.goUp()
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.requestedDirectory?.path, "/unreadable/child")
    }

    private func workspace(_ gate: DiskSnapshotGate) async -> WorkspaceModel {
        let model = WorkspaceModel(detect: { MoleInstallation(executableURL: URL(fileURLWithPath: "/fixture/mole"), version: "1.54.0") }, analyze: { directory, _ in try await gate.next(directory) })
        model.start()
        await settle(model)
        return model
    }

    private func loadOriginal(_ model: WorkspaceModel, _ gate: DiskSnapshotGate) async throws {
        model.analyze(directory: URL(fileURLWithPath: "/fixture/original"))
        await gate.waitForRequests(1)
        await gate.finish(0, report: try report("/fixture/original", size: 12))
        await settle(model)
        model.selectedDiskEntryID = "/fixture/original/notes.txt"
    }

    private func report(_ path: String, size: Int) throws -> MoleDiskReport {
        let json: [String: Any] = ["path": path, "overview": false, "entries": [["name": "notes.txt", "path": path + "/notes.txt", "size": size, "is_dir": false]], "total_size": size, "total_files": 1]
        return try JSONDecoder().decode(MoleDiskReport.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func settle(_ model: WorkspaceModel) async {
        for _ in 0..<2_000 {
            if !model.isBusy { return }
            await Task.yield()
        }
        XCTFail("查询未完成")
    }
}

private actor DiskSnapshotGate {
    private var pending: [CheckedContinuation<MoleDiskReport, Error>] = []
    func next(_ directory: URL) async throws -> MoleDiskReport {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func waitForRequests(_ count: Int) async {
        for _ in 0..<2_000 {
            if pending.count >= count { return }
            await Task.yield()
        }
        XCTFail("磁盘请求未到达")
    }
    func finish(_ index: Int, report: MoleDiskReport) { pending[index].resume(returning: report) }
    func fail(_ index: Int) { pending[index].resume(throwing: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "目录不可读"])) }
}
