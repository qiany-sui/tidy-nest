import Foundation
import Testing
import Darwin
import TidyNestProtocol
import TidyNestCore
@testable import TidyNestEngine

private final class WrapperEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MaintenanceEvent] = []
    func append(_ event: MaintenanceEvent) { lock.withLock { values.append(event) } }
    var events: [MaintenanceEvent] { lock.withLock { values } }
}

private struct WrapperFixture: Sendable {
    let root: URL
    let home: URL
    let app: URL
    let payload: URL
    let trash: URL
    let bundleID = "org.example.cloudgame"
    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/m2-engine-fixtures/" + UUID().uuidString)
        home = root.appendingPathComponent("home")
        app = home.appendingPathComponent("Applications/云·示例.app")
        payload = app.appendingPathComponent("Wrapper/CloudGame.app")
        trash = root.appendingPathComponent("trash")
        for url in [payload, trash] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try plist(["CFBundleIdentifier": bundleID], at: payload.appendingPathComponent("Info.plist"))
        try Data("fixture executable".utf8).write(to: payload.appendingPathComponent("CloudGame"))
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("WrappedBundle").path, withDestinationPath: "Wrapper/CloudGame.app")
    }
    func plist(_ contents: [String: String], at url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0).write(to: url)
    }
    func file(_ relative: String, under directory: URL? = nil, contents: String = "fixture data") throws -> URL {
        let url = (directory ?? home).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }
    func container(name: String = UUID().uuidString, identifier: String? = nil) throws -> URL {
        let url = home.appendingPathComponent("Library/Containers/" + name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try plist(["MCMMetadataIdentifier": identifier ?? bundleID], at: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        return url
    }
    func context(hook: @escaping @Sendable (ExecutionBoundary, String, String) throws -> Void = { _, _, _ in }) -> EngineContext {
        let applications = home.appendingPathComponent("Applications")
        return EngineContext(home: home.path, appRoots: [applications.path], catalog: {
            try FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "app" }
                .map { try catalogApplication(at: $0.path, name: $0.deletingPathExtension().lastPathComponent, source: "App", observedBundleID: "unknown") }
                .sorted { $0.path < $1.path }
        }, runtime: { _, _ in }, trash: { source in
            let destination = trash.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }, hook: hook, environment: { [:] })
    }
    func plan(_ engine: MaintenanceEngine, uninstall: Bool = true) async throws -> MaintenancePlan {
        let events = WrapperEvents()
        _ = try await engine.handle(command: uninstall ? "plan-uninstall" : "scan-clean", request: uninstall ? MaintenanceRequest(appPath: app.path, expectedBundleID: bundleID) : MaintenanceRequest(), emit: { events.append($0) })
        return try #require(events.events.last?.plan)
    }
    func apply(_ engine: MaintenanceEngine, plan: MaintenancePlan, paths: [String]) async throws -> MaintenanceResult {
        let ids = plan.items.filter { paths.contains($0.path) }.map(\.itemID)
        #expect(ids.count == paths.count)
        let events = WrapperEvents()
        _ = try await engine.handle(command: "apply-plan", request: MaintenanceRequest(planID: plan.planID, selectedItemIDs: ids, confirmed: true), emit: { events.append($0) })
        return try #require(events.events.last?.applyResult)
    }
}

@Test(arguments: [false, true])
func wrappedApplicationOnlySelectedBodyCachesAndLogsMove(_ uninstall: Bool) async throws {
    let fixture = try WrapperFixture()
    let container = try fixture.container(name: uninstall ? fixture.bundleID : UUID().uuidString)
    let global = try fixture.file("Library/Caches/\(fixture.bundleID)/A.cache")
    let globalLog = try fixture.file("Library/Logs/\(fixture.bundleID)/unselected.log")
    let cache = try fixture.file("Data/Library/Caches/unselected.cache", under: container)
    let log = try fixture.file("Data/Library/Logs/selected.log", under: container)
    let retained = try ["Data/Documents/save.dat", "Data/Library/Application Support/save.dat", "Data/Library/Preferences/settings.plist", "Data/tmp/keep.tmp"].map { try fixture.file($0, under: container) }
    let shared = try fixture.file("Library/Group Containers/group.\(fixture.bundleID)/Library/Caches/shared.cache")
    let engine = MaintenanceEngine(context: fixture.context())
    let plan = try await fixture.plan(engine, uninstall: uninstall)
    #expect(plan.scanComplete)
    #expect(Set(plan.items.filter { $0.kind == .file }.map(\.path)) == Set([global.path, globalLog.path, cache.path, log.path]))
    #expect(plan.items.filter { $0.kind == .file }.allSatisfy { $0.selection == .optional })
    if uninstall {
        let body = try #require(plan.items.first { $0.kind == .application })
        #expect(body.path == fixture.app.path)
        #expect(body.selection == .required)
        #expect(body.estimatedBytes != nil)
        #expect(body.reason.contains("包装"))
        #expect(plan.items.filter { $0.kind == .file }.allSatisfy { $0.dependsOnItemIDs == [body.itemID] })
    }
    let added = try fixture.file("Data/Library/Caches/after-plan.cache", under: container)
    let result = try await fixture.apply(engine, plan: plan, paths: [global.path, log.path] + (uninstall ? [fixture.app.path] : []))
    #expect(result.status == .completed)
    #expect(result.items.allSatisfy { $0.outcome == .trashed })
    for url in retained + [globalLog, cache, shared, added] { #expect(try String(contentsOf: url, encoding: .utf8) == "fixture data") }
    #expect(FileManager.default.fileExists(atPath: container.path))
    #expect(FileManager.default.fileExists(atPath: fixture.app.path) == !uninstall)
    if uninstall {
        let body = try #require(result.items.first { $0.path == fixture.app.path })
        let destination = URL(fileURLWithPath: try #require(body.trashPath))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("WrappedBundle").path) == "Wrapper/CloudGame.app")
        #expect(try String(contentsOf: destination.appendingPathComponent("Wrapper/CloudGame.app/CloudGame"), encoding: .utf8) == "fixture executable")
    }
}

@Test func wrappedApplicationDuplicateInstallPreservesSharedData() async throws {
    let fixture = try WrapperFixture()
    let second = fixture.app.deletingLastPathComponent().appendingPathComponent("Second.app")
    try FileManager.default.copyItem(at: fixture.app, to: second)
    let container = try fixture.container()
    let cache = try fixture.file("Data/Library/Caches/A.cache", under: container)
    let global = try fixture.file("Library/Caches/\(fixture.bundleID)/A.cache")
    let engine = MaintenanceEngine(context: fixture.context())
    let plan = try await fixture.plan(engine)
    #expect(plan.scanComplete)
    #expect(plan.items.map(\.path) == [fixture.app.path])
    #expect(try await fixture.apply(engine, plan: plan, paths: [fixture.app.path]).status == .completed)
    #expect(FileManager.default.fileExists(atPath: second.path))
    for url in [cache, global] { #expect(try String(contentsOf: url, encoding: .utf8) == "fixture data") }
}

@Test(arguments: ["duplicate", "mismatch", "missing", "corrupt", "metadata-link", "container-link", "oversize", "unreadable"])
func wrappedApplicationUnprovenContainerIsPreserved(_ reason: String) async throws {
    let fixture = try WrapperFixture()
    let container = try fixture.container(name: fixture.bundleID, identifier: reason == "mismatch" ? "org.example.other" : nil)
    let cache = try fixture.file("Data/Library/Caches/A.cache", under: container)
    let metadata = container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
    if reason == "duplicate" { _ = try fixture.container() }
    if reason == "missing" { try FileManager.default.removeItem(at: metadata) }
    if reason == "corrupt" { try Data("not a plist".utf8).write(to: metadata) }
    if reason == "oversize" { try Data(repeating: 65, count: 1_048_577).write(to: metadata) }
    if reason == "unreadable" { #expect(chmod(metadata.path, 0) == 0) }
    defer { if reason == "unreadable" { _ = chmod(metadata.path, 0o600) } }
    if reason == "metadata-link" {
        let original = fixture.root.appendingPathComponent("metadata-backup")
        try FileManager.default.moveItem(at: metadata, to: original)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: original)
    }
    if reason == "container-link" {
        let original = fixture.root.appendingPathComponent("container-backup")
        try FileManager.default.moveItem(at: container, to: original)
        try FileManager.default.createSymbolicLink(at: container, withDestinationURL: original)
    }
    let engine = MaintenanceEngine(context: fixture.context())
    let plan = try await fixture.plan(engine)
    #expect(plan.scanComplete)
    #expect(plan.items.map(\.path) == [fixture.app.path])
    #expect(plan.scanIssues.contains { $0.reason.contains("容器") && $0.reason.contains("保留") })
    #expect(try await fixture.apply(engine, plan: plan, paths: [fixture.app.path]).status == .completed)
    #expect(try String(contentsOf: cache, encoding: .utf8) == "fixture data")
}

@Test(arguments: ["identifier", "metadata-replaced", "container-replaced", "new-duplicate"])
func wrappedContainerOwnershipChangeBlocksBeforeAnyMove(_ change: String) async throws {
    let fixture = try WrapperFixture()
    let container = try fixture.container()
    let cache = try fixture.file("Data/Library/Caches/A.cache", under: container)
    let metadata = container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
    let engine = MaintenanceEngine(context: fixture.context())
    let plan = try await fixture.plan(engine)
    #expect(plan.items.contains { $0.path == cache.path })
    if change == "identifier" { try fixture.plist(["MCMMetadataIdentifier": "org.example.other"], at: metadata) }
    if change == "metadata-replaced" {
        let data = try Data(contentsOf: metadata)
        try FileManager.default.moveItem(at: metadata, to: fixture.root.appendingPathComponent("old-metadata"))
        try data.write(to: metadata)
    }
    if change == "container-replaced" {
        try FileManager.default.moveItem(at: container, to: fixture.root.appendingPathComponent("old-container"))
        _ = try fixture.container(name: container.lastPathComponent)
        _ = try fixture.file("Data/Library/Caches/A.cache", under: container)
    }
    if change == "new-duplicate" { _ = try fixture.container() }
    let result = try await fixture.apply(engine, plan: plan, paths: [fixture.app.path, cache.path])
    #expect(result.status == .blocked)
    #expect(FileManager.default.fileExists(atPath: fixture.app.path))
    #expect(try String(contentsOf: cache, encoding: .utf8) == "fixture data")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test(arguments: [false, true])
func wrappedContainerOwnershipIsRecheckedAfterBodyAndStaging(_ afterStaging: Bool) async throws {
    let fixture = try WrapperFixture()
    let container = try fixture.container()
    let cache = try fixture.file("Data/Library/Caches/A.cache", under: container)
    let metadata = container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
    let engine = MaintenanceEngine(context: fixture.context(hook: { stage, original, _ in
        if (afterStaging && stage == .afterStaging && original == cache.path) || (!afterStaging && stage == .afterTrash && original == fixture.app.path) {
            try fixture.plist(["MCMMetadataIdentifier": "org.example.other"], at: metadata)
        }
    }))
    let plan = try await fixture.plan(engine, uninstall: !afterStaging)
    let result = try await fixture.apply(engine, plan: plan, paths: [cache.path] + (afterStaging ? [] : [fixture.app.path]))
    #expect(result.status == (afterStaging ? .failed : .partial))
    #expect(result.items.first { $0.path == cache.path }?.outcome == .failed)
    #expect(try String(contentsOf: cache, encoding: .utf8) == "fixture data")
}

@Test func wrappedApplicationChangedPayloadKeepsBodyAndDependentFiles() async throws {
    let fixture = try WrapperFixture()
    let cache = try fixture.file("Library/Caches/\(fixture.bundleID)/A.cache")
    let engine = MaintenanceEngine(context: fixture.context())
    let plan = try await fixture.plan(engine)
    try Data("changed executable".utf8).write(to: fixture.payload.appendingPathComponent("CloudGame"))
    let result = try await fixture.apply(engine, plan: plan, paths: [fixture.app.path, cache.path])
    #expect(result.status == .failed)
    #expect(result.items.first { $0.path == cache.path }?.outcome == .skipped)
    #expect(FileManager.default.fileExists(atPath: fixture.app.path))
    #expect(try String(contentsOf: cache, encoding: .utf8) == "fixture data")
}

@Test func wrappedContainerUnsafeAndPersistentFilesNeverEnterPlan() async throws {
    let fixture = try WrapperFixture()
    let container = try fixture.container()
    let safe = try fixture.file("Data/Library/Caches/safe.cache", under: container)
    let database = try fixture.file("Data/Library/Caches/state.dat", under: container, contents: "SQLite format 3\0persistent")
    let model = try fixture.file("Data/Library/Caches/model.mlmodel", under: container)
    let original = try fixture.file("Data/Library/Logs/linked.log", under: container)
    let hard = container.appendingPathComponent("Data/Library/Logs/hard.log")
    try FileManager.default.linkItem(at: original, to: hard)
    let sym = container.appendingPathComponent("Data/Library/Caches/symbolic")
    try FileManager.default.createSymbolicLink(at: sym, withDestinationURL: fixture.home)
    let engine = MaintenanceEngine(context: fixture.context())
    let plan = try await fixture.plan(engine, uninstall: false)
    #expect(plan.scanComplete)
    #expect(plan.items.map(\.path) == [safe.path])
    #expect(try await fixture.apply(engine, plan: plan, paths: [safe.path]).status == .completed)
    for url in [database, model, original, hard, sym] { #expect(FileManager.default.fileExists(atPath: url.path)) }
}

@Test(arguments: ["absolute", "traversal", "nested", "payload-link", "wrapper-link", "info-link", "top-link"])
func unsafeWrappedApplicationLayoutsAreNotAuthorized(_ layout: String) async throws {
    let fixture = try WrapperFixture()
    let manager = FileManager.default
    let link = fixture.app.appendingPathComponent("WrappedBundle")
    if ["absolute", "traversal", "nested"].contains(layout) {
        try manager.removeItem(at: link)
        let target = layout == "absolute" ? fixture.payload.path : (layout == "traversal" ? "Wrapper/../Wrapper/CloudGame.app" : "Wrapper/Nested/CloudGame.app")
        if layout == "nested" {
            let nested = fixture.app.appendingPathComponent(target)
            try manager.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: fixture.payload, to: nested)
        }
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: target)
    } else {
        let source = layout == "payload-link" ? fixture.payload : (layout == "wrapper-link" ? fixture.payload.deletingLastPathComponent() : (layout == "info-link" ? fixture.payload.appendingPathComponent("Info.plist") : fixture.app))
        let destination = fixture.root.appendingPathComponent("saved-original")
        try manager.moveItem(at: source, to: destination)
        try manager.createSymbolicLink(at: source, withDestinationURL: destination)
    }
    let engine = MaintenanceEngine(context: fixture.context())
    let plan = try await fixture.plan(engine)
    #expect(!plan.scanComplete || plan.items.allSatisfy { $0.selection == .blocked })
    #expect(plan.items.allSatisfy { $0.selection != .required })
    #expect(try manager.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test func wrappedContainerChangeAtFinalVerificationInvalidatesPlan() async throws {
    let fixture = try WrapperFixture()
    let container = try fixture.container()
    let cache = try fixture.file("Data/Library/Caches/A.cache", under: container)
    let metadata = container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
    let engine = MaintenanceEngine(context: fixture.context())
    let events = WrapperEvents()
    _ = try await engine.handle(command: "plan-uninstall", request: MaintenanceRequest(appPath: fixture.app.path, expectedBundleID: fixture.bundleID), emit: { event in
        if event.message == "正在复核应用状态，确认检查结果…" {
            do { try fixture.plist(["MCMMetadataIdentifier": "org.example.changed"], at: metadata) }
            catch { Issue.record(error) }
        }
        events.append(event)
    })
    let plan = try #require(events.events.last?.plan)
    #expect(!plan.scanComplete)
    #expect(plan.scanIssues.contains { $0.reason.contains("容器归属") })
    #expect(try await fixture.apply(engine, plan: plan, paths: [fixture.app.path, cache.path]).status == .blocked)
    #expect(FileManager.default.fileExists(atPath: fixture.app.path))
    #expect(try String(contentsOf: cache, encoding: .utf8) == "fixture data")
}

@Test func wrappedApplicationBodyOnlyDoesNotRequireUnselectedContainer() async throws {
    let fixture = try WrapperFixture()
    let container = try fixture.container()
    let cache = try fixture.file("Data/Library/Caches/A.cache", under: container)
    let engine = MaintenanceEngine(context: fixture.context())
    let plan = try await fixture.plan(engine)
    try fixture.plist(["MCMMetadataIdentifier": "org.example.changed"], at: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
    let result = try await fixture.apply(engine, plan: plan, paths: [fixture.app.path])
    #expect(result.status == .completed)
    #expect(try String(contentsOf: cache, encoding: .utf8) == "fixture data")
}

@Test func wrappedApplicationCancellationPreservesRemainingContainerFiles() async throws {
    let fixture = try WrapperFixture()
    let container = try fixture.container()
    let cache = try fixture.file("Data/Library/Caches/A.cache", under: container)
    let cancellation = EngineCancellation()
    let engine = MaintenanceEngine(context: fixture.context(hook: { stage, original, _ in
        if stage == .afterTrash && original == fixture.app.path { cancellation.cancel() }
    }), cancellation: cancellation)
    let plan = try await fixture.plan(engine)
    let result = try await fixture.apply(engine, plan: plan, paths: [fixture.app.path, cache.path])
    #expect(result.status == .partial)
    #expect(result.items.first { $0.path == cache.path }?.outcome == .cancelled)
    #expect(try String(contentsOf: cache, encoding: .utf8) == "fixture data")
    #expect(!FileManager.default.fileExists(atPath: fixture.app.path))
}

@Test(arguments: ["Data", "Data/Library", "Data/Library/Caches"])
func wrappedContainerDataAncestorLinksNeverAuthorizeFiles(_ linked: String) async throws {
    let fixture = try WrapperFixture()
    let container = try fixture.container()
    let cache = try fixture.file("Data/Library/Caches/A.cache", under: container)
    let source = container.appendingPathComponent(linked)
    let target = fixture.root.appendingPathComponent("outside-data")
    try FileManager.default.moveItem(at: source, to: target)
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
    let engine = MaintenanceEngine(context: fixture.context())
    let plan = try await fixture.plan(engine)
    #expect(!plan.scanComplete)
    #expect(!plan.items.contains { $0.kind == .file })
    #expect(try String(contentsOf: cache, encoding: .utf8) == "fixture data")
}

@Test(arguments: [ExecutionBoundary.beforeMove, .afterStaging, .beforeTrash])
func wrappedContainerDuplicateAtMoveBoundaryPreservesFile(_ boundary: ExecutionBoundary) async throws {
    let fixture = try WrapperFixture()
    let container = try fixture.container()
    let cache = try fixture.file("Data/Library/Caches/A.cache", under: container)
    let engine = MaintenanceEngine(context: fixture.context(hook: { stage, original, _ in
        if stage == boundary && original == cache.path { _ = try fixture.container() }
    }))
    let plan = try await fixture.plan(engine, uninstall: false)
    let result = try await fixture.apply(engine, plan: plan, paths: [cache.path])
    #expect(result.status == .failed)
    #expect(try String(contentsOf: cache, encoding: .utf8) == "fixture data")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test func wrappedContainerOtherOwnerChangingDuringDiscoveryIsRejected() throws {
    let fixture = try WrapperFixture()
    let other = try fixture.container(name: "A-other", identifier: "org.example.other")
    _ = try fixture.container(name: "B-target")
    let metadata = other.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
    var visits = 0
    #expect(throws: (any Error).self) {
        _ = try ContainerOwnership.discover(home: fixture.home.path, bundleID: fixture.bundleID, checkCancelled: {
            visits += 1
            if visits == 2 { try fixture.plist(["MCMMetadataIdentifier": fixture.bundleID], at: metadata) }
        })
    }
}

@Test func wrappedContainerCancellationAtFinalVerificationReturnsCancelled() async throws {
    let fixture = try WrapperFixture()
    let container = try fixture.container()
    _ = try fixture.file("Data/Library/Caches/A.cache", under: container)
    let cancellation = EngineCancellation()
    let events = WrapperEvents()
    let engine = MaintenanceEngine(context: fixture.context(), cancellation: cancellation)
    _ = try await engine.handle(command: "plan-uninstall", request: MaintenanceRequest(appPath: fixture.app.path, expectedBundleID: fixture.bundleID), emit: { event in
        if event.message == "正在复核应用状态，确认检查结果…" { cancellation.cancel() }
        events.append(event)
    })
    #expect(events.events.last?.plan == nil)
    #expect(events.events.last?.error == "扫描已取消。")
    #expect(FileManager.default.fileExists(atPath: fixture.app.path))
}

@Test func wrappedContainerCancellationAfterStagingFinishesCurrentItem() async throws {
    let fixture = try WrapperFixture()
    let container = try fixture.container()
    let current = try fixture.file("Data/Library/Caches/A.cache", under: container)
    let next = try fixture.file("Data/Library/Caches/B.cache", under: container)
    let cancellation = EngineCancellation()
    let engine = MaintenanceEngine(context: fixture.context(hook: { stage, original, _ in
        if stage == .afterStaging && original == current.path { cancellation.cancel() }
    }), cancellation: cancellation)
    let plan = try await fixture.plan(engine, uninstall: false)
    let result = try await fixture.apply(engine, plan: plan, paths: [current.path, next.path])
    #expect(result.status == .partial)
    #expect(result.items.first { $0.path == current.path }?.outcome == .trashed)
    #expect(result.items.first { $0.path == next.path }?.outcome == .cancelled)
    #expect(try String(contentsOf: next, encoding: .utf8) == "fixture data")
}


@Test func wrappedBodyWithExternalReadOnlyFileMovesAndKeepsOtherData() async throws {
    let fixture = try WrapperFixture()
    let container = try fixture.container()
    let save = try fixture.file("Data/Documents/save.dat", under: container)
    let resource = try fixture.file("Wrapper/CloudGame.app/readme.txt", under: fixture.app, contents: "read-only fixture")
    let reader = open(resource.path, O_RDONLY)
    #expect(reader >= 0)
    defer { if reader >= 0 { close(reader) } }
    let base = fixture.context()
    let context = EngineContext(home: base.home, appRoots: base.appRoots, catalog: base.catalog, runtime: { app, target in
        try await RuntimeInspectionService().inspect(applicationPath: app.path, targetPath: target, originalApplicationPath: app.originalPath)
    }, trash: base.trash, hook: base.hook, environment: base.environment)
    let engine = MaintenanceEngine(context: context)
    let plan = try await fixture.plan(engine)
    let body = try #require(plan.items.first { $0.kind == .application })
    #expect(body.selection == .required)
    let result = try await fixture.apply(engine, plan: plan, paths: [fixture.app.path])
    #expect(result.status == .completed)
    let destination = URL(fileURLWithPath: try #require(result.items.first?.trashPath))
    #expect(try String(contentsOf: destination.appendingPathComponent("Wrapper/CloudGame.app/readme.txt"), encoding: .utf8) == "read-only fixture")
    #expect(try String(contentsOf: save, encoding: .utf8) == "fixture data")
    var bytes = [UInt8](repeating: 0, count: 128)
    let count = read(reader, &bytes, bytes.count)
    #expect(count > 0)
    #expect(String(decoding: bytes.prefix(max(0, count)), as: UTF8.self) == "read-only fixture")
}


@Test func readonlyWrappedApplicationIsBlockedBeforeExecution() async throws {
    let fixture = try WrapperFixture()
    let cache = try fixture.file("Library/Caches/\(fixture.bundleID)/keep.cache")
    #expect(chmod(fixture.app.path, 0o555) == 0)
    defer { _ = chmod(fixture.app.path, 0o755) }
    let before = try ObjectSnapshot.capture(fixture.app.path, application: true)
    let engine = MaintenanceEngine(context: fixture.context())
    let plan = try await fixture.plan(engine)
    #expect(plan.scanComplete)
    #expect(plan.items.count == 1)
    let body = try #require(plan.items.first)
    #expect(body.path == fixture.app.path)
    #expect(body.selection == .blocked)
    #expect(body.blockedReason?.contains("权限") == true)
    #expect(body.blockedReason?.contains("Finder") == true)
    #expect(try await fixture.apply(engine, plan: plan, paths: [fixture.app.path]).status == .blocked)
    #expect(before.matches(try ObjectSnapshot.capture(fixture.app.path, application: true)))
    #expect(try String(contentsOf: cache, encoding: .utf8) == "fixture data")
}
