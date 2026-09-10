import Foundation
import Testing
import Darwin
import TidyNestProtocol
@testable import TidyNestEngine

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MaintenanceEvent] = []
    func append(_ event: MaintenanceEvent) { lock.withLock { values.append(event) } }
    var events: [MaintenanceEvent] { lock.withLock { values } }
}

private struct Fixture {
    let root: URL
    let home: URL
    let app: URL
    let cache: URL
    let trash: URL
    let bundleID: String
    init(bundleID: String = "org.example.fixture") throws {
        self.bundleID = bundleID
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/m2-engine-fixtures/" + UUID().uuidString)
        home = root.appendingPathComponent("home")
        app = home.appendingPathComponent("Applications/Fixture.app")
        cache = home.appendingPathComponent("Library/Caches/" + bundleID)
        trash = root.appendingPathComponent("trash")
        for url in [app.appendingPathComponent("Contents"), cache, trash] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Fixture"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
    }
    func file(_ name: String, _ contents: String = "fixture only") throws -> URL {
        let url = cache.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
    func context(hook: @escaping @Sendable (ExecutionBoundary, String, String) throws -> Void = { _, _, _ in }, runtime: @escaping @Sendable (EngineApplication, String) async throws -> Void = { _, _ in }, trashOperation: (@Sendable (URL) throws -> URL)? = nil) -> EngineContext {
        let application = EngineApplication(path: app.path, bundleID: bundleID, name: "Fixture", source: "app")
        let trash = trash
        return EngineContext(home: home.path, appRoots: [home.appendingPathComponent("Applications").path], catalog: { FileManager.default.fileExists(atPath: application.path) ? [application] : [] }, runtime: runtime, trash: trashOperation ?? { source in
            let destination = trash.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }, hook: hook, environment: { [:] })
    }
    func engine() -> MaintenanceEngine { MaintenanceEngine(context: context()) }
}

private func scan(_ engine: MaintenanceEngine) async throws -> MaintenancePlan {
    let box = EventBox()
    _ = try await engine.handle(command: "scan-clean", request: MaintenanceRequest(), emit: { box.append($0) })
    return try #require(box.events.last?.plan)
}
private func apply(_ engine: MaintenanceEngine, _ plan: MaintenancePlan, _ ids: [String]) async throws -> MaintenanceResult {
    let box = EventBox()
    _ = try await engine.handle(command: "apply-plan", request: MaintenanceRequest(planID: plan.planID, selectedItemIDs: ids, confirmed: true), emit: { box.append($0) })
    return try #require(box.events.last?.applyResult)
}

@Test func selectedFileOnlyAndNewFilesStay() async throws {
    let fixture = try Fixture()
    let a = try fixture.file("A.cache", "A")
    let b = try fixture.file("B.cache", "B")
    let engine = fixture.engine()
    let plan = try await scan(engine)
    #expect(plan.scanComplete)
    #expect(plan.items.count == 2)
    #expect(plan.items.allSatisfy { $0.selection == .optional })
    let c = try fixture.file("C.cache", "C")
    let selected = try #require(plan.items.first { $0.path == a.path })
    let result = try await apply(engine, plan, [selected.itemID])
    #expect(result.status == .completed)
    #expect(!FileManager.default.fileExists(atPath: a.path))
    #expect(try String(contentsOf: b, encoding: .utf8) == "B")
    #expect(try String(contentsOf: c, encoding: .utf8) == "C")
    #expect(result.items.first?.trashPath != nil)
}

@Test func scanProgressDescribesEachApplicationAndFinalVerificationBeforeReturningPlan() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("A.cache", "keep")
    let second = fixture.home.appendingPathComponent("Applications/Second.app")
    try FileManager.default.copyItem(at: fixture.app, to: second)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.second"], format: .binary, options: 0).write(to: second.appendingPathComponent("Contents/Info.plist"))
    let applications = try [
        catalogApplication(at: fixture.app.path, name: "Fixture", source: "app"),
        catalogApplication(at: second.path, name: "第二个应用", source: "app")
    ]
    let box = EventBox()
    let catalogStages = EventBox()
    let base = fixture.context()
    let context = EngineContext(home: base.home, appRoots: base.appRoots, catalog: {
        catalogStages.append(try #require(box.events.last { $0.type == .progress }))
        return applications
    }, runtime: { app, _ in
        let expected = app.path == fixture.app.path ? "正在检查 Fixture（1/2 个应用）" : "正在检查 第二个应用（2/2 个应用）"
        #expect(box.events.last { $0.type == .progress }?.message == expected)
    }, trash: base.trash, hook: base.hook, environment: base.environment)
    _ = try await MaintenanceEngine(context: context).handle(command: "scan-clean", request: MaintenanceRequest(), emit: { box.append($0) })
    #expect(box.events.filter { $0.type == .progress }.compactMap(\.message) == [
        "正在读取应用信息与保护设置…",
        "正在检查 Fixture（1/2 个应用）",
        "正在检查 第二个应用（2/2 个应用）",
        "正在复核应用状态，确认检查结果…",
        "正在整理检查结果…"
    ])
    #expect(catalogStages.events.compactMap(\.message) == ["正在读取应用信息与保护设置…", "正在复核应用状态，确认检查结果…"])
    let plan = try #require(box.events.last?.plan)
    #expect(box.events.last?.type == .result)
    #expect(plan.scanComplete)
    #expect(plan.items.map(\.path) == [target.path])
    #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
}

@Test func strictProtocolRejectsUnknownFieldsAndUnconfirmedApply() throws {
    #expect(throws: (any Error).self) { try MaintenanceJSON.request(from: Data(#"{"testRoot":"/tmp"}"#.utf8), command: "scan-clean") }
    #expect(throws: (any Error).self) { try MaintenanceJSON.request(from: Data(#"{"planID":"x","selectedItemIDs":[]}"#.utf8), command: "apply-plan") }
}

@Test func unsafeKindsAreNeverCandidates() async throws {
    let fixture = try Fixture()
    let db = try fixture.file("state.sqlite", "SQLite format 3\0sensitive")
    let original = try fixture.file("hard.cache")
    let hard = fixture.cache.appendingPathComponent("hard2.cache")
    try FileManager.default.linkItem(at: original, to: hard)
    let sym = fixture.cache.appendingPathComponent("linked.cache")
    try FileManager.default.createSymbolicLink(at: sym, withDestinationURL: db)
    let plan = try await scan(fixture.engine())
    #expect(plan.items.isEmpty)
    #expect(plan.scanIssues.count >= 3)
    #expect(FileManager.default.fileExists(atPath: db.path))
}

@Test func replacedTargetAndParentArePreserved() async throws {
    for replaceParent in [false, true] {
        let fixture = try Fixture()
        let target = try fixture.file("A.cache")
        let engine = fixture.engine()
        let plan = try await scan(engine)
        if replaceParent {
            try FileManager.default.moveItem(at: fixture.cache, to: fixture.root.appendingPathComponent("old-cache"))
            try FileManager.default.createDirectory(at: fixture.cache, withIntermediateDirectories: true)
        } else {
            try FileManager.default.moveItem(at: target, to: fixture.root.appendingPathComponent("old-file"))
        }
        try Data("replacement".utf8).write(to: target)
        let result = try await apply(engine, plan, plan.items.map(\.itemID))
        #expect(result.status != .completed)
        #expect(try String(contentsOf: target, encoding: .utf8) == "replacement")
    }
}


@Test func unknownSelectionConfigurationChangeAndRepeatAreBlocked() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("A.cache")
    let engine = fixture.engine()
    let plan = try await scan(engine)
    let unknown = try await apply(engine, plan, [UUID().uuidString])
    #expect(unknown.status == .blocked)
    #expect(FileManager.default.fileExists(atPath: target.path))
    _ = try await engine.handle(command: "protect-path", request: MaintenanceRequest(protectedPath: target.path), emit: { _ in })
    let changed = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(changed.status == .blocked)
    let protected = try await scan(engine)
    #expect(protected.items.isEmpty)
    _ = try await engine.handle(command: "unprotect-path", request: MaintenanceRequest(protectedPath: target.path), emit: { _ in })
    let fresh = try await scan(engine)
    #expect(try await apply(engine, fresh, fresh.items.map(\.itemID)).status == .completed)
    #expect(try await apply(engine, fresh, fresh.items.map(\.itemID)).status == .blocked)
}

@Test func stagingChangeRestoresWithoutTrashing() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("A.cache")
    let engine = MaintenanceEngine(context: fixture.context(hook: { stage, _, staged in
        if stage == .afterStaging { try Data("writer changed content".utf8).write(to: URL(fileURLWithPath: staged)) }
    }))
    let plan = try await scan(engine)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .failed)
    #expect(try String(contentsOf: target, encoding: .utf8) == "writer changed content")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    #expect(result.items.first?.retainedPath == target.path)
}

@Test func restoreConflictRetainsStagedObjectAndNeverOverwrites() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("A.cache", "original")
    let engine = MaintenanceEngine(context: fixture.context(hook: { stage, original, staged in
        if stage == .afterStaging {
            try Data("new original".utf8).write(to: URL(fileURLWithPath: original))
            try Data("staged mutation".utf8).write(to: URL(fileURLWithPath: staged))
        }
    }))
    let plan = try await scan(engine)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .unknown)
    #expect(try String(contentsOf: target, encoding: .utf8) == "new original")
    let retained = try #require(result.items.first?.retainedPath)
    #expect(retained.contains("/Transactions/"))
    #expect(try String(contentsOfFile: retained, encoding: .utf8) == "staged mutation")
}

@Test func trashFailureRestoresAndNextItemCanSucceed() async throws {
    let fixture = try Fixture()
    let a = try fixture.file("A.cache", "A")
    let b = try fixture.file("B.cache", "B")
    let trash = fixture.trash
    let engine = MaintenanceEngine(context: fixture.context(trashOperation: { source in
        if source.lastPathComponent == "A.cache" { throw EngineFailure("fixture Trash failure") }
        let destination = trash.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }))
    let plan = try await scan(engine)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .partial)
    #expect(try String(contentsOf: a, encoding: .utf8) == "A")
    #expect(!FileManager.default.fileExists(atPath: b.path))
    #expect(result.items.map(\.outcome) == [.failed, .trashed])
}

@Test func cancellationAccountsCurrentItemAndStopsLaterItems() async throws {
    let fixture = try Fixture()
    _ = try fixture.file("A.cache")
    let b = try fixture.file("B.cache")
    let cancellation = EngineCancellation()
    let engine = MaintenanceEngine(context: fixture.context(hook: { stage, _, _ in
        if stage == .afterTrash { cancellation.cancel() }
    }), cancellation: cancellation)
    let plan = try await scan(engine)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .partial)
    #expect(result.items.map(\.outcome) == [.trashed, .cancelled])
    #expect(FileManager.default.fileExists(atPath: b.path))
    let historyData = try #require(try await engine.handle(command: "history", request: MaintenanceRequest(), emit: { _ in }))
    let history = try MaintenanceJSON.decoder().decode([MaintenanceResult].self, from: historyData)
    #expect(history.first?.status == .partial)
}

private func uninstall(_ engine: MaintenanceEngine, fixture: Fixture) async throws -> MaintenancePlan {
    let box = EventBox()
    _ = try await engine.handle(command: "plan-uninstall", request: MaintenanceRequest(appPath: fixture.app.path, expectedBundleID: fixture.bundleID), emit: { box.append($0) })
    return try #require(box.events.last?.plan)
}

@Test func applicationBodyIsRequiredAndResidualDependsOnRealSuccess() async throws {
    let fixture = try Fixture()
    let cache = try fixture.file("A.cache")
    let engine = fixture.engine()
    let plan = try await uninstall(engine, fixture: fixture)
    let body = try #require(plan.items.first { $0.kind == .application })
    let residual = try #require(plan.items.first { $0.kind == .file })
    #expect(body.selection == .required)
    #expect(residual.dependsOnItemIDs == [body.itemID])
    #expect(try await apply(engine, plan, [residual.itemID]).status == .blocked)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .completed)
    #expect(result.items.map(\.outcome) == [.trashed, .trashed])
    #expect(!FileManager.default.fileExists(atPath: fixture.app.path))
    #expect(!FileManager.default.fileExists(atPath: cache.path))
}

@Test func failedApplicationBodyLeavesResidualUnchanged() async throws {
    let fixture = try Fixture()
    let cache = try fixture.file("A.cache", "residual")
    let engine = MaintenanceEngine(context: fixture.context(trashOperation: { _ in throw EngineFailure("fixture failure") }))
    let plan = try await uninstall(engine, fixture: fixture)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.items.map(\.outcome) == [.failed, .skipped])
    #expect(try String(contentsOf: cache, encoding: .utf8) == "residual")
    #expect(FileManager.default.fileExists(atPath: fixture.app.path))
}

@Test func applicationNewMemberAndExternalLinkPreventMoving() async throws {
    let fixture = try Fixture()
    let engine = fixture.engine()
    let plan = try await uninstall(engine, fixture: fixture)
    try Data("new member".utf8).write(to: fixture.app.appendingPathComponent("Contents/new-file"))
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .failed)
    #expect(FileManager.default.fileExists(atPath: fixture.app.path))
    try FileManager.default.createSymbolicLink(atPath: fixture.app.appendingPathComponent("Contents/external").path, withDestinationPath: "../../../outside")
    let blocked = try await uninstall(engine, fixture: fixture)
    #expect(blocked.items.first?.selection == .blocked)
}

@Test func internalFrameworkLinksAreSnapshottedWithoutFollowing() throws {
    let fixture = try Fixture()
    let versions = fixture.app.appendingPathComponent("Contents/Frameworks/Kit.framework/Versions/A")
    try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
    try Data("binary".utf8).write(to: versions.appendingPathComponent("Kit"))
    try FileManager.default.createSymbolicLink(atPath: versions.deletingLastPathComponent().appendingPathComponent("Current").path, withDestinationPath: "A")
    let snapshot = try ObjectSnapshot.capture(fixture.app.path, application: true)
    #expect(snapshot.members.contains { $0.linkTarget == "A" })
}

@Test func executionLockPreventsConcurrentApply() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("A.cache")
    let engine = fixture.engine()
    let plan = try await scan(engine)
    let store = try EngineStore(home: fixture.home.path)
    let lock = try store.lock(); defer { flock(lock, LOCK_UN); close(lock) }
    #expect(try await apply(engine, plan, plan.items.map(\.itemID)).status == .blocked)
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test func unsafeRecordIsNotTruncatedBeforeRejection() throws {
    let fixture = try Fixture()
    let store = try EngineStore(home: fixture.home.path)
    let outside = try fixture.file("outside.cache", "preserve")
    try FileManager.default.linkItem(atPath: outside.path, toPath: store.root + "/protections.json")
    #expect(throws: (any Error).self) { try store.write(["replacement"], "protections.json", exclusive: false) }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "preserve")
}

@Test func symlinkApplicationSupportDoesNotCreateOutsideDirectory() throws {
    let fixture = try Fixture()
    let external = fixture.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: fixture.home.appendingPathComponent("Library/Application Support"), withDestinationURL: external)
    #expect(throws: (any Error).self) { try EngineStore(home: fixture.home.path) }
    #expect(!FileManager.default.fileExists(atPath: external.appendingPathComponent("TidyNest").path))
}

@Test func journalFailureAfterTrashReturnsUnknownWithRealLocation() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("A.cache")
    let journals = fixture.home.path + "/Library/Application Support/TidyNest/Engine/Journals"
    let engine = MaintenanceEngine(context: fixture.context(hook: { boundary, _, _ in
        if boundary == .afterTrash {
            let names = try FileManager.default.contentsOfDirectory(atPath: journals)
            for name in names { chmod(journals + "/" + name, 0o644) }
        }
    }))
    let plan = try await scan(engine)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .unknown)
    #expect(result.items.count == 1)
    #expect(result.items.first?.trashPath != nil)
    #expect(!FileManager.default.fileExists(atPath: target.path))
    let realTrash = try #require(result.items.first?.trashPath)
    #expect(FileManager.default.fileExists(atPath: realTrash))
}


@Test func chineseSpaceAndNewlineFileNameRoundTripsAndMovesExactly() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("中文 文件\n第二行.cache", "precise")
    let engine = fixture.engine()
    let plan = try await scan(engine)
    #expect(plan.scanComplete)
    let item = try #require(plan.items.first)
    #expect(item.path == target.path)
    let encoded = try MaintenanceJSON.encoder().encode(plan)
    #expect(try MaintenanceJSON.decoder().decode(MaintenancePlan.self, from: encoded).items[0].path == target.path)
    let result = try await apply(engine, plan, [item.itemID])
    #expect(result.status == .completed)
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

@Test func unreadableCandidateMakesScanIncomplete() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("unreadable.cache")
    chmod(target.path, 0o000)
    defer { chmod(target.path, 0o600) }
    let plan = try await scan(fixture.engine())
    #expect(!plan.scanComplete)
    #expect(!plan.scanIssues.isEmpty)
}

private final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
@Test func newlyRunningApplicationPreservesPlannedFiles() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("A.cache")
    let running = MutableFlag()
    let engine = MaintenanceEngine(context: fixture.context(runtime: { _, _ in
        if running.isSet { throw EngineFailure("fixture app now running") }
    }))
    let plan = try await scan(engine)
    running.set()
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .failed)
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test func whitelistReplacementKeepsHardSafetyAndMalformedDenoIsRejected() throws {
    let fixture = try Fixture()
    let rules = try EngineRules()
    let context = fixture.context()
    let before = try rules.configuration(context: context, protections: [])
    let playwright = fixture.home.path + "/Library/Caches/ms-playwright-test/file"
    #expect(rules.fileBlock(playwright, configuration: before) != nil)
    let config = fixture.home.appendingPathComponent(".config/mole")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try Data("# complete user replacement\n".utf8).write(to: config.appendingPathComponent("whitelist"))
    let after = try rules.configuration(context: context, protections: [])
    #expect(rules.fileBlock(playwright, configuration: after) == nil)
    #expect(rules.fileBlock(fixture.home.path + "/Library/Caches/CloudKit-local/file", configuration: after) != nil)
    #expect(before.digest != after.digest)
    let bad = EngineContext(home: context.home, appRoots: context.appRoots, catalog: context.catalog, runtime: context.runtime, trash: context.trash, hook: context.hook, environment: { ["DENO_DIR": fixture.home.path + "/Library/Caches"] })
    #expect(throws: (any Error).self) { try rules.configuration(context: bad, protections: []) }
}

@Test func duplicateBundleOwnersDoNotAuthorizeAnyFile() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("A.cache")
    let copy = fixture.home.appendingPathComponent("Applications/Copy.app")
    try FileManager.default.copyItem(at: fixture.app, to: copy)
    let base = fixture.context()
    let context = EngineContext(home: base.home, appRoots: base.appRoots, catalog: {
        [EngineApplication(path: fixture.app.path, bundleID: "org.example.fixture", name: "Fixture", source: "app"), EngineApplication(path: copy.path, bundleID: "org.example.fixture", name: "Copy", source: "app")]
    }, runtime: base.runtime, trash: base.trash, hook: base.hook, environment: base.environment)
    let plan = try await scan(MaintenanceEngine(context: context))
    #expect(plan.items.isEmpty)
    #expect(plan.scanIssues.contains { $0.reason.contains("不唯一") })
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test(arguments: ["org.example.fixture", "com.apple.dt.Xcode"])
func duplicateApplicationRemovalMovesOnlySelectedBodyAndPreservesSharedData(_ bundleID: String) async throws {
    let fixture = try Fixture(bundleID: bundleID)
    let cache = try fixture.file("shared.cache", "shared cache")
    let logs = fixture.home.appendingPathComponent("Library/Logs/" + bundleID)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let log = logs.appendingPathComponent("shared.log")
    try Data("shared log".utf8).write(to: log)
    let copy = fixture.home.appendingPathComponent("Applications/Other Version.app")
    try FileManager.default.copyItem(at: fixture.app, to: copy)
    let copyBefore = try ObjectSnapshot.capture(copy.path, application: true)
    let base = fixture.context()
    let context = EngineContext(home: base.home, appRoots: base.appRoots, catalog: {
        try [copy, fixture.app].filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { try catalogApplication(at: $0.path, name: $0.lastPathComponent, source: "app") }
    }, runtime: base.runtime, trash: base.trash, hook: base.hook, environment: base.environment)
    let engine = MaintenanceEngine(context: context)
    let plan = try await uninstall(engine, fixture: fixture)
    #expect(plan.scanComplete)
    let body = try #require(plan.items.first { $0.kind == .application })
    #expect(body.path == fixture.app.path)
    #expect(body.selection == .required)
    #expect(body.blockedReason == nil)
    #expect(body.impact.contains("缓存与日志保留"))
    #expect(plan.items.count == 1)
    #expect(plan.scanIssues.contains { $0.reason.contains("共享缓存与日志") && $0.reason.contains("保留") })
    let result = try await apply(engine, plan, [body.itemID])
    #expect(result.status == .completed)
    #expect(result.items.map(\.path) == [fixture.app.path])
    #expect(!FileManager.default.fileExists(atPath: fixture.app.path))
    #expect(copyBefore.matches(try ObjectSnapshot.capture(copy.path, application: true)))
    #expect(try String(contentsOf: cache, encoding: .utf8) == "shared cache")
    #expect(try String(contentsOf: log, encoding: .utf8) == "shared log")
}

@Test func rootOwnedPackageMembersCanBeReadWithoutAuthorizingLooseSystemFiles() throws {
    // 只读系统自带文件，验证应用包成员的 root 属主；不生成计划或移动该文件。
    let path = "/System/Library/CoreServices/SystemVersion.plist"
    let before = try identity(at: path)
    #expect(before.owner == 0)
    let snapshot = try ObjectSnapshot.capture(path, application: true)
    #expect(snapshot.members.first?.identity == before)
    #expect(throws: EngineFailure.self) { try ObjectSnapshot.capture(path, application: false) }
    #expect(try identity(at: path) == before)
}

@Test(arguments: ["externalHardLink", "worldWritable", "sharedGroupWritable", "specialMode"])
func unsafeApplicationMembersStayBlocked(_ kind: String) async throws {
    let fixture = try Fixture(bundleID: "com.apple.dt.Xcode")
    let member = fixture.app.appendingPathComponent("Contents/member")
    try Data("preserve".utf8).write(to: member)
    if kind == "externalHardLink" {
        try FileManager.default.linkItem(at: member, to: fixture.root.appendingPathComponent("outside-link"))
    } else {
        #expect(chmod(member.path, kind == "worldWritable" ? 0o666 : (kind == "sharedGroupWritable" ? 0o664 : 0o4644)) == 0)
    }
    let engine = fixture.engine()
    let plan = try await uninstall(engine, fixture: fixture)
    #expect(plan.items.first?.selection == .blocked)
    #expect(try await apply(engine, plan, plan.items.map(\.itemID)).status == .blocked)
    #expect(try String(contentsOf: member, encoding: .utf8) == "preserve")
}

@Test func internalHardLinksMoveWithApplication() async throws {
    let fixture = try Fixture(bundleID: "com.apple.dt.Xcode")
    let folder = fixture.app.appendingPathComponent("Contents/Developer")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let original = folder.appendingPathComponent("original")
    let linked = folder.appendingPathComponent("linked")
    try Data("package content".utf8).write(to: original)
    try FileManager.default.linkItem(at: original, to: linked)
    let snapshot = try ObjectSnapshot.capture(fixture.app.path, application: true)
    let plistBytes = try identity(at: fixture.app.appendingPathComponent("Contents/Info.plist").path).size
    #expect(snapshot.bytes == UInt64(plistBytes) + UInt64(Data("package content".utf8).count))
    let engine = fixture.engine()
    let plan = try await uninstall(engine, fixture: fixture)
    #expect(plan.items.first?.selection == .required)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .completed)
    let returned = URL(fileURLWithPath: try #require(result.items.first?.trashPath))
    let moved = returned.appendingPathComponent("Contents/Developer/original")
    let other = returned.appendingPathComponent("Contents/Developer/linked")
    #expect(try String(contentsOf: moved, encoding: .utf8) == "package content")
    #expect(try identity(at: moved.path) == identity(at: other.path))
    #expect(try identity(at: moved.path).links == 2)
}

@Test func externalHardLinkAddedAfterPlanPreservesApplication() async throws {
    let fixture = try Fixture(bundleID: "com.apple.dt.Xcode")
    let member = fixture.app.appendingPathComponent("Contents/member")
    try Data("preserve".utf8).write(to: member)
    let engine = fixture.engine()
    let plan = try await uninstall(engine, fixture: fixture)
    #expect(plan.items.first?.selection == .required)
    let external = fixture.root.appendingPathComponent("external-link")
    try FileManager.default.linkItem(at: member, to: external)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .failed)
    #expect(try String(contentsOf: member, encoding: .utf8) == "preserve")
    #expect(try String(contentsOf: external, encoding: .utf8) == "preserve")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test func snapshotIdentityRetainsGroupForParentAndMovedObjectChecks() throws {
    var metadata = stat()
    metadata.st_uid = 0; metadata.st_gid = 0; metadata.st_mode = UInt16(S_IFDIR) | 0o775
    let original = FileIdentity(metadata)
    let restored = try MaintenanceJSON.decoder().decode(FileIdentity.self, from: MaintenanceJSON.encoder().encode(original))
    #expect(restored == original)
    metadata.st_gid = 80
    let changed = FileIdentity(metadata)
    #expect(!restored.sameDirectory(changed))
    #expect(!restored.sameMovedObject(changed))
}

@Test func largeApplicationSnapshotPersistsWithoutDroppingMembers() throws {
    let fixture = try Fixture()
    let memberIdentity = try identity(at: fixture.app.appendingPathComponent("Contents/Info.plist").path)
    // 复现 Xcode 的成员数量和常见 SDK 路径长度；只构造元数据，不创建海量文件。
    let members = (0..<135_501).map { index in
        SnapshotMember(relativePath: "Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Fixture.framework/Headers/\(index).h", identity: memberIdentity, linkTarget: nil)
    }
    let snapshot = ObjectSnapshot(parents: [], members: members)
    let store = try EngineStore(home: fixture.home.path)
    try store.write(snapshot, "Plans/large-fixture.json")
    let restored = try store.read(ObjectSnapshot.self, "Plans/large-fixture.json")
    #expect(restored.members.count == members.count)
    #expect(snapshot.matches(restored))
}

@Test func singleXcodeRemovalKeepsDeveloperData() async throws {
    let fixture = try Fixture(bundleID: "com.apple.dt.Xcode")
    let cache = try fixture.file("developer.cache", "developer data")
    let engine = fixture.engine()
    let clean = try await scan(engine)
    #expect(clean.items.isEmpty)
    let plan = try await uninstall(engine, fixture: fixture)
    #expect(plan.scanComplete)
    #expect(plan.items.count == 1)
    #expect(plan.items.first?.selection == .required)
    #expect(plan.items.first?.kind == .application)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .completed)
    #expect(try String(contentsOf: cache, encoding: .utf8) == "developer data")
}

@Test(arguments: ["com.apple.finder", "com.apple.dt.Instruments", "com.apple.Safari"])
func xcodeRemovalExceptionDoesNotAllowOtherAppleApplications(_ bundleID: String) async throws {
    let fixture = try Fixture(bundleID: bundleID)
    let engine = fixture.engine()
    let plan = try await uninstall(engine, fixture: fixture)
    #expect(plan.items.first?.selection == .blocked)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .blocked)
    #expect(FileManager.default.fileExists(atPath: fixture.app.path))
}

@Test(arguments: ["selected", "other", "running"])
func duplicateApplicationRemovalStillRejectsChangesOrRunningState(_ change: String) async throws {
    let fixture = try Fixture()
    let copy = fixture.home.appendingPathComponent("Applications/Other.app")
    try FileManager.default.copyItem(at: fixture.app, to: copy)
    let running = MutableFlag()
    let base = fixture.context(runtime: { _, _ in
        if running.isSet { throw EngineFailure("fixture is running") }
    })
    let context = EngineContext(home: base.home, appRoots: base.appRoots, catalog: {
        try [fixture.app, copy].map { try catalogApplication(at: $0.path, name: $0.lastPathComponent, source: "app") }
    }, runtime: base.runtime, trash: base.trash, hook: base.hook, environment: base.environment)
    let engine = MaintenanceEngine(context: context)
    let plan = try await uninstall(engine, fixture: fixture)
    #expect(plan.items.first?.selection == .required)
    if change == "running" { running.set() }
    else if change == "other" {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.changed"], format: .xml, options: 0)
        try plist.write(to: copy.appendingPathComponent("Contents/Info.plist"))
    } else {
        try Data("changed".utf8).write(to: fixture.app.appendingPathComponent("Contents/new-member"))
    }
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .blocked || result.status == .failed)
    #expect(FileManager.default.fileExists(atPath: fixture.app.path))
    #expect(FileManager.default.fileExists(atPath: copy.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test func duplicateApplicationPlanCannotAcquireSharedResidualFromAnotherPlan() async throws {
    let fixture = try Fixture()
    let cache = try fixture.file("shared.cache", "keep shared")
    let originalPlan = try await uninstall(fixture.engine(), fixture: fixture)
    let residual = try #require(originalPlan.items.first { $0.kind == .file })
    let copy = fixture.home.appendingPathComponent("Applications/Copy.app")
    try FileManager.default.copyItem(at: fixture.app, to: copy)
    let base = fixture.context()
    let context = EngineContext(home: base.home, appRoots: base.appRoots, catalog: {
        try [fixture.app, copy].filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { try catalogApplication(at: $0.path, name: $0.lastPathComponent, source: "app") }
    }, runtime: base.runtime, trash: base.trash, hook: base.hook, environment: base.environment)
    let engine = MaintenanceEngine(context: context)
    let plan = try await uninstall(engine, fixture: fixture)
    let body = try #require(plan.items.first)
    #expect(body.selection == .required)
    let store = try EngineStore(home: fixture.home.path)
    let original = try #require(JSONSerialization.jsonObject(with: store.readData("Plans/" + originalPlan.planID + ".json")) as? [String: Any])
    var document = try #require(JSONSerialization.jsonObject(with: store.readData("Plans/" + plan.planID + ".json")) as? [String: Any])
    var jsonPlan = try #require(document["plan"] as? [String: Any])
    let originalItems = try #require((original["plan"] as? [String: Any])?["items"] as? [[String: Any]])
    var injected = try #require(originalItems.first { $0["itemID"] as? String == residual.itemID })
    injected["dependsOnItemIDs"] = [body.itemID]
    jsonPlan["items"] = try #require(jsonPlan["items"] as? [[String: Any]]) + [injected]
    document["plan"] = jsonPlan
    for key in ["snapshots", "owners"] {
        var values = try #require(document[key] as? [String: Any])
        values[residual.itemID] = try #require((original[key] as? [String: Any])?[residual.itemID])
        document[key] = values
    }
    try store.writeData(JSONSerialization.data(withJSONObject: document), "Plans/" + plan.planID + ".json", exclusive: false)
    let result = try await apply(engine, plan, [body.itemID, residual.itemID])
    #expect(result.status == .blocked)
    #expect(FileManager.default.fileExists(atPath: fixture.app.path))
    #expect(FileManager.default.fileExists(atPath: copy.path))
    #expect(try String(contentsOf: cache, encoding: .utf8) == "keep shared")
}

@Test func finalResultMissingIsShownAsUnknownAndNeverReplayed() async throws {
    let fixture = try Fixture()
    _ = try fixture.file("A.cache")
    let engine = fixture.engine()
    let plan = try await scan(engine)
    let applied = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(applied.status == .completed)
    let store = try EngineStore(home: fixture.home.path)
    // 仅移走隔离fixture的结果记录，模拟进程在写最终历史前中断。
    try FileManager.default.moveItem(atPath: store.root + "/History/" + applied.runID + ".json", toPath: fixture.root.appendingPathComponent("saved-final.json").path)
    let data = try #require(try await engine.handle(command: "history", request: MaintenanceRequest(), emit: { _ in }))
    let history = try MaintenanceJSON.decoder().decode([MaintenanceResult].self, from: data)
    #expect(history.first?.status == .unknown)
    #expect(history.first?.items.first?.outcome == .trashed)
    #expect(history.first?.items.first?.trashPath == applied.items.first?.trashPath)
    #expect(try await apply(engine, plan, plan.items.map(\.itemID)).status == .blocked)
}


@Test(.enabled(if: ProcessInfo.processInfo.environment["TIDYNEST_VERIFY_SYSTEM_TRASH"] == "1"))
func systemTrashMovesOnlyNewIsolatedFixture() async throws {
    let fixture = try Fixture()
    let a = try fixture.file("TidyNest-fixture-" + UUID().uuidString + ".cache", "new isolated A")
    let b = try fixture.file("B.cache", "new isolated B")
    let engine = MaintenanceEngine(context: fixture.context(trashOperation: EngineContext.production().trash))
    let plan = try await scan(engine)
    let item = try #require(plan.items.first { $0.path == a.path })
    let result = try await apply(engine, plan, [item.itemID])
    let report = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/m2-system-trash-result.json")
    try MaintenanceJSON.encoder().encode(result).write(to: report)
    #expect(result.status == .completed)
    let actual = try #require(result.items.first?.trashPath)
    #expect(try String(contentsOfFile: actual, encoding: .utf8) == "new isolated A")
    #expect(!FileManager.default.fileExists(atPath: a.path))
    #expect(try String(contentsOf: b, encoding: .utf8) == "new isolated B")
}


@Test func unselectedCorruptRuleInvalidatesWholeStoredPlan() async throws {
    let fixture = try Fixture()
    let a = try fixture.file("A.cache")
    _ = try fixture.file("B.cache")
    let engine = fixture.engine()
    let plan = try await scan(engine)
    let store = try EngineStore(home: fixture.home.path)
    var document = try #require(JSONSerialization.jsonObject(with: store.readData("Plans/" + plan.planID + ".json")) as? [String: Any])
    var jsonPlan = try #require(document["plan"] as? [String: Any])
    var jsonItems = try #require(jsonPlan["items"] as? [[String: Any]])
    let index = try #require(jsonItems.firstIndex { $0["path"] as? String != a.path })
    jsonItems[index]["ruleID"] = "untrusted-rule"
    jsonPlan["items"] = jsonItems
    document["plan"] = jsonPlan
    try store.writeData(JSONSerialization.data(withJSONObject: document), "Plans/" + plan.planID + ".json", exclusive: false)
    let selected = try #require(plan.items.first { $0.path == a.path })
    let result = try await apply(engine, plan, [selected.itemID])
    #expect(result.status == .blocked)
    #expect(FileManager.default.fileExists(atPath: a.path))
}

@Test func parentReplacedAtRenameBoundaryNeverMovesReplacementContents() async throws {
    let fixture = try Fixture()
    let a = try fixture.file("A.cache", "planned A")
    let old = fixture.root.appendingPathComponent("old-parent")
    let engine = MaintenanceEngine(context: fixture.context(hook: { boundary, path, _ in
        if boundary == .beforeMove {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.moveItem(at: parent, to: old)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data("replacement A".utf8).write(to: URL(fileURLWithPath: path))
        }
    }))
    let plan = try await scan(engine)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .unknown)
    #expect(try String(contentsOf: a, encoding: .utf8) == "replacement A")
    let retained = try #require(result.items.first?.retainedPath)
    #expect(try String(contentsOfFile: retained, encoding: .utf8) == "planned A")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}


@Test func caseVariantBundleIDsCannotAuthorizeSharedData() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("A.cache")
    let copy = fixture.home.appendingPathComponent("Applications/Uppercase.app")
    try FileManager.default.copyItem(at: fixture.app, to: copy)
    let upperID = "ORG.EXAMPLE.FIXTURE"
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": upperID], format: .xml, options: 0)
    try plist.write(to: copy.appendingPathComponent("Contents/Info.plist"))
    let base = fixture.context()
    let context = EngineContext(home: base.home, appRoots: base.appRoots, catalog: {
        [EngineApplication(path: fixture.app.path, bundleID: "org.example.fixture", name: "Fixture", source: "app"), EngineApplication(path: copy.path, bundleID: upperID, name: "Uppercase", source: "app")]
    }, runtime: base.runtime, trash: base.trash, hook: base.hook, environment: base.environment)
    let engine = MaintenanceEngine(context: context)
    let clean = try await scan(engine)
    #expect(clean.items.isEmpty)
    let removal = try await uninstall(engine, fixture: fixture)
    #expect(removal.items.first?.selection == .required)
    #expect(removal.items.first?.path == fixture.app.path)
    #expect(removal.items.filter { $0.kind == .file }.isEmpty)
    #expect(FileManager.default.fileExists(atPath: target.path))
}


@Test func caseVariantProtectionAppliesToSameDirectory() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("A.cache")
    let engine = fixture.engine()
    let protection = fixture.home.path + "/Library/Caches/ORG.EXAMPLE.FIXTURE"
    #expect(FileManager.default.fileExists(atPath: protection))
    _ = try await engine.handle(command: "protect-path", request: MaintenanceRequest(protectedPath: protection), emit: { _ in })
    let plan = try await scan(engine)
    #expect(plan.items.isEmpty)
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test func whitelistChangeAfterFirstItemPreservesLaterItem() async throws {
    let fixture = try Fixture()
    _ = try fixture.file("A.cache")
    let b = try fixture.file("B.cache")
    let config = fixture.home.appendingPathComponent(".config/mole")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let engine = MaintenanceEngine(context: fixture.context(hook: { boundary, _, _ in
        if boundary == .afterTrash { try Data((b.path + "\n").utf8).write(to: config.appendingPathComponent("whitelist")) }
    }))
    let plan = try await scan(engine)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .partial)
    #expect(result.items.map(\.outcome) == [.trashed, .failed])
    #expect(FileManager.default.fileExists(atPath: b.path))
}

@Test func duplicateInstalledAfterFirstItemPreservesLaterItem() async throws {
    let fixture = try Fixture()
    _ = try fixture.file("A.cache")
    let b = try fixture.file("B.cache")
    let copy = fixture.home.appendingPathComponent("Applications/Late.app")
    let base = fixture.context(hook: { boundary, _, _ in
        if boundary == .afterTrash && !FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.copyItem(at: fixture.app, to: copy) }
    })
    let context = EngineContext(home: base.home, appRoots: base.appRoots, catalog: {
        var apps = [EngineApplication(path: fixture.app.path, bundleID: "org.example.fixture", name: "Fixture", source: "app")]
        if FileManager.default.fileExists(atPath: copy.path) { apps.append(EngineApplication(path: copy.path, bundleID: "org.example.fixture", name: "Late", source: "app")) }
        return apps
    }, runtime: base.runtime, trash: base.trash, hook: base.hook, environment: base.environment)
    let engine = MaintenanceEngine(context: context)
    let plan = try await scan(engine)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .partial)
    #expect(FileManager.default.fileExists(atPath: b.path))
}

@Test func sharedWritableFileIsNotCandidate() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("shared.cache")
    chmod(target.path, 0o666)
    let plan = try await scan(fixture.engine())
    #expect(plan.items.isEmpty)
    #expect(FileManager.default.fileExists(atPath: target.path))
}


@Test func truncatedHistoryRecoversThatRunWithoutHidingOtherResults() async throws {
    let fixture = try Fixture()
    _ = try fixture.file("A.cache")
    let engine = fixture.engine()
    let plan = try await scan(engine)
    let completed = try await apply(engine, plan, plan.items.map(\.itemID))
    let blocked = try await apply(engine, plan, [UUID().uuidString])
    let store = try EngineStore(home: fixture.home.path)
    try store.writeData(Data("{\"truncated\":".utf8), "History/" + completed.runID + ".json", exclusive: false)
    let data = try #require(try await engine.handle(command: "history", request: MaintenanceRequest(), emit: { _ in }))
    let history = try MaintenanceJSON.decoder().decode([MaintenanceResult].self, from: data)
    #expect(history.contains { $0.runID == blocked.runID && $0.status == .blocked })
    let recovered = try #require(history.first { $0.runID == completed.runID })
    #expect(recovered.status == .unknown)
    #expect(recovered.items.first?.trashPath == completed.items.first?.trashPath)
}

@Test func danglingWhitelistLinkNeverMeansDefaultConfiguration() throws {
    let fixture = try Fixture()
    let config = fixture.home.appendingPathComponent(".config/mole")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: config.appendingPathComponent("whitelist").path, withDestinationPath: "missing-whitelist")
    #expect(throws: (any Error).self) { try EngineRules().configuration(context: fixture.context(), protections: []) }
}


@Test func finalFileVerificationDoesNotRequireListingTrashParent() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("A.cache", "exact returned object")
    let final = fixture.trash.appendingPathComponent("A.cache")
    defer { chmod(fixture.trash.path, 0o700) }
    let engine = MaintenanceEngine(context: fixture.context(trashOperation: { source in
        try FileManager.default.moveItem(at: source, to: final)
        chmod(fixture.trash.path, 0o100)
        return final
    }))
    let plan = try await scan(engine)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .completed)
    #expect(result.items.first?.trashPath == final.path)
    #expect(try String(contentsOf: final, encoding: .utf8) == "exact returned object")
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

@Test func finalApplicationVerificationDoesNotRequireListingTrashParent() async throws {
    let fixture = try Fixture()
    let final = fixture.trash.appendingPathComponent("Fixture.app")
    defer { chmod(fixture.trash.path, 0o700) }
    let engine = MaintenanceEngine(context: fixture.context(trashOperation: { source in
        try FileManager.default.moveItem(at: source, to: final)
        chmod(fixture.trash.path, 0o100)
        return final
    }))
    let plan = try await uninstall(engine, fixture: fixture)
    let body = try #require(plan.items.first { $0.kind == .application })
    let result = try await apply(engine, plan, [body.itemID])
    #expect(result.status == .completed)
    #expect(result.items.first?.trashPath == final.path)
    #expect(try Data(contentsOf: final.appendingPathComponent("Contents/Info.plist")).count > 0)
}

@Test func finalVerificationStillRejectsSymlinkAncestor() async throws {
    let fixture = try Fixture()
    _ = try fixture.file("A.cache")
    let final = fixture.trash.appendingPathComponent("A.cache")
    let alias = fixture.root.appendingPathComponent("returned-parent")
    let engine = MaintenanceEngine(context: fixture.context(trashOperation: { source in
        try FileManager.default.moveItem(at: source, to: final)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.trash)
        return alias.appendingPathComponent("A.cache")
    }))
    let plan = try await scan(engine)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .unknown)
    #expect(FileManager.default.fileExists(atPath: final.path))
}

@Test func finalVerificationStillDetectsApplicationMemberChanges() async throws {
    let fixture = try Fixture()
    let final = fixture.trash.appendingPathComponent("Fixture.app")
    let engine = MaintenanceEngine(context: fixture.context(trashOperation: { source in
        try FileManager.default.moveItem(at: source, to: final)
        try Data("late member".utf8).write(to: final.appendingPathComponent("Contents/added-after-trash"))
        return final
    }))
    let plan = try await uninstall(engine, fixture: fixture)
    let body = try #require(plan.items.first { $0.kind == .application })
    let result = try await apply(engine, plan, [body.itemID])
    #expect(result.status == .unknown)
    #expect(FileManager.default.fileExists(atPath: final.appendingPathComponent("Contents/added-after-trash").path))
}


@Test(.enabled(if: ProcessInfo.processInfo.environment["TIDYNEST_VERIFY_EXISTING_TRASH"] == "1"))
func previouslyReturnedSystemTrashObjectMatchesOriginalSnapshot() throws {
    struct RecordedPlan: Decodable { let snapshots: [String: ObjectSnapshot] }
    let workspace = FileManager.default.currentDirectoryPath
    let result = try MaintenanceJSON.decoder().decode(MaintenanceResult.self, from: Data(contentsOf: URL(fileURLWithPath: workspace + "/work/m2-system-trash-result.json")))
    let item = try #require(result.items.first)
    let returned = try #require(item.trashPath)
    #expect(item.path.hasPrefix(workspace + "/work/m2-engine-fixtures/"))
    #expect(returned.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/.Trash/TidyNest-fixture-"))
    let home = try #require(item.path.components(separatedBy: "/Library/Caches/").first)
    let saved = try MaintenanceJSON.decoder().decode(RecordedPlan.self, from: Data(contentsOf: URL(fileURLWithPath: home + "/Library/Application Support/TidyNest/Engine/Plans/" + result.planID + ".json")))
    let original = try #require(saved.snapshots[item.itemID])
    let current = try ObjectSnapshot.captureFinalLocation(returned, application: false)
    #expect(original.matches(current, moved: true))
}


@Test func readableUnsupportedMetadataDoesNotEraseKnownValidCatalog() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("A.cache")
    let unsupported = fixture.home.appendingPathComponent("Applications/Unsupported.app")
    let missingID = fixture.home.appendingPathComponent("Applications/MissingID.app")
    for url in [unsupported, missingID] { try FileManager.default.copyItem(at: fixture.app, to: url) }
    let unsupportedInfo = unsupported.appendingPathComponent("Contents/Info.plist")
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "ShortName"], format: .xml, options: 0).write(to: unsupportedInfo)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Missing"], format: .binary, options: 0).write(to: missingID.appendingPathComponent("Contents/Info.plist"))
    let base = fixture.context()
    let context = EngineContext(home: base.home, appRoots: base.appRoots, catalog: {
        try [fixture.app, unsupported, missingID].map { url in try catalogApplication(at: url.path, name: url.lastPathComponent, source: "app") }
    }, runtime: base.runtime, trash: base.trash, hook: base.hook, environment: base.environment)
    let engine = MaintenanceEngine(context: context)
    let plan = try await scan(engine)
    #expect(plan.scanComplete)
    #expect(plan.items.map(\.path) == [target.path])
    #expect(plan.scanIssues.contains { $0.path == unsupported.path })
    #expect(plan.scanIssues.contains { $0.path == missingID.path })
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "AnotherShortName"], format: .xml, options: 0).write(to: unsupportedInfo)
    #expect(try await apply(engine, plan, plan.items.map(\.itemID)).status == .blocked)
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test func knownIOSWrapperMetadataCanBeReadWithoutFollowingWrapperLink() async throws {
    let fixture = try Fixture()
    let wrapper = fixture.home.appendingPathComponent("Applications/Wrapped.app")
    let payload = wrapper.appendingPathComponent("Wrapper/Payload.app")
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.fixture"], format: .binary, options: 0).write(to: payload.appendingPathComponent("Info.plist"))
    try FileManager.default.createSymbolicLink(atPath: wrapper.appendingPathComponent("WrappedBundle").path, withDestinationPath: "Wrapper/Payload.app")
    #expect(try bundleID(at: wrapper.path) == "org.example.fixture")
    let target = try fixture.file("A.cache")
    let base = fixture.context()
    let context = EngineContext(home: base.home, appRoots: base.appRoots, catalog: {
        try [fixture.app, wrapper].map { try catalogApplication(at: $0.path, name: $0.lastPathComponent, source: "app") }
    }, runtime: base.runtime, trash: base.trash, hook: base.hook, environment: base.environment)
    let engine = MaintenanceEngine(context: context)
    #expect(try await scan(engine).items.isEmpty)
    let application = try catalogApplication(at: wrapper.path, name: "Wrapped", source: "app")
    #expect(application.unsupportedReason == nil)
    #expect(application.metadataPath == payload.appendingPathComponent("Info.plist").path)
    let box = EventBox()
    _ = try await engine.handle(command: "plan-uninstall", request: MaintenanceRequest(appPath: wrapper.path, expectedBundleID: "org.example.fixture"), emit: { box.append($0) })
    #expect(box.events.last?.plan?.items.first?.selection == .required)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.ios"], format: .binary, options: 0).write(to: payload.appendingPathComponent("Info.plist"))
    let plan = try await scan(engine)
    #expect(plan.items.map(\.path) == [target.path])
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.ios.changed"], format: .binary, options: 0).write(to: payload.appendingPathComponent("Info.plist"))
    #expect(try await apply(engine, plan, plan.items.map(\.itemID)).status == .blocked)
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test func wrappedApplicationWithUnknownListIDRequiresRefreshInsteadOfReportingMissing() async throws {
    let fixture = try Fixture()
    let wrapper = fixture.home.appendingPathComponent("Applications/云·示例.app")
    let payload = wrapper.appendingPathComponent("Wrapper/CloudGame.app")
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
    let info = payload.appendingPathComponent("Info.plist")
    let metadata = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.CloudGame.Nap"], format: .binary, options: 0)
    try metadata.write(to: info)
    try FileManager.default.createSymbolicLink(atPath: wrapper.appendingPathComponent("WrappedBundle").path, withDestinationPath: "Wrapper/CloudGame.app")
    let base = fixture.context()
    let context = EngineContext(home: base.home, appRoots: base.appRoots, catalog: {
        try [catalogApplication(at: wrapper.path, name: "云·示例", source: "App", observedBundleID: "unknown")]
    }, runtime: { _, _ in Issue.record("标识未核对成功时不应进入运行检查") }, trash: { _ in
        Issue.record("标识未核对成功时不能移入废纸篓")
        throw CancellationError()
    }, hook: base.hook, environment: base.environment)
    let engine = MaintenanceEngine(context: context)
    let box = EventBox()
    _ = try await engine.handle(command: "plan-uninstall", request: MaintenanceRequest(appPath: wrapper.path, expectedBundleID: "unknown"), emit: { box.append($0) })
    let plan = try #require(box.events.last?.plan)
    #expect(!plan.scanComplete)
    #expect(plan.items.isEmpty)
    let issue = try #require(plan.scanIssues.first { $0.path == wrapper.path })
    #expect(issue.reason.contains("仍然存在"))
    #expect(issue.reason.contains("标识"))
    #expect(issue.reason.contains("刷新"))
    #expect(!issue.reason.contains("暂不支持"))
    #expect(!issue.reason.contains("已缺失"))
    #expect(try await apply(engine, plan, []).status == .blocked)
    #expect(try Data(contentsOf: info) == metadata)
}

@Test(arguments: ["org.example.replaced", "ORG.example.fixture", "unknown"])
func mismatchedApplicationIDRemainsBlockedWithAccurateReason(_ expectedID: String) async throws {
    let fixture = try Fixture()
    let cache = try fixture.file("A.cache", "keep")
    let engine = fixture.engine()
    let box = EventBox()
    _ = try await engine.handle(command: "plan-uninstall", request: MaintenanceRequest(appPath: fixture.app.path, expectedBundleID: expectedID), emit: { box.append($0) })
    let plan = try #require(box.events.last?.plan)
    #expect(!plan.scanComplete)
    #expect(plan.items.isEmpty)
    let issue = try #require(plan.scanIssues.first)
    #expect(issue.reason.contains("仍然存在"))
    #expect(issue.reason.contains("标识"))
    #expect(!issue.reason.contains("已缺失"))
    #expect(try await apply(engine, plan, []).status == .blocked)
    #expect(try String(contentsOf: cache, encoding: .utf8) == "keep")
}

@Test func absentApplicationIsNotReportedAsAnIdentifierChange() async throws {
    let fixture = try Fixture()
    let missing = fixture.home.appendingPathComponent("Applications/Missing.app")
    let box = EventBox()
    _ = try await fixture.engine().handle(command: "plan-uninstall", request: MaintenanceRequest(appPath: missing.path, expectedBundleID: "org.example.fixture"), emit: { box.append($0) })
    let plan = try #require(box.events.last?.plan)
    #expect(!plan.scanComplete)
    #expect(plan.items.isEmpty)
    let issue = try #require(plan.scanIssues.first)
    #expect(issue.reason.contains("未找到"))
    #expect(!issue.reason.contains("标识变化"))
}


@Test(arguments: ["application", "parent"])
func uninstallPlanBlocksMissingMovePermission(_ target: String) async throws {
    let fixture = try Fixture()
    let restricted = target == "application" ? fixture.app : fixture.app.deletingLastPathComponent()
    #expect(chmod(restricted.path, 0o555) == 0)
    defer { _ = chmod(restricted.path, 0o755) }
    let before = try ObjectSnapshot.capture(fixture.app.path, application: true)
    let engine = fixture.engine()
    let plan = try await uninstall(engine, fixture: fixture)
    let body = try #require(plan.items.first { $0.kind == .application })
    #expect(body.selection == .blocked)
    #expect(body.blockedReason?.contains("权限") == true)
    #expect(body.blockedReason?.contains("Finder") == true)
    #expect(try await apply(engine, plan, [body.itemID]).status == .blocked)
    #expect(before.matches(try ObjectSnapshot.capture(fixture.app.path, application: true)))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    let consumed = fixture.home.appendingPathComponent("Library/Application Support/TidyNest/Engine/Consumed")
    #expect(try FileManager.default.contentsOfDirectory(atPath: consumed.path).isEmpty)
}

@Test func readonlyApplicationStillAllowsIndependentCacheCleaning() async throws {
    let fixture = try Fixture()
    let cache = try fixture.file("selected.cache", "only cache")
    #expect(chmod(fixture.app.path, 0o555) == 0)
    defer { _ = chmod(fixture.app.path, 0o755) }
    let before = try ObjectSnapshot.capture(fixture.app.path, application: true)
    let engine = fixture.engine()
    let plan = try await scan(engine)
    #expect(plan.items.map(\.path) == [cache.path])
    #expect(try await apply(engine, plan, plan.items.map(\.itemID)).status == .completed)
    #expect(before.matches(try ObjectSnapshot.capture(fixture.app.path, application: true)))
}

@Test func movePermissionLossReportsCauseAndPreservesApplicationDependencies() async throws {
    let fixture = try Fixture()
    let cache = try fixture.file("dependent.cache", "keep cache")
    defer { _ = chmod(fixture.app.path, 0o755) }
    let engine = MaintenanceEngine(context: fixture.context(hook: { stage, original, _ in
        if stage == .beforeMove && original == fixture.app.path {
            #expect(chmod(original, 0o555) == 0)
        }
    }))
    let plan = try await uninstall(engine, fixture: fixture)
    #expect(plan.items.count == 2)
    #expect(plan.items.first { $0.kind == .application }?.selection == .required)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    let body = try #require(result.items.first { $0.path == fixture.app.path })
    #expect(body.outcome == .failed)
    #expect(body.reason?.contains("权限") == true)
    #expect(body.reason?.contains("系统错误 13") == true)
    #expect(body.retainedPath == fixture.app.path)
    #expect(result.items.first { $0.path == cache.path }?.outcome == .skipped)
    #expect(try String(contentsOf: cache, encoding: .utf8) == "keep cache")
    #expect(FileManager.default.fileExists(atPath: fixture.app.appendingPathComponent("Contents/Info.plist").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test func stagingCollisionReportsCauseWithoutOverwritingEitherObject() async throws {
    let fixture = try Fixture()
    let before = try ObjectSnapshot.capture(fixture.app.path, application: true)
    let engine = MaintenanceEngine(context: fixture.context(hook: { stage, _, staged in
        if stage == .beforeMove {
            let destination = URL(fileURLWithPath: staged)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("keep existing".utf8).write(to: destination.appendingPathComponent("sentinel"))
        }
    }))
    let plan = try await uninstall(engine, fixture: fixture)
    let result = try await apply(engine, plan, plan.items.map(\.itemID))
    #expect(result.status == .failed)
    #expect(result.trashedBytes == 0)
    #expect(result.items.first?.reason?.contains("系统错误 17") == true)
    #expect(before.matches(try ObjectSnapshot.capture(fixture.app.path, application: true)))
    let item = try #require(plan.items.first)
    let staged = fixture.home.appendingPathComponent("Library/Application Support/TidyNest/Engine/Transactions/\(result.runID)/\(item.itemID)/Fixture.app/sentinel")
    #expect(try String(contentsOf: staged, encoding: .utf8) == "keep existing")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test(arguments: ["application", "parent"])
func applicationMoveDoesNotRequireUnrelatedACLAddFilePermission(_ target: String) async throws {
    let fixture = try Fixture()
    let restricted = target == "application" ? fixture.app : fixture.app.deletingLastPathComponent()
    let chmodProcess = Process()
    chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
    chmodProcess.arguments = ["+a", "user:\(NSUserName()) deny add_file", restricted.path]
    try chmodProcess.run()
    chmodProcess.waitUntilExit()
    try #require(chmodProcess.terminationStatus == 0)
    let directory = try DirectoryFD(path: restricted.path)
    #expect(faccessat(directory.fd, ".", W_OK, AT_EACCESS) != 0)
    let engine = fixture.engine()
    let plan = try await uninstall(engine, fixture: fixture)
    let body = try #require(plan.items.first { $0.kind == .application })
    #expect(body.selection == .required)
    let result = try await apply(engine, plan, [body.itemID])
    #expect(result.status == .completed)
    #expect(!FileManager.default.fileExists(atPath: fixture.app.path))
    let destination = try #require(result.items.first?.trashPath)
    #expect(FileManager.default.fileExists(atPath: destination + "/Contents/Info.plist"))
}

@Test func uninstallPlanBlocksACLDeletionDenialDespiteWritableModes() async throws {
    let fixture = try Fixture()
    for (url, permission) in [(fixture.app, "delete"), (fixture.app.deletingLastPathComponent(), "delete_child")] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "user:\(NSUserName()) deny \(permission)", url.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let directory = try DirectoryFD(path: url.path)
        #expect(faccessat(directory.fd, ".", W_OK, AT_EACCESS) == 0)
    }
    let before = try ObjectSnapshot.capture(fixture.app.path, application: true)
    let plan = try await uninstall(fixture.engine(), fixture: fixture)
    let body = try #require(plan.items.first { $0.kind == .application })
    #expect(body.selection == .blocked)
    #expect(body.blockedReason?.contains("权限") == true)
    #expect(before.matches(try ObjectSnapshot.capture(fixture.app.path, application: true)))
}

@Test func missingMovePermissionIsExplainedBeforeTransientOccupancy() async throws {
    let fixture = try Fixture()
    #expect(chmod(fixture.app.path, 0o555) == 0)
    defer { _ = chmod(fixture.app.path, 0o755) }
    let engine = MaintenanceEngine(context: fixture.context(runtime: { _, _ in
        throw EngineFailure("后台进程暂时占用，请关闭相关窗口。")
    }))
    let plan = try await uninstall(engine, fixture: fixture)
    let body = try #require(plan.items.first { $0.kind == .application })
    #expect(body.selection == .blocked)
    #expect(body.blockedReason?.contains("权限") == true)
    #expect(body.blockedReason?.contains("Finder") == true)
}
