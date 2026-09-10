import Foundation
import XCTest
@testable import TidyNest
@testable import TidyNestCore

@MainActor
final class WorkspaceModelTests: XCTestCase {
    func testStartupUsesApplicationsPageWithoutAutomaticQueries() async {
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in XCTFail("启动、重新进入和重新检测都不能自动读取应用"); return [] }, analyze: { _, _ in XCTFail("首次启动不应扫描目录"); throw CancellationError() })
        model.start()
        await settle(model)
        XCTAssertEqual(model.page, .applications)
        XCTAssertEqual(model.maintenance.phase, .idle)
        XCTAssertEqual(model.installation, installation())
        XCTAssertEqual(model.applicationsPhase, .idle)
        XCTAssertTrue(model.applications.isEmpty)
        XCTAssertFalse(model.hasApplicationSnapshot)
        XCTAssertTrue(model.canQuery)
        model.page = .clean
        model.start()
        XCTAssertFalse(model.isBusy, "重复显示窗口不应重新扫描")
        XCTAssertEqual(model.page, .clean, "同一会话不应强制跳回默认页")
        model.detectInstallation()
        await settle(model)
        XCTAssertEqual(model.applicationsPhase, .idle)
        XCTAssertTrue(model.applications.isEmpty)
        XCTAssertEqual(model.diskPhase, .idle)
    }

    func testCancelledLateResultCannotReplaceNewApplications() async {
        let gate = ApplicationGate()
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in await gate.next() }, analyze: { _, _ in throw CancellationError() })
        model.start()
        await settle(model)
        model.loadApplications()
        await gate.waitForRequests(1)
        model.cancelOperation()
        XCTAssertEqual(model.applicationsPhase, .cancelling)
        XCTAssertTrue(model.isBusy)
        model.loadApplications()
        let pendingCount = await gate.count()
        XCTAssertEqual(pendingCount, 1, "旧请求收尾前不得启动新请求")
        await gate.finish(0, with: [application("Old", path: "/tmp/old.app")])
        await settle(model)
        XCTAssertTrue(model.applications.isEmpty, "取消后的旧结果不得显示")
        model.loadApplications()
        await gate.waitForRequests(2)
        await gate.finish(1, with: [application("New", path: "/tmp/new.app")])
        await settle(model)
        XCTAssertEqual(model.applications.map(\.name), ["New"])
        XCTAssertEqual(model.applicationsPhase, .loaded)
    }

    func testFailedRefreshKeepsPreviousApplicationsAndSelection() async {
        let requests = ApplicationResponses()
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in try await requests.next() }, analyze: { _, _ in throw CancellationError() })
        model.start()
        await settle(model)
        model.loadApplications()
        await settle(model)
        model.selectedApplicationID = "/tmp/example.app"
        model.loadApplications()
        await settle(model)
        XCTAssertEqual(model.applications.map(\.name), ["Example"])
        XCTAssertEqual(model.selectedApplicationID, "/tmp/example.app")
        guard case .failed = model.applicationsPhase else { return XCTFail("错误必须单独显示") }
    }

    func testRefreshKeepsListUntilSuccessAndDropsMissingSelection() async {
        let gate = ApplicationGate()
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in await gate.next() })
        model.start()
        await settle(model)
        model.loadApplications()
        await gate.waitForRequests(1)
        await gate.finish(0, with: [application("Old", path: "/tmp/old.app")])
        await settle(model)
        model.selectedApplicationID = "/tmp/old.app"
        model.loadApplications()
        await gate.waitForRequests(2)
        XCTAssertEqual(model.applicationsPhase, .loading)
        XCTAssertEqual(model.applications.map(\.name), ["Old"])
        XCTAssertEqual(model.selectedApplicationID, "/tmp/old.app")
        await gate.finish(1, with: [application("New", path: "/tmp/new.app")])
        await settle(model)
        XCTAssertEqual(model.applications.map(\.name), ["New"])
        XCTAssertNil(model.selectedApplicationID)
    }

    func testUnsupportedInstallationBlocksQueries() async {
        let model = WorkspaceModel(detect: { installation(version: "99.0.0") }, applications: { _ in XCTFail("未知版本不得查询"); return [] }, analyze: { _, _ in XCTFail("未知版本不得查询"); throw CancellationError() })
        model.start()
        await settle(model)
        model.loadApplications()
        model.analyze(directory: URL(fileURLWithPath: "/tmp"))
        XCTAssertFalse(model.canQuery)
        XCTAssertEqual(model.applicationsPhase, .idle)
        XCTAssertEqual(model.diskPhase, .idle)
    }

    func testDiskFailureDoesNotKeepPreviousReportOrSelection() async {
        let requests = DiskResponses()
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in [] }, analyze: { directory, _ in try await requests.next(directory) })
        model.start()
        await settle(model)
        model.analyze(directory: URL(fileURLWithPath: "/tmp/example"))
        await settle(model)
        XCTAssertEqual(model.diskReport?.totalSize, 12)
        model.selectedDiskEntryID = "/tmp/example/notes.txt"
        model.analyze(directory: URL(fileURLWithPath: "/tmp/other"))
        await settle(model)
        XCTAssertNil(model.diskReport)
        XCTAssertNil(model.selectedDiskEntryID)
        XCTAssertEqual(model.requestedDirectory?.path, "/tmp/other")
        guard case .failed = model.diskPhase else { return XCTFail("磁盘错误必须单独显示") }
    }

    func testSearchDistinguishesPathsAndHidesFilteredSelection() async {
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in
            [application("Example", path: "/tmp/one.app"), application("Example", path: "/tmp/two.app"), application("Other", path: "/tmp/other.app")]
        }, analyze: { _, _ in throw CancellationError() })
        model.start()
        await settle(model)
        model.loadApplications()
        await settle(model)
        model.searchText = "eXaMpLe"
        XCTAssertEqual(Set(model.filteredApplications.map(\.path)), ["/tmp/one.app", "/tmp/two.app"])
        model.selectedApplicationID = "/tmp/two.app"
        XCTAssertEqual(model.selectedApplication?.path, "/tmp/two.app")
        model.searchText = "Other"
        XCTAssertNil(model.selectedApplication)
    }

    func testTerminationWaitsForCurrentQueryToFinishCleanup() async {
        let gate = ApplicationGate()
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in await gate.next() }, analyze: { _, _ in throw CancellationError() })
        model.start()
        await settle(model)
        model.loadApplications()
        await gate.waitForRequests(1)
        var completed = false
        let shutdown = Task { await model.prepareToTerminate(); completed = true }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(model.isTerminating)
        XCTAssertFalse(completed, "发出取消后仍须等待查询实际收尾")
        XCTAssertFalse(model.canQuery)
        await gate.finish(0, with: [])
        await shutdown.value
        XCTAssertTrue(completed)
        XCTAssertEqual(model.applicationsPhase, .cancelled)
    }

    func testTerminationAlsoWaitsForPreviouslyCancelledQuery() async {
        let gate = ApplicationGate()
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in await gate.next() }, analyze: { _, _ in throw CancellationError() })
        model.start()
        await settle(model)
        model.loadApplications()
        await gate.waitForRequests(1)
        model.cancelOperation()
        XCTAssertTrue(model.isBusy)
        var completed = false
        let shutdown = Task { await model.prepareToTerminate(); completed = true }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(completed, "此前取消的查询仍未收尾，退出必须等待")
        await gate.finish(0, with: [])
        await shutdown.value
        XCTAssertTrue(completed)
    }

    func testCachedListIsVisibleBeforeDetectionAndSurvivesMissingMole() async throws {
        let cache = ApplicationListCache(fileURL: try cacheFixtureURL())
        let previous = ApplicationListSnapshot(applications: [application("Old", path: "/tmp/old.app")], updatedAt: Date(timeIntervalSince1970: 100))
        try cache.save(previous)
        let model = WorkspaceModel(detect: { throw MoleError.notInstalled }, applications: { _ in XCTFail("未连接时不能查询"); return [] }, applicationCache: cache)
        model.start()
        XCTAssertEqual(model.connectionPhase, .loading)
        XCTAssertEqual(model.applications, previous.applications)
        XCTAssertEqual(model.applicationsUpdatedAt, previous.updatedAt)
        XCTAssertEqual(model.applicationsPhase, .idle, "缓存不能冒充本次查询成功")
        await settle(model)
        XCTAssertTrue(model.canInstallMole)
        XCTAssertEqual(model.applications, previous.applications)
        model.page = .applications
        XCTAssertTrue(model.canPlanUninstall(previous.applications[0]), "缓存不阻止独立维护检查，依赖错误由检查流程报告")
    }

    func testManualRefreshPersistsResultAndKeepsExistingSelection() async throws {
        let cache = ApplicationListCache(fileURL: try cacheFixtureURL())
        let old = application("Old", path: "/tmp/example.app")
        let previous = ApplicationListSnapshot(applications: [old], updatedAt: Date(timeIntervalSince1970: 100))
        try cache.save(previous)
        let gate = ApplicationGate()
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in await gate.next() }, applicationCache: cache)
        model.start()
        XCTAssertEqual(model.applications, [old], "启动应直接恢复快照")
        await settle(model)
        model.page = .disk
        model.page = .applications
        model.start()
        model.detectInstallation()
        await settle(model)
        let queriesBeforeRefresh = await gate.count()
        XCTAssertEqual(queriesBeforeRefresh, 0, "恢复缓存、重新进入和检测不能自动刷新")
        XCTAssertEqual(model.applicationsPhase, .idle)
        XCTAssertEqual(model.applicationsUpdatedAt, previous.updatedAt)
        XCTAssertEqual(cache.load(), previous)
        model.selectedApplicationID = old.id
        model.searchText = "Updated"
        XCTAssertTrue(model.canPlanUninstall(old), "缓存可直接发起独立检查")
        model.loadApplications()
        await gate.waitForRequests(1)
        XCTAssertEqual(model.applications, [old])
        XCTAssertTrue(model.canPlanUninstall(old), "刷新期间仍可发起独立检查，实际派发由并发隔离用例验证")
        XCTAssertEqual(model.page, .applications)
        let updated = application("Updated", path: old.path)
        await gate.finish(0, with: [updated])
        await settle(model)
        XCTAssertEqual(model.applications, [updated])
        XCTAssertEqual(model.selectedApplication, updated)
        XCTAssertEqual(model.searchText, "Updated")
        XCTAssertEqual(cache.load()?.applications, [updated])
        XCTAssertEqual(cache.load()?.updatedAt, model.applicationsUpdatedAt)
        let queryCount = await gate.count()
        XCTAssertEqual(queryCount, 1)
        let reopened = WorkspaceModel(detect: { throw MoleError.notInstalled }, applications: { _ in XCTFail("恢复快照不能自动查询"); return [] }, applicationCache: cache)
        reopened.start()
        XCTAssertEqual(reopened.applications, [updated], "新会话应直接恢复最新快照")
        XCTAssertEqual(reopened.page, .applications, "恢复快照后新会话固定打开应用页")
        await settle(reopened)
    }

    func testCancelledRefreshCannotOverwriteSavedSnapshotWithLateResult() async throws {
        let cache = ApplicationListCache(fileURL: try cacheFixtureURL())
        let previous = ApplicationListSnapshot(applications: [application("Old", path: "/tmp/old.app")], updatedAt: Date(timeIntervalSince1970: 100))
        try cache.save(previous)
        let gate = ApplicationGate()
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in await gate.next() }, applicationCache: cache)
        model.start()
        await settle(model)
        model.loadApplications()
        await gate.waitForRequests(1)
        model.cancelOperation()
        await gate.finish(0, with: [])
        await settle(model)
        XCTAssertEqual(model.applicationsPhase, .cancelled)
        XCTAssertEqual(model.applications, previous.applications)
        XCTAssertEqual(model.applicationsUpdatedAt, previous.updatedAt)
        XCTAssertEqual(cache.load(), previous)
    }

    func testFailedManualRefreshKeepsSnapshotAndAllowsIndependentPlan() async throws {
        let cache = ApplicationListCache(fileURL: try cacheFixtureURL())
        let previous = ApplicationListSnapshot(applications: [application("Old", path: "/tmp/old.app")], updatedAt: Date(timeIntervalSince1970: 100))
        try cache.save(previous)
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in throw MoleError.invalidResponse("应用列表") }, applicationCache: cache)
        model.start()
        await settle(model)
        model.loadApplications()
        await settle(model)
        guard case .failed = model.applicationsPhase else { return XCTFail("刷新失败必须保留独立错误状态") }
        XCTAssertEqual(model.applications, previous.applications)
        XCTAssertEqual(cache.load(), previous)
        model.page = .applications
        XCTAssertTrue(model.canPlanUninstall(previous.applications[0]), "刷新失败不阻止引擎独立复核")
    }

    func testEmptyManualResultReplacesPreviousSnapshotAndRestoresWithoutQuery() async throws {
        let cache = ApplicationListCache(fileURL: try cacheFixtureURL())
        try cache.save(ApplicationListSnapshot(applications: [application("Old", path: "/tmp/old.app")], updatedAt: Date(timeIntervalSince1970: 100)))
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in [] }, applicationCache: cache)
        model.start()
        await settle(model)
        model.loadApplications()
        await settle(model)
        XCTAssertEqual(model.applicationsPhase, .loaded)
        XCTAssertTrue(model.hasApplicationSnapshot)
        XCTAssertEqual(cache.load()?.applications, [])
        model.start()
        XCTAssertFalse(model.isBusy, "成功的空列表不应被当成未读取而重复扫描")
        let reopened = WorkspaceModel(detect: { installation() }, applications: { _ in XCTFail("空快照也不能自动查询"); return [] }, applicationCache: cache)
        reopened.start()
        await settle(reopened)
        XCTAssertTrue(reopened.hasApplicationSnapshot)
        XCTAssertTrue(reopened.applications.isEmpty)
        XCTAssertEqual(reopened.applicationsUpdatedAt, model.applicationsUpdatedAt)
        XCTAssertEqual(reopened.applicationsPhase, .idle)
    }

    func testCorruptCacheWaitsForManualQuery() async throws {
        let fileURL = try cacheFixtureURL()
        try Data("broken JSON".utf8).write(to: fileURL)
        let cache = ApplicationListCache(fileURL: fileURL)
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in [application("Fresh", path: "/tmp/fresh.app")] }, applicationCache: cache)
        model.start()
        XCTAssertFalse(model.hasApplicationSnapshot)
        await settle(model)
        XCTAssertEqual(model.applicationsPhase, .idle)
        XCTAssertTrue(model.applications.isEmpty)
        XCTAssertNil(cache.load())
        model.loadApplications()
        await settle(model)
        XCTAssertEqual(model.applications.map(\.name), ["Fresh"])
        XCTAssertEqual(cache.load()?.applications.map(\.name), ["Fresh"])
    }

    func testCacheWriteFailureDoesNotHideSuccessfulQuery() async throws {
        let fileURL = try cacheFixtureURL()
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        let model = WorkspaceModel(detect: { installation() }, applications: { _ in [application("Fresh", path: "/tmp/fresh.app")] }, applicationCache: ApplicationListCache(fileURL: fileURL))
        model.start()
        await settle(model)
        model.loadApplications()
        await settle(model)
        XCTAssertEqual(model.applicationsPhase, .loaded)
        XCTAssertEqual(model.applications.map(\.name), ["Fresh"])
        XCTAssertNotNil(model.applicationCacheNotice, "保存失败应告知下次仍需重新读取")
    }

    private func settle(_ model: WorkspaceModel) async {
        for _ in 0..<2_000 {
            if !model.isBusy { return }
            await Task.yield()
        }
        XCTFail("查询未完成")
    }
}

private func installation(version: String = "1.53.0") -> MoleInstallation {
    MoleInstallation(executableURL: URL(fileURLWithPath: "/tmp/mole"), version: version)
}

private func application(_ name: String, path: String) -> MoleApplication {
    MoleApplication(name: name, bundleIdentifier: "example.app", source: "App", uninstallName: name, path: path, displaySize: "24 MB")
}

private actor ApplicationGate {
    private var pending: [CheckedContinuation<[MoleApplication], Never>] = []
    func next() async -> [MoleApplication] { await withCheckedContinuation { pending.append($0) } }
    func waitForRequests(_ count: Int) async {
        for _ in 0..<2_000 {
            if pending.count >= count { return }
            await Task.yield()
        }
    }
    func count() -> Int { pending.count }
    func finish(_ index: Int, with result: [MoleApplication]) { pending[index].resume(returning: result) }
}

private actor ApplicationResponses {
    private var count = 0
    func next() throws -> [MoleApplication] {
        count += 1
        if count == 1 { return [application("Example", path: "/tmp/example.app")] }
        throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "示例查询失败"])
    }
}

private actor DiskResponses {
    private var count = 0
    func next(_ directory: URL) throws -> MoleDiskReport {
        count += 1
        if count == 1 {
            XCTAssertEqual(directory.path, "/tmp/example")
            return try JSONDecoder().decode(MoleDiskReport.self, from: Data(#"{"path":"/tmp/example","overview":false,"entries":[{"name":"notes.txt","path":"/tmp/example/notes.txt","size":12,"is_dir":false}],"total_size":12,"total_files":1}"#.utf8))
        }
        throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "示例目录不可读取"])
    }
}

private func cacheFixtureURL() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("work/application-list-model-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("applications.json")
}
