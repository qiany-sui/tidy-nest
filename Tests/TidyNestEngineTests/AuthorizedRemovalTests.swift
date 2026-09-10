import Foundation
import Testing
import Darwin
import TidyNestProtocol
@testable import TidyNestEngine

private final class AuthorizedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MaintenanceEvent] = []
    func append(_ event: MaintenanceEvent) { lock.withLock { values.append(event) } }
    var last: MaintenanceEvent? { lock.withLock { values.last } }
}
private struct AuthorizedFixture {
    let home: URL, app: URL, cache: URL, trash: URL
    init() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/authorized-engine-fixtures/" + UUID().uuidString)
        home = root.appendingPathComponent("home")
        app = home.appendingPathComponent("Applications/Authorized.app")
        cache = home.appendingPathComponent("Library/Caches/org.example.authorized/keep.cache")
        trash = home.appendingPathComponent(".Trash")
        for directory in [app.appendingPathComponent("Contents"), cache.deletingLastPathComponent(), trash] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":"org.example.authorized"], format:.binary, options:0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("unselected personal fixture".utf8).write(to:cache)
        #expect(chmod(app.path, 0o555) == 0)
    }
    func context(operation: @escaping @Sendable (URL, ObjectSnapshot) async throws -> URL) -> EngineContext {
        let application = EngineApplication(path:app.path,bundleID:"org.example.authorized",name:"Authorized",source:"App")
        var context = EngineContext(home:home.path,appRoots:[home.appendingPathComponent("Applications").path],catalog: {
            FileManager.default.fileExists(atPath:application.path) ? [application] : []
        }, runtime:{ _, _ in }, trash:{ source in
            let target = trash.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            try FileManager.default.moveItem(at:source,to:target)
            return target
        }, hook:{ _, _, _ in }, environment:{ [:] })
        context.authorizedTrash = operation
        context.authorizedTrashRoot = trash.path
        return context
    }
    // 测试适配器只改变本次新建 fixture 的模式以模拟系统权限；最终对象仍保留原模式。
    func simulatedSystemTrash(_ source: URL) throws -> URL {
        var info = stat()
        #expect(lstat(source.path, &info) == 0)
        #expect(chmod(source.path, 0o755) == 0)
        let target = trash.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        try FileManager.default.moveItem(at:source,to:target)
        #expect(chmod(target.path, info.st_mode & 0o7777) == 0)
        return target
    }
    func plan(_ engine: MaintenanceEngine) async throws -> MaintenancePlan {
        let events = AuthorizedEvents()
        _ = try await engine.handle(command:"plan-uninstall",request:MaintenanceRequest(appPath:app.path,expectedBundleID:"org.example.authorized"),emit:events.append)
        return try #require(events.last?.plan)
    }
    func apply(_ engine: MaintenanceEngine, _ plan: MaintenancePlan, includeCache: Bool = false) async throws -> MaintenanceResult {
        let events = AuthorizedEvents()
        let ids = plan.items.filter { includeCache || $0.kind == .application }.map(\.itemID)
        _ = try await engine.handle(command:"apply-plan",request:MaintenanceRequest(planID:plan.planID,selectedItemIDs:ids,confirmed:true),emit:events.append)
        return try #require(events.last?.applyResult)
    }
}

@Test func authorizedApplicationPlanIsSelectableAndKeepsOptionalCache() async throws {
    let f = try AuthorizedFixture()
    let engine = MaintenanceEngine(context:f.context { _, _ in Issue.record("计划不得请求系统授权"); throw CancellationError() })
    let plan = try await f.plan(engine)
    let body = try #require(plan.items.first { $0.kind == .application })
    #expect(plan.scanComplete)
    #expect(body.selection == .required)
    #expect(body.requiresAuthorization == true)
    #expect(body.blockedReason == nil)
    #expect(body.estimatedBytes != nil)
    #expect(plan.items.first { $0.path == f.cache.path }?.selection == .optional)
}

@Test func systemAuthorizedRemovalIsVerifiedRecordedAndPreservesUnselectedCache() async throws {
    let f = try AuthorizedFixture()
    let before = try ObjectSnapshot.capture(f.app.path, application:true)
    let engine = MaintenanceEngine(context:f.context { url, _ in try f.simulatedSystemTrash(url) })
    let plan = try await f.plan(engine)
    let result = try await f.apply(engine, plan)
    #expect(result.status == .completed)
    let moved = try #require(result.items.first?.trashPath)
    #expect(before.matches(try ObjectSnapshot.capture(moved,application:true),moved:true))
    #expect(FileManager.default.fileExists(atPath:f.cache.path))
    let data = try #require(await engine.handle(command:"history",request:MaintenanceRequest(),emit:{ _ in }))
    #expect(try MaintenanceJSON.decoder().decode([MaintenanceResult].self,from:data).first?.runID == result.runID)
}

@Test(arguments:[false,true]) func cancelledOrDeniedAuthorizationPreservesApplicationAndDependencies(denied: Bool) async throws {
    let f = try AuthorizedFixture()
    let before = try ObjectSnapshot.capture(f.app.path,application:true)
    let engine = MaintenanceEngine(context:f.context { _, _ in throw denied ? SystemTrashError.denied : SystemTrashError.cancelled })
    let plan = try await f.plan(engine)
    let result = try await f.apply(engine,plan,includeCache:true)
    #expect(result.status == .cancelled)
    #expect(result.items.first?.outcome == .cancelled)
    #expect(result.items.allSatisfy { $0.outcome != .trashed })
    #expect(before.matches(try ObjectSnapshot.capture(f.app.path,application:true)))
    #expect(FileManager.default.fileExists(atPath:f.cache.path))
}

@Test func timedOutSystemAuthorizationIsUnknownEvenWhenSourceStillExists() async throws {
    let f = try AuthorizedFixture()
    let engine = MaintenanceEngine(context:f.context { _, _ in throw SystemTrashError.uncertain("测试超时") })
    let plan = try await f.plan(engine)
    let result = try await f.apply(engine,plan,includeCache:true)
    #expect(result.status == .unknown)
    #expect(result.items.first?.outcome == .unknown)
    #expect(result.items.allSatisfy { $0.outcome != .trashed })
    #expect(FileManager.default.fileExists(atPath:f.cache.path))
}

@Test func changedSystemTrashResultKeepsDependentCacheAndRecordsUnknown() async throws {
    let f = try AuthorizedFixture()
    let engine = MaintenanceEngine(context:f.context { url, _ in
        let destination = try f.simulatedSystemTrash(url)
        try Data("changed during system interaction".utf8).write(to:destination.appendingPathComponent("Contents/extra"))
        return destination
    })
    let plan = try await f.plan(engine)
    let result = try await f.apply(engine,plan,includeCache:true)
    #expect(result.status == .unknown)
    #expect(result.items.first?.trashPath != nil)
    #expect(result.items.allSatisfy { $0.outcome != .trashed })
    #expect(FileManager.default.fileExists(atPath:f.cache.path))
}

@Test func changedApplicationBeforeAuthorizationDoesNotReachSystem() async throws {
    let f = try AuthorizedFixture()
    let engine = MaintenanceEngine(context:f.context { _, _ in Issue.record("变化的包不得交给系统"); throw CancellationError() })
    let plan = try await f.plan(engine)
    try Data("changed".utf8).write(to:f.app.appendingPathComponent("Contents/extra"))
    let result = try await f.apply(engine,plan)
    #expect(result.items.first?.outcome == .failed)
    #expect(FileManager.default.fileExists(atPath:f.app.path))
}

@Test func ordinaryWritableApplicationDoesNotUseAuthorization() async throws {
    let f = try AuthorizedFixture()
    #expect(chmod(f.app.path,0o755) == 0)
    let engine = MaintenanceEngine(context:f.context { _, _ in Issue.record("普通移动不得请求授权"); throw CancellationError() })
    let plan = try await f.plan(engine)
    #expect(plan.items.first { $0.kind == .application }?.requiresAuthorization != true)
    #expect(try await f.apply(engine,plan).status == .completed)
}

@Test func systemAuthorizationFailurePreservesApplicationAndCache() async throws {
    let f = try AuthorizedFixture()
    let engine = MaintenanceEngine(context:f.context { _, _ in throw SystemTrashError.rejected("系统拒绝") })
    let plan = try await f.plan(engine)
    let result = try await f.apply(engine,plan,includeCache:true)
    #expect(result.status == .failed)
    #expect(result.items.first?.outcome == .failed)
    #expect(FileManager.default.fileExists(atPath:f.app.path))
    #expect(FileManager.default.fileExists(atPath:f.cache.path))
}

@Test func completedSystemMoveIsNotLostWhenCancellationArrivesDuringSystemOperation() async throws {
    let f = try AuthorizedFixture()
    let cancellation = EngineCancellation()
    let engine = MaintenanceEngine(context:f.context { source, _ in
        let destination = try f.simulatedSystemTrash(source)
        cancellation.cancel()
        return destination
    }, cancellation:cancellation)
    let plan = try await f.plan(engine)
    let result = try await f.apply(engine,plan,includeCache:true)
    #expect(result.status == .partial)
    #expect(result.items.first?.outcome == .trashed)
    #expect(result.items.last?.outcome == .cancelled)
    #expect(FileManager.default.fileExists(atPath:f.cache.path))
}

@Test func authorizedRemovalRejectsSystemResultOutsideUserTrash() async throws {
    let f = try AuthorizedFixture()
    let engine = MaintenanceEngine(context:f.context { source, _ in source })
    let plan = try await f.plan(engine)
    let result = try await f.apply(engine,plan)
    #expect(result.status == .unknown)
    #expect(result.items.first?.outcome == .unknown)
    #expect(FileManager.default.fileExists(atPath:f.app.path))
}

@Test func legacyPlanWithoutAuthorizationFieldRemainsReadable() throws {
    let item = MaintenanceItem(itemID:"old",ruleID:"rule",path:"/fixture/Old.app",displayName:"Old",kind:.application,action:.trashItem,estimatedBytes:1,reason:"old",impact:"old",selection:.required,blockedReason:nil,dependsOnItemIDs:[])
    let data = try MaintenanceJSON.encoder().encode(item)
    #expect(!String(decoding:data,as:UTF8.self).contains("requiresAuthorization"))
    #expect(try MaintenanceJSON.decoder().decode(MaintenanceItem.self,from:data).requiresAuthorization == nil)
}


@Test(arguments: [-1711, -1718, -1712, -609, -600, 0])
func missingSystemReplyIsUnknown(code: Int) async throws {
    let f = try AuthorizedFixture()
    let engine = MaintenanceEngine(context: f.context { _, _ in
        throw SystemTrashError.appleEventFailure(code: code, message: "未收到确定回执")
    })
    let plan = try await f.plan(engine)
    let result = try await f.apply(engine, plan, includeCache: true)
    #expect(result.status == .unknown)
    #expect(result.items.first?.outcome == .unknown)
    #expect(FileManager.default.fileExists(atPath: f.app.path))
    #expect(FileManager.default.fileExists(atPath: f.cache.path))
}

@Test func systemMoveJournalFailureRetainsKnownTrashLocation() async throws {
    let f = try AuthorizedFixture()
    let engine = MaintenanceEngine(context: f.context { source, _ in
        let destination = try f.simulatedSystemTrash(source)
        let journals = f.home.appendingPathComponent("Library/Application Support/TidyNest/Engine/Journals")
        for file in try FileManager.default.contentsOfDirectory(at: journals, includingPropertiesForKeys: nil) {
            // 仅破坏本次测试的日志权限，模拟移动完成后的持久化失败。
            #expect(chmod(file.path, 0o644) == 0)
        }
        return destination
    })
    let plan = try await f.plan(engine)
    let result = try await f.apply(engine, plan, includeCache: true)
    #expect(result.status == .unknown)
    let body = try #require(result.items.first)
    #expect(body.outcome == .unknown)
    let destination = try #require(body.trashPath)
    #expect(FileManager.default.fileExists(atPath: destination))
    #expect(body.retainedPath == nil)
    #expect(FileManager.default.fileExists(atPath: f.cache.path))
}

@MainActor @Test func authorizedFileReferenceSurvivesSameNameReplacement() throws {
    let f = try AuthorizedFixture()
    let source = try DirectoryFD(path: f.app.path)
    defer { withExtendedLifetime(source) {} }
    let descriptor = try FinderTrashService.targetReference(source)
    let destination = try f.simulatedSystemTrash(f.app)
    try FileManager.default.createDirectory(at: f.app, withIntermediateDirectories: false)
    let text = String(decoding: try #require(descriptor.data), as: UTF8.self)
    let reference = try #require(CFURLCreateWithString(nil, text as CFString, nil))
    #expect(CFURLIsFileReferenceURL(reference))
    let resolved = try #require(CFURLCreateFilePathURL(nil, reference, nil)?.takeRetainedValue())
    #expect((resolved as URL).path == destination.path)
    #expect((resolved as URL).path != f.app.path)
}

@MainActor @Test func authorizedReferenceCreationUsesHeldObjectAfterPathReplacement() throws {
    let f = try AuthorizedFixture()
    let source = try DirectoryFD(path: f.app.path)
    defer { withExtendedLifetime(source) {} }
    let destination = try f.simulatedSystemTrash(f.app)
    try FileManager.default.createDirectory(at: f.app, withIntermediateDirectories: false)
    // 引用创建时原路径已经指向替身，仍须绑定之前持有的对象。
    let descriptor = try FinderTrashService.targetReference(source)
    let text = String(decoding: try #require(descriptor.data), as: UTF8.self)
    let reference = try #require(CFURLCreateWithString(nil, text as CFString, nil))
    let resolved = try #require(CFURLCreateFilePathURL(nil, reference, nil)?.takeRetainedValue())
    #expect((resolved as URL).path == destination.path)
    #expect((resolved as URL).path != f.app.path)
}

@Test func selectedCacheMovesOnlyAfterVerifiedSystemApplicationRemoval() async throws {
    let f = try AuthorizedFixture()
    let engine = MaintenanceEngine(context: f.context { source, _ in try f.simulatedSystemTrash(source) })
    let plan = try await f.plan(engine)
    let result = try await f.apply(engine, plan, includeCache: true)
    #expect(result.status == .completed)
    #expect(result.items.count == 2)
    #expect(result.items.allSatisfy { $0.outcome == .trashed })
    #expect(!FileManager.default.fileExists(atPath: f.cache.path))
}


@MainActor @Test func authorizedReferenceRejectsDifferentObject() throws {
    let f = try AuthorizedFixture()
    let another = try AuthorizedFixture()
    let expectedID = try #require(f.app.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
    let source = try DirectoryFD(path: f.app.path)
    defer { withExtendedLifetime(source) {} }
    let reference = try #require(CFURLCreateFileReferenceURL(nil, another.app as CFURL, nil)?.takeRetainedValue())
    #expect(throws: SystemTrashError.self) {
        try FinderTrashService.verifyReference(reference, resourceID: expectedID, inode: source.identities.last!.inode)
    }
}
