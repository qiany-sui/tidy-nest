import Foundation
import XCTest
@testable import TidyNest
@testable import TidyNestCore

@MainActor
final class MoleInstallationModelTests: XCTestCase {
    func testOrdinaryDetectionStaysQuietUntilCancellationFinishes() async {
        let gate = InstallerGate()
        let maintenance = inertMaintenance()
        let model = WorkspaceModel(detect: { try await gate.run { _ in } }, applications: { _ in
            XCTFail("检测期间不能查询应用")
            return []
        }, analyze: { _, _ in
            XCTFail("检测期间不能查询磁盘")
            throw CancellationError()
        }, maintenance: maintenance)
        XCTAssertEqual(model.connectionPhase, .idle)
        XCTAssertFalse(model.showsConnectionNotice, "启动任务开始前不应闪现连接横幅")
        model.start()
        await gate.waitForRequests(1)
        XCTAssertEqual(model.connectionPhase, .loading)
        XCTAssertFalse(model.showsConnectionNotice, "普通检测进度应留在侧栏")
        XCTAssertNil(model.installation, "检测完成前不能提前显示已连接")
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canQuery)
        XCTAssertFalse(maintenance.canStart)
        model.loadApplications()
        model.analyze(directory: URL(fileURLWithPath: "/tmp"))
        maintenance.scanClean()
        XCTAssertEqual(model.applicationsPhase, .idle)
        XCTAssertEqual(model.diskPhase, .idle)
        XCTAssertEqual(maintenance.phase, .idle)
        await gate.finish(0, result: .success(installedMole()))
        await settle(model)
        XCTAssertEqual(model.connectionPhase, .loaded)
        XCTAssertEqual(model.installation, installedMole())
        XCTAssertTrue(model.canQuery)
        XCTAssertFalse(model.showsConnectionNotice)
        model.detectInstallation()
        await gate.waitForRequests(2)
        XCTAssertEqual(model.connectionPhase, .loading)
        XCTAssertFalse(model.showsConnectionNotice, "手动复检也不应挤动主内容")
        XCTAssertNil(model.installation)
        XCTAssertFalse(model.canQuery)
        model.cancelOperation()
        XCTAssertEqual(model.connectionPhase, .cancelling)
        XCTAssertTrue(model.isBusy, "取消后仍须等待检测收尾")
        XCTAssertFalse(model.canQuery)
        XCTAssertFalse(model.showsConnectionNotice)
        model.detectInstallation()
        let count = await gate.count
        XCTAssertEqual(count, 2, "取消尚未收尾时不能重新检测")
        await gate.finish(1, result: .success(installedMole()))
        await settle(model)
        XCTAssertEqual(model.connectionPhase, .cancelled)
        XCTAssertNil(model.installation, "取消后迟到的成功不能显示为已连接")
        XCTAssertFalse(model.canQuery)
        XCTAssertTrue(model.showsConnectionNotice, "取消完成后应显示重新检测入口")
    }

    func testMissingMoleOffersManualInstallationWithoutStartingIt() async {
        let gate = InstallerGate()
        let model = WorkspaceModel(detect: { throw MoleError.notInstalled }, applications: { _ in [] }, install: { try await gate.run($0) })
        model.start()
        await settle(model)
        XCTAssertTrue(model.canInstallMole)
        XCTAssertTrue(model.showsConnectionNotice, "缺失 Mole 时仍需显示安装入口")
        XCTAssertEqual(model.installPhase, .idle)
        let count = await gate.count
        XCTAssertEqual(count, 0, "检测缺失不能自动安装")
    }

    func testOtherDetectionErrorsAndUnsupportedVersionsDoNotOfferInstallation() async {
        for error in [MoleError.invalidVersion, .unsupportedVersion("99.0.0"), .processFailed(1, "network failure"), .invalidResponse("版本") ] {
            let model = WorkspaceModel(detect: { throw error }, applications: { _ in [] }, install: { _ in XCTFail("非缺失错误不应安装"); throw CancellationError() })
            model.start()
            await settle(model)
            XCTAssertFalse(model.canInstallMole)
            XCTAssertTrue(model.showsConnectionNotice, "检测失败仍需显示错误与重试入口")
            model.installMole()
            XCTAssertEqual(model.installPhase, .idle)
        }
        let model = WorkspaceModel(detect: { installedMole(version: "99.0.0") }, applications: { _ in XCTFail("未知版本不得查询应用"); return [] })
        model.start()
        await settle(model)
        XCTAssertFalse(model.canInstallMole)
        XCTAssertFalse(model.canQuery)
        XCTAssertTrue(model.showsConnectionNotice, "不支持的版本仍需明确提示")
    }

    func testSuccessfulInstallationUsesFreshDetectionInsteadOfInstallerReturnValue() async {
        let detected = InstallationDetections([.failure(.notInstalled), .success(installedMole(path: "/tmp/rechecked-mole"))])
        let model = WorkspaceModel(detect: { try await detected.next() }, applications: { _ in [] }, install: { progress in
            progress(.verifying)
            return installedMole(path: "/tmp/untrusted-installer-result")
        })
        model.start()
        await settle(model)
        model.installMole()
        await settle(model)
        let count = await detected.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(model.installation?.executableURL.path, "/tmp/rechecked-mole")
        XCTAssertEqual(model.installPhase, .loaded)
        XCTAssertTrue(model.canQuery)
        XCTAssertFalse(model.canInstallMole)
    }

    func testFailedRedetectionDoesNotTrustSuccessfulInstaller() async {
        let detected = InstallationDetections([.failure(.notInstalled), .failure(.invalidVersion)])
        let model = WorkspaceModel(detect: { try await detected.next() }, applications: { _ in [] }, install: { _ in installedMole() })
        model.start()
        await settle(model)
        model.installMole()
        await settle(model)
        XCTAssertNil(model.installation)
        XCTAssertFalse(model.canQuery)
        XCTAssertFalse(model.canInstallMole, "解析失败不等于未安装")
        guard case .failed = model.installPhase else { return XCTFail("必须显示安装后的重新检测失败") }
    }

    func testPostInstallDetectionRemainsBusyAndCancellationDiscardsItsLateResult() async {
        let firstDetection = InstallationDetections([.failure(.notInstalled)])
        let recheck = InstallerGate()
        let model = WorkspaceModel(detect: {
            if await firstDetection.count == 0 { return try await firstDetection.next() }
            return try await recheck.run { _ in }
        }, applications: { _ in [] }, install: { _ in installedMole(path: "/tmp/installer-return") })
        model.start()
        await settle(model)
        model.installMole()
        await recheck.waitForRequests(1)
        XCTAssertNil(model.installation, "重新检测结束前不能提前显示已连接")
        XCTAssertEqual(model.installPhase, .loading)
        XCTAssertEqual(model.installProgress, .checking)
        XCTAssertTrue(model.showsConnectionNotice, "安装后的复检仍属于安装进度")
        XCTAssertFalse(model.canQuery)
        model.cancelOperation()
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.installPhase, .cancelling)
        await recheck.finish(0, result: .success(installedMole()))
        await settle(model)
        XCTAssertNil(model.installation)
        XCTAssertEqual(model.installPhase, .cancelled)
        XCTAssertEqual(model.connectionPhase, .cancelled)
    }

    func testUnsupportedRedetectionCannotReportInstallationSuccess() async {
        let detected = InstallationDetections([.failure(.notInstalled), .success(installedMole(version: "99.0.0"))])
        let model = WorkspaceModel(detect: { try await detected.next() }, applications: { _ in [] }, install: { _ in installedMole() })
        model.start()
        await settle(model)
        model.installMole()
        await settle(model)
        XCTAssertFalse(model.canQuery)
        XCTAssertFalse(model.canInstallMole)
        guard case .failed = model.installPhase else { return XCTFail("未知版本不能显示安装验证成功") }
    }

    func testInstallationProgressAndAllQueriesAreMutuallyExclusive() async {
        let gate = InstallerGate()
        let detected = InstallationDetections([.failure(.notInstalled), .success(installedMole())])
        let maintenance = inertMaintenance()
        let applicationQueries = InstallationApplicationQueries()
        let model = WorkspaceModel(detect: { try await detected.next() }, applications: { _ in await applicationQueries.next() }, analyze: { _, _ in XCTFail("安装期间不能查询磁盘"); throw CancellationError() }, install: { try await gate.run($0) }, maintenance: maintenance)
        model.start()
        await settle(model)
        model.installMole()
        await gate.waitForRequests(1)
        for _ in 0..<100 { if model.installProgress == .downloading { break }; await Task.yield() }
        XCTAssertEqual(model.installProgress, .downloading)
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canInstallMole)
        XCTAssertFalse(model.canQuery)
        model.installMole()
        model.detectInstallation()
        model.loadApplications()
        model.analyze(directory: URL(fileURLWithPath: "/tmp"))
        maintenance.scanClean()
        let installCount = await gate.count
        let detectCount = await detected.count
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(detectCount, 1)
        XCTAssertEqual(maintenance.phase, .idle)
        let queriesDuringInstallation = await applicationQueries.count
        XCTAssertEqual(queriesDuringInstallation, 0)
        await gate.finish(0, result: .success(installedMole()))
        await settle(model)
        let queriesAfterInstallation = await applicationQueries.count
        XCTAssertEqual(queriesAfterInstallation, 0, "安装并重新检测成功后应等待手动读取")
        XCTAssertEqual(model.applicationsPhase, .idle)
        model.loadApplications()
        await settle(model)
        let queriesAfterManualLoad = await applicationQueries.count
        XCTAssertEqual(queriesAfterManualLoad, 1)
        XCTAssertEqual(model.applicationsPhase, .loaded)
    }

    func testFailedInstallationCanRetry() async {
        let gate = InstallerGate()
        let detected = InstallationDetections([.failure(.notInstalled), .success(installedMole())])
        let model = WorkspaceModel(detect: { try await detected.next() }, applications: { _ in [] }, install: { try await gate.run($0) })
        model.start()
        await settle(model)
        model.installMole()
        await gate.waitForRequests(1)
        await gate.finish(0, result: .failure(.processFailed(1, "下载失败")))
        await settle(model)
        guard case .failed = model.installPhase else { return XCTFail("安装失败应显示错误") }
        XCTAssertTrue(model.canInstallMole)
        model.installMole()
        await gate.waitForRequests(2)
        await gate.finish(1, result: .success(installedMole()))
        await settle(model)
        XCTAssertTrue(model.canQuery)
    }

    func testCancellationWaitsForCleanupAndIgnoresLateInstallationResult() async {
        let gate = InstallerGate()
        let detected = InstallationDetections([.failure(.notInstalled), .success(installedMole())])
        let model = WorkspaceModel(detect: { try await detected.next() }, applications: { _ in [] }, install: { try await gate.run($0) })
        model.start()
        await settle(model)
        model.installMole()
        await gate.waitForRequests(1)
        model.cancelOperation()
        XCTAssertEqual(model.installPhase, .cancelling)
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canInstallMole)
        model.installMole()
        model.detectInstallation()
        await gate.emit(0, phase: .checking)
        await gate.finish(0, result: .success(installedMole()))
        await settle(model)
        let count = await detected.count
        XCTAssertEqual(count, 1, "取消后迟到的安装成功不能启动重新检测")
        XCTAssertNil(model.installation)
        XCTAssertEqual(model.installPhase, .cancelled)
        XCTAssertTrue(model.canInstallMole)
        model.installMole()
        await gate.waitForRequests(2)
        await gate.emit(0, phase: .checking)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(model.installProgress, .downloading, "旧安装阶段不能覆盖新安装")
        await gate.finish(1, result: .success(installedMole()))
        await settle(model)
    }

    func testTerminationWaitsForInstallationCleanup() async {
        let gate = InstallerGate()
        let model = WorkspaceModel(detect: { throw MoleError.notInstalled }, applications: { _ in [] }, install: { try await gate.run($0) })
        model.start()
        await settle(model)
        model.installMole()
        await gate.waitForRequests(1)
        var finished = false
        let shutdown = Task { await model.prepareToTerminate(); finished = true }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(model.isTerminating)
        XCTAssertFalse(finished)
        XCTAssertFalse(model.canInstallMole)
        XCTAssertEqual(model.installPhase, .cancelling)
        await gate.finish(0, result: .success(installedMole()))
        await shutdown.value
        XCTAssertTrue(finished)
        XCTAssertEqual(model.installPhase, .cancelled)
        XCTAssertNil(model.installation)
    }

    func testReinstallationKeepsApplicationListUntilManualRefresh() async {
        let detected = InstallationDetections([.success(installedMole()), .failure(.notInstalled), .success(installedMole())])
        let queries = InstallationApplicationQueries()
        let previous = MoleApplication(name: "Example", bundleIdentifier: "example.app", source: "App", uninstallName: "Example", path: "/tmp/example.app", displaySize: "24 MB")
        let model = WorkspaceModel(detect: { try await detected.next() }, applications: { _ in
            _ = await queries.next()
            return [previous]
        }, install: { _ in installedMole() })
        model.start()
        await settle(model)
        model.loadApplications()
        await settle(model)
        XCTAssertEqual(model.applicationsPhase, .loaded)
        let updatedAt = model.applicationsUpdatedAt
        model.detectInstallation()
        await settle(model)
        XCTAssertTrue(model.canInstallMole)
        model.installMole()
        await settle(model)
        let queryCount = await queries.count
        XCTAssertEqual(queryCount, 1, "重新安装并验证成功不能自动刷新已有列表")
        XCTAssertEqual(model.installPhase, .loaded)
        XCTAssertEqual(model.applicationsPhase, .loaded)
        XCTAssertEqual(model.applications, [previous])
        XCTAssertEqual(model.applicationsUpdatedAt, updatedAt)
        model.loadApplications()
        await settle(model)
        let queriesAfterManualRefresh = await queries.count
        XCTAssertEqual(queriesAfterManualRefresh, 2)
        XCTAssertEqual(model.applicationsPhase, .loaded)
    }

    private func settle(_ model: WorkspaceModel) async {
        for _ in 0..<2_000 {
            if !model.isBusy { return }
            await Task.yield()
        }
        XCTFail("安装或检测未完成")
    }
}

private func installedMole(path: String = "/tmp/mole", version: String = "1.53.0") -> MoleInstallation {
    MoleInstallation(executableURL: URL(fileURLWithPath: path), version: version)
}

private actor InstallationDetections {
    private let responses: [Result<MoleInstallation, MoleError>]
    private(set) var count = 0
    init(_ responses: [Result<MoleInstallation, MoleError>]) { self.responses = responses }
    func next() throws -> MoleInstallation {
        let index = min(count, responses.count - 1)
        count += 1
        return try responses[index].get()
    }
}

private actor InstallerGate {
    private var pending: [CheckedContinuation<MoleInstallation, any Error>] = []
    private var callbacks: [@Sendable (MoleInstallPhase) -> Void] = []
    var count: Int { pending.count }
    func run(_ callback: @escaping @Sendable (MoleInstallPhase) -> Void) async throws -> MoleInstallation {
        callbacks.append(callback)
        callback(.downloading)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func waitForRequests(_ count: Int) async {
        for _ in 0..<2_000 {
            if pending.count >= count { return }
            await Task.yield()
        }
        XCTFail("安装闭包没有按预期开始")
    }
    func emit(_ index: Int, phase: MoleInstallPhase) { callbacks[index](phase) }
    func finish(_ index: Int, result: Result<MoleInstallation, MoleError>) {
        pending[index].resume(with: result.mapError { $0 as any Error })
    }
}

@MainActor
private func inertMaintenance() -> MaintenanceModel {
    MaintenanceModel(actions: MaintenanceActions(
        capabilities: { XCTFail("安装期间不能启动维护引擎"); throw MoleError.outputFailed },
        scanClean: { _ in throw MoleError.outputFailed },
        planUninstall: { _, _ in throw MoleError.outputFailed },
        apply: { _, _, _ in throw MoleError.outputFailed },
        history: { [] }, protections: { [] }, protect: { _ in }, unprotect: { _ in }, forceEnd: {}
    ))
}

private actor InstallationApplicationQueries {
    private(set) var count = 0
    func next() -> [MoleApplication] { count += 1; return [] }
}
