import Foundation
import XCTest
import TidyNestProtocol
@testable import TidyNest
@testable import TidyNestCore

@MainActor
final class ApplicationRemovalSyncTests: XCTestCase {
    func testTrashedApplicationDisappearsFromListDetailsAndPersistedSnapshot() async throws {
        let fixture = try RemovalSyncFixture()
        let model = fixture.workspace()
        model.start()
        await settle(model)
        model.searchText = "Fixture"
        model.selectedApplicationID = fixture.application.id
        model.refreshApplication(fixture.application)
        await settle(model)
        XCTAssertNotNil(model.applicationRefreshTarget)
        await execute(model, application: fixture.application)
        model.page = .applications
        XCTAssertEqual(model.applications, [fixture.other])
        XCTAssertNil(model.selectedApplicationID)
        XCTAssertNil(model.selectedApplication)
        XCTAssertNil(model.applicationRefreshTarget)
        XCTAssertEqual(model.applicationRefreshPhase, .idle)
        XCTAssertEqual(model.searchText, "Fixture")
        XCTAssertEqual(model.applicationsUpdatedAt, removalSnapshotDate)
        XCTAssertEqual(model.applicationsPhase, .idle)
        XCTAssertEqual(fixture.cache.load(), ApplicationListSnapshot(applications: [fixture.other], updatedAt: removalSnapshotDate))
        let reopened = fixture.workspace()
        reopened.start()
        await settle(reopened)
        XCTAssertEqual(reopened.applications, [fixture.other])
        XCTAssertEqual(reopened.applicationsUpdatedAt, removalSnapshotDate)
    }

    func testConfirmedBodyRemovalSurvivesPartialCancelledAndUnknownOverallStatus() async throws {
        for status in [MaintenanceStatus.partial, .cancelled, .unknown] {
            let fixture = try RemovalSyncFixture()
            let result = fixture.result(status: status, outcome: .trashed)
            let model = fixture.workspace(apply: { _, _, _ in result })
            model.start()
            await settle(model)
            model.selectedApplicationID = fixture.other.id
            await execute(model, application: fixture.application)
            XCTAssertEqual(model.applications, [fixture.other], "整体状态 \(status) 不应覆盖已确认的本体结果")
            XCTAssertEqual(model.selectedApplication, fixture.other)
            XCTAssertEqual(fixture.cache.load()?.applications, [fixture.other])
        }
    }

    func testUnconfirmedBodyOutcomesKeepApplicationAndCache() async throws {
        for outcome in [ItemOutcome.failed, .skipped, .cancelled, .unknown] {
            let fixture = try RemovalSyncFixture()
            let before = try Data(contentsOf: fixture.cacheURL)
            let result = fixture.result(status: .partial, outcome: outcome)
            let model = fixture.workspace(apply: { _, _, _ in result })
            model.start()
            await settle(model)
            model.selectedApplicationID = fixture.application.id
            await execute(model, application: fixture.application)
            XCTAssertEqual(model.applications, [fixture.application, fixture.other])
            XCTAssertEqual(model.selectedApplication, fixture.application)
            XCTAssertEqual(try Data(contentsOf: fixture.cacheURL), before)
        }
    }

    func testOnlyMatchingApplicationItemInFinalUninstallResultUpdatesList() async throws {
        for mismatch in ["plan", "item", "path", "file", "clean"] {
            let fixture = try RemovalSyncFixture()
            let plan = fixture.plan(kind: mismatch == "clean" ? .clean : .uninstall, itemKind: mismatch == "file" ? .file : .application)
            let result = fixture.result(status: .completed, outcome: .trashed,
                planID: mismatch == "plan" ? "other-plan" : "removal-plan",
                itemID: mismatch == "item" ? "other-item" : "body",
                path: mismatch == "path" ? fixture.other.path : fixture.application.path)
            let model = fixture.workspace(plan: plan, apply: { _, _, _ in result })
            model.start()
            await settle(model)
            await execute(model, application: fixture.application)
            XCTAssertEqual(model.applications, [fixture.application, fixture.other], mismatch)
            XCTAssertEqual(fixture.cache.load()?.applications, [fixture.application, fixture.other], mismatch)
        }
    }

    func testProgressBeforeApplyThrowsDoesNotRemoveApplication() async throws {
        let fixture = try RemovalSyncFixture()
        let gate = RemovalSyncGate()
        let progress = fixture.result(status: .completed, outcome: .trashed).items[0]
        let model = fixture.workspace(apply: { _, _, event in
            event(MaintenanceEvent(schemaVersion: 1, runID: "removal-run", sequence: 1, type: .itemResult,
                message: nil, candidate: nil, itemResult: progress, plan: nil, applyResult: nil, error: nil))
            return try await gate.wait()
        })
        model.start()
        await settle(model)
        model.openUninstallPlan(fixture.application)
        await model.maintenance.waitForCurrentOperation()
        model.maintenance.requestConfirmation()
        model.maintenance.confirmExecution()
        await gate.waitUntilStarted()
        for _ in 0..<2_000 {
            if model.maintenance.itemResults.contains(progress) { break }
            await Task.yield()
        }
        XCTAssertTrue(model.maintenance.itemResults.contains(progress))
        XCTAssertEqual(model.applications, [fixture.application, fixture.other])
        await gate.finish(.failure(RemovalSyncError.fixture))
        await model.maintenance.waitForCurrentOperation()
        XCTAssertTrue(model.maintenance.executionUncertain)
        XCTAssertEqual(model.applications, [fixture.application, fixture.other])
        XCTAssertEqual(fixture.cache.load()?.applications, [fixture.application, fixture.other])
    }

    func testInterruptedBridgeKeepsConfirmedItemOutcomeWhenSynchronizingList() async throws {
        for outcome in [ItemOutcome.trashed, .unknown] {
            let fixture = try RemovalSyncFixture()
            let script = fixture.cacheURL.deletingLastPathComponent().appendingPathComponent("bridge")
            try Data("#!/bin/bash\n/bin/cat > /dev/null\n/bin/cat \"${0}.response\"\n".utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let item = fixture.result(status: .unknown, outcome: outcome).items[0]
            let event = MaintenanceEvent(schemaVersion: 1, runID: "removal-run", sequence: 1, type: .itemResult,
                message: nil, candidate: nil, itemResult: item, plan: nil, applyResult: nil, error: nil)
            var data = try MaintenanceJSON.encoder().encode(event)
            data.append(0x0A)
            try data.write(to: URL(fileURLWithPath: script.path + ".response"))
            let service = MaintenanceService(executableURL: script)
            let model = fixture.workspace(apply: { planID, ids, callback in
                try await service.apply(planID: planID, selectedItemIDs: ids, onEvent: callback)
            })
            model.start()
            await settle(model)
            await execute(model, application: fixture.application)
            XCTAssertEqual(model.maintenance.result?.status, .unknown)
            XCTAssertEqual(model.maintenance.result?.items.first?.outcome, outcome)
            XCTAssertTrue(model.maintenance.executionUncertain)
            if outcome == .trashed {
                XCTAssertEqual(model.applications, [fixture.other])
                XCTAssertEqual(fixture.cache.load()?.applications, [fixture.other])
            } else {
                XCTAssertEqual(model.applications, [fixture.application, fixture.other])
                XCTAssertEqual(fixture.cache.load()?.applications, [fixture.application, fixture.other])
            }
        }
    }

    func testCancellationKeepsWaitingAndPersistsAlreadyTrashedBody() async throws {
        let fixture = try RemovalSyncFixture()
        let gate = RemovalSyncGate()
        let model = fixture.workspace(apply: { _, _, _ in try await gate.wait() })
        model.start()
        await settle(model)
        model.openUninstallPlan(fixture.application)
        await model.maintenance.waitForCurrentOperation()
        model.maintenance.requestConfirmation()
        model.maintenance.confirmExecution()
        await gate.waitUntilStarted()
        model.maintenance.cancel()
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.applications, [fixture.application, fixture.other])
        await gate.finish(.success(fixture.result(status: .cancelled, outcome: .trashed)))
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.applications, [fixture.other])
        XCTAssertEqual(fixture.cache.load()?.applications, [fixture.other])
    }

    func testCacheWriteFailureStillUpdatesCurrentListAndShowsNotice() async throws {
        let fixture = try RemovalSyncFixture()
        let model = fixture.workspace()
        model.start()
        await settle(model)
        try FileManager.default.moveItem(at: fixture.cacheURL, to: fixture.cacheURL.appendingPathExtension("backup"))
        try FileManager.default.createDirectory(at: fixture.cacheURL, withIntermediateDirectories: false)
        await execute(model, application: fixture.application)
        XCTAssertEqual(model.applications, [fixture.other])
        XCTAssertNotNil(model.applicationCacheNotice)
        XCTAssertEqual(model.maintenance.result?.status, .completed)
    }

    private func execute(_ model: WorkspaceModel, application: MoleApplication) async {
        model.openUninstallPlan(application)
        await model.maintenance.waitForCurrentOperation()
        XCTAssertTrue(model.maintenance.canConfirm)
        model.maintenance.requestConfirmation()
        model.maintenance.confirmExecution()
        await model.maintenance.waitForCurrentOperation()
        XCTAssertEqual(model.maintenance.phase, .finished)
    }

    private func settle(_ model: WorkspaceModel) async {
        for _ in 0..<2_000 {
            if !model.isBusy { return }
            await Task.yield()
        }
        XCTFail("隔离查询未结束")
    }
}

private let removalSnapshotDate = Date(timeIntervalSince1970: 1_700_000_000)
private enum RemovalSyncError: Error { case fixture }

@MainActor
private struct RemovalSyncFixture {
    let application = MoleApplication(name: "Fixture", bundleIdentifier: "unknown", source: "App", uninstallName: "Fixture", path: "/fixture/Chosen.app", displaySize: "24 MB")
    let other = MoleApplication(name: "Fixture Other", bundleIdentifier: "unknown", source: "App", uninstallName: "Fixture Other", path: "/fixture/Other.app", displaySize: "36 MB")
    let cacheURL: URL
    let cache: ApplicationListCache

    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        cacheURL = root.appendingPathComponent("work/removal-sync-tests/\(UUID().uuidString)/applications.json")
        cache = ApplicationListCache(fileURL: cacheURL)
        try cache.save(ApplicationListSnapshot(applications: [application, other], updatedAt: removalSnapshotDate))
    }

    func plan(kind: MaintenanceKind = .uninstall, itemKind: MaintenanceItemKind = .application) -> MaintenancePlan {
        let item = MaintenanceItem(itemID: "body", ruleID: "mole.application.bundle.v1", path: application.path, displayName: application.name,
            kind: itemKind, action: .trashItem, estimatedBytes: 24, reason: "隔离本体", impact: "移入废纸篓", selection: .required,
            blockedReason: nil, dependsOnItemIDs: [], requiresAuthorization: true)
        return MaintenancePlan(schemaVersion: 1, planID: "removal-plan", runID: "scan-run", kind: kind, title: "隔离移除",
            engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", configurationDigest: "fixture",
            createdAt: Date(), scopeRoots: ["/fixture"], scanComplete: true, scanIssues: [], items: [item])
    }

    func result(status: MaintenanceStatus, outcome: ItemOutcome, planID: String = "removal-plan", itemID: String = "body", path: String? = nil) -> MaintenanceResult {
        MaintenanceResult(planID: planID, runID: "removal-run", title: "隔离移除", status: status, startedAt: Date(), finishedAt: Date(),
            items: [MaintenanceItemResult(itemID: itemID, path: path ?? application.path, outcome: outcome, reason: nil,
                trashPath: outcome == .trashed ? "/fixture/trash/Chosen.app" : nil, retainedPath: nil, estimatedBytes: 24)],
            selectedBytes: 24, trashedBytes: outcome == .trashed ? 24 : 0, freeBytesDelta: nil, message: nil)
    }

    func workspace(plan: MaintenancePlan? = nil,
        apply: (@Sendable (String, [String], @escaping @Sendable (MaintenanceEvent) -> Void) async throws -> MaintenanceResult)? = nil
    ) -> WorkspaceModel {
        let plan = plan ?? self.plan()
        let result = result(status: .completed, outcome: .trashed)
        let actions = MaintenanceActions(
            capabilities: { EngineCapabilities(schemaVersion: 1, engineVersion: "fixture", engineDigest: "fixture", rulesVersion: "fixture", supportedRuleIDs: [], supportedActions: [.trashItem]) },
            scanClean: { _ in XCTFail("不应扫描缓存"); throw RemovalSyncError.fixture },
            planUninstall: { _, _ in plan }, apply: apply ?? { _, _, _ in result }, history: { [] },
            protections: { [] }, protect: { _ in }, unprotect: { _ in }, forceEnd: {}
        )
        return WorkspaceModel(
            detect: { MoleInstallation(executableURL: URL(fileURLWithPath: "/fixture/mole"), version: "1.53.0") },
            applications: { _ in XCTFail("移除后不应全量扫描应用"); throw RemovalSyncError.fixture },
            refreshApplication: { $0 }, maintenance: MaintenanceModel(actions: actions), applicationCache: cache
        )
    }
}

private actor RemovalSyncGate {
    private var continuation: CheckedContinuation<MaintenanceResult, any Error>?
    func wait() async throws -> MaintenanceResult {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        for _ in 0..<2_000 {
            if continuation != nil { return }
            await Task.yield()
        }
        XCTFail("隔离执行未开始")
    }
    func finish(_ result: Result<MaintenanceResult, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
