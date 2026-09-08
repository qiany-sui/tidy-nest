import Foundation
import Darwin
import TidyNestProtocol

private struct CatalogRecord: Codable, Sendable {
    let app: EngineApplication
    let root: FileIdentity
    let info: FileIdentity?
}
private struct SavedPlan: Codable, Sendable {
    let plan: MaintenancePlan
    let snapshots: [String: ObjectSnapshot]
    let owners: [String: EngineApplication]
    let catalogDigest: String
    let catalogRecords: [CatalogRecord]
}
private struct JournalEntry: Codable {
    let state: String
    let itemID: String?
    let path: String?
    let retainedPath: String?
    let result: MaintenanceItemResult?
    let accepted: MaintenanceResult?
}
private final class ExecutionProgress {
    var accepted: MaintenanceResult?
    var items: [MaintenanceItemResult] = []
}
private final class EventStream: @unchecked Sendable {
    let runID: String
    let emit: @Sendable (MaintenanceEvent) -> Void
    private let lock = NSLock()
    private var sequence = 0
    init(runID: String, emit: @escaping @Sendable (MaintenanceEvent) -> Void) { self.runID = runID; self.emit = emit }
    func send(_ type: MaintenanceEventKind, message: String? = nil, candidate: MaintenanceItem? = nil, itemResult: MaintenanceItemResult? = nil, plan: MaintenancePlan? = nil, result: MaintenanceResult? = nil, error: String? = nil) {
        lock.withLock {
            sequence += 1
            emit(MaintenanceEvent(schemaVersion: 1, runID: runID, sequence: sequence, type: type, message: message, candidate: candidate, itemResult: itemResult, plan: plan, applyResult: result, error: error))
        }
    }
}

public actor MaintenanceEngine {
    private let context: EngineContext
    private let cancellation: EngineCancellation
    public init() { context = .production(); cancellation = EngineCancellation() }
    public init(cancellation: EngineCancellation) { context = .production(); self.cancellation = cancellation }
    internal init(context: EngineContext, cancellation: EngineCancellation = EngineCancellation()) { self.context = context; self.cancellation = cancellation }

    public func handle(command: String, request: MaintenanceRequest, emit: @escaping @Sendable (MaintenanceEvent) -> Void) async throws -> Data? {
        // 直接调用引擎也必须经过同一输入约束，不能绕过 CLI 传入未确认的选择。
        _ = try MaintenanceJSON.request(from: MaintenanceJSON.encoder().encode(request), command: command)
        let rules = try EngineRules()
        let engineDigest = try engineDigest(rules)
        if command == "capabilities" {
            return try MaintenanceJSON.encoder().encode(EngineCapabilities(schemaVersion: 1, engineVersion: EngineRules.engineVersion, engineDigest: engineDigest, rulesVersion: EngineRules.version, supportedRuleIDs: EngineRules.ids, supportedActions: [.trashItem]))
        }
        if command == "list-apps" {
            let apps = try await context.catalog()
            let data = apps.map { ["name": $0.name, "bundle_id": $0.bundleID, "source": $0.source, "uninstall_name": $0.name, "path": $0.path, "size": "未知"] }
            return try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
        }
        let store = try EngineStore(home: context.home)
        switch command {
        case "protections": return try MaintenanceJSON.encoder().encode(protections(store))
        case "protect-path", "unprotect-path":
            let lock = try store.lock(); defer { flock(lock, LOCK_UN); close(lock) }
            let path = try canonicalPath(request.protectedPath!)
            guard pathInside(path, context.home) || context.appRoots.contains(where: { pathInside(path, $0) }) else { throw EngineFailure("长期保护仅接受用户目录或普通应用根内的路径。") }
            var paths = try protections(store)
            if command == "protect-path" { paths.append(path) } else { paths.removeAll { $0 == path } }
            paths = Set(paths).sorted()
            try store.write(paths, "protections.json", exclusive: false)
            return try MaintenanceJSON.encoder().encode(paths)
        case "history": return try MaintenanceJSON.encoder().encode(history(store))
        case "scan-clean", "plan-uninstall":
            let stream = EventStream(runID: UUID().uuidString, emit: emit)
            stream.send(.progress, message: "正在读取应用信息与保护设置…")
            do {
                let saved = try await makePlan(uninstall: command == "plan-uninstall", request: request, rules: rules, engineDigest: engineDigest, store: store, stream: stream)
                stream.send(.progress, message: "正在整理检查结果…")
                try store.write(saved, "Plans/\(saved.plan.planID).json")
                stream.send(.result, plan: saved.plan)
            } catch {
                stream.send(.result, error: cancellation.isCancelled || error is CancellationError ? "扫描已取消。" : error.localizedDescription)
            }
            return nil
        case "apply-plan":
            let runID = UUID().uuidString
            let stream = EventStream(runID: runID, emit: emit)
            stream.send(.progress, message: "校验本地计划、选择、保护配置和维护锁")
            let progress = ExecutionProgress()
            do {
                let result = try await execute(progress: progress, request: request, rules: rules, engineDigest: engineDigest, store: store, stream: stream)
                stream.send(.result, result: result)
            } catch {
                let result: MaintenanceResult
                if let accepted = progress.accepted {
                    let completed = Dictionary(uniqueKeysWithValues: progress.items.map { ($0.itemID, $0) })
                    let known = accepted.items.map { completed[$0.itemID] ?? $0 }
                    result = MaintenanceResult(planID: accepted.planID, runID: runID, title: accepted.title, status: .unknown, startedAt: accepted.startedAt, finishedAt: Date(), items: known, selectedBytes: accepted.selectedBytes, trashedBytes: known.filter { $0.outcome == .trashed }.reduce(0) { $0 + ($1.estimatedBytes ?? 0) }, freeBytesDelta: nil, message: "执行已接受，但事务记录未完整持久化，需要人工核对：" + error.localizedDescription)
                } else {
                    result = MaintenanceResult(planID: request.planID!, runID: runID, title: "维护未执行", status: cancellation.isCancelled ? .cancelled : .blocked, startedAt: Date(), finishedAt: Date(), items: [], selectedBytes: 0, trashedBytes: 0, freeBytesDelta: nil, message: error.localizedDescription)
                }
                try? store.write(result, "History/\(runID).json")
                stream.send(.result, result: result)
            }
            return nil
        default: throw MaintenanceProtocolError.invalidCommand
        }
    }

    private func engineDigest(_ rules: EngineRules) throws -> String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        return digest(try Data(contentsOf: executable) + Data((rules.resourceDigest + EngineRules.engineVersion + EngineRules.version).utf8))
    }
    private func protections(_ store: EngineStore) throws -> [String] {
        if !store.exists("protections.json") { return [] }
        let paths = try store.read([String].self, "protections.json")
        for path in paths { _ = try canonicalPath(path) }
        return paths
    }
    private func captureCatalog(_ catalog: [EngineApplication]) throws -> [CatalogRecord] {
        try catalog.sorted { $0.path < $1.path }.map { app in
            let root = try identity(at: app.path)
            return CatalogRecord(app: app, root: root, info: root.type == S_IFLNK ? nil : try identity(at: app.metadataPath ?? app.path + "/Contents/Info.plist"))
        }
    }
    private func catalogDigest(_ catalog: [EngineApplication]) throws -> String {
        digest(try MaintenanceJSON.encoder().encode(captureCatalog(catalog)))
    }
    private func checkCancelled() throws { if cancellation.isCancelled || Task.isCancelled { throw CancellationError() } }

    private func makePlan(uninstall: Bool, request: MaintenanceRequest, rules: EngineRules, engineDigest: String, store: EngineStore, stream: EventStream) async throws -> SavedPlan {
        let configuration = try rules.configuration(context: context, protections: protections(store))
        var issues: [PlanIssue] = []
        var complete = true
        var catalog: [EngineApplication] = []
        var fingerprint = "unavailable"
        var catalogRecords: [CatalogRecord] = []
        do {
            try checkCancelled()
            catalog = try await context.catalog()
            catalogRecords = try captureCatalog(catalog)
            fingerprint = digest(try MaintenanceJSON.encoder().encode(catalogRecords))
        } catch {
            if error is CancellationError { throw error }
            complete = false; issues.append(PlanIssue(path: context.home, reason: "安装集合不可完整核验：" + error.localizedDescription))
        }
        var items: [MaintenanceItem] = []
        var snapshots: [String: ObjectSnapshot] = [:]
        var owners: [String: EngineApplication] = [:]
        let groups = Dictionary(grouping: catalog, by: { $0.bundleID.lowercased() })
        var selectedApps = catalog
        var appItemID: String?
        if uninstall {
            let path = try canonicalPath(request.appPath!)
            guard let app = catalog.first(where: { $0.path == path }) else {
                complete = false; issues.append(PlanIssue(path: path, reason: "本次安装检查未找到此应用，无法生成移除计划。请刷新应用列表后重试。"))
                selectedApps = []
                return finishPlan()
            }
            guard app.bundleID == request.expectedBundleID else {
                // Mole 对包装应用可能返回 unknown；保留身份校验，但不能把已找到的应用误报为缺失。
                let reason = app.unsupportedReason.map { "应用仍然存在。" + $0 }
                    ?? "应用仍然存在，但标识与应用列表不一致。请刷新应用列表后重新检查。"
                complete = false; issues.append(PlanIssue(path: path, reason: reason))
                selectedApps = []
                return finishPlan()
            }
            selectedApps = [app]
        }
        for (index, app) in selectedApps.enumerated() {
            try checkCancelled()
            stream.send(.progress, message: "正在检查 \(app.name)（\(index + 1)/\(selectedApps.count) 个应用）")
            var block: String?
            if groups[app.bundleID.lowercased()]?.count != 1 { block = "bundle ID 安装归属不唯一。" }
            if !validBundle(app.bundleID) { block = app.unsupportedReason ?? "bundle ID 不完整，不授权维护动作。" }
            if !context.appRoots.contains(where: { pathInside(app.path, $0) && app.path != $0 }) || !app.path.hasSuffix(".app") { block = "应用不在首批普通应用安装范围。" }
            block = block ?? rules.appBlock(app, clean: !uninstall)
            if configuration.protections.contains(where: { protectionContains(app.path, $0) || protectionContains($0, app.path) }) { block = "用户长期保护的应用。" }
            if block == nil {
                do {
                    guard try bundleID(at: app.path) == app.bundleID else { throw EngineFailure("应用标识已变化。") }
                    _ = try DirectoryFD(path: app.path)
                    try await context.runtime(app, app.path)
                } catch { block = error.localizedDescription }
            }
            if uninstall {
                let id = UUID().uuidString; appItemID = id
                var snapshot: ObjectSnapshot?
                if block == nil {
                    do { snapshot = try ObjectSnapshot.capture(app.path, application: true) }
                    catch { block = error.localizedDescription }
                }
                let item = MaintenanceItem(itemID: id, ruleID: EngineRules.ids[2], path: app.path, displayName: app.name, kind: .application, action: .trashItem, estimatedBytes: snapshot?.bytes, reason: "移除选定的普通应用本体", impact: "应用将无法启动，可从废纸篓手动恢复。相关缓存与日志单独选择。", selection: block == nil ? .required : .blocked, blockedReason: block, dependsOnItemIDs: [])
                items.append(item); owners[id] = app
                if let snapshot { snapshots[id] = snapshot }
            }
            if let block { issues.append(PlanIssue(path: app.path, reason: block)); continue }
            for (folder, rule) in [("Caches", EngineRules.ids[0]), ("Logs", EngineRules.ids[1])] {
                let root = context.home + "/Library/" + folder + "/" + app.bundleID
                if try existingIdentity(root) == nil { continue }
                do { try enumerate(root, app: app, rule: rule, dependencies: appItemID.map { [$0] } ?? []) }
                catch { complete = false; issues.append(PlanIssue(path: root, reason: "枚举不完整：" + error.localizedDescription)) }
            }
        }
        if !uninstall {
            for folder in ["Caches", "Logs"] {
                let root = context.home + "/Library/" + folder
                if try existingIdentity(root) == nil { continue }
                do {
                    for name in try DirectoryFD(path: root).names() where groups[name.lowercased()] == nil {
                        issues.append(PlanIssue(path: root + "/" + name, reason: "没有唯一的已安装应用精确 bundle ID 归属，已跳过。"))
                    }
                } catch { complete = false; issues.append(PlanIssue(path: root, reason: error.localizedDescription)) }
            }
        }
        try checkCancelled()
        stream.send(.progress, message: "正在复核应用状态，确认检查结果…")
        // 枚举期间发生安装变化会使整个计划不可执行。
        do {
            guard try await catalogDigest(context.catalog()) == fingerprint else { throw EngineFailure("扫描期间安装集合发生变化。") }
        } catch {
            complete = false; issues.append(PlanIssue(path: context.home, reason: error.localizedDescription))
        }
        return finishPlan()

        func finishPlan() -> SavedPlan {
            let plan = MaintenancePlan(schemaVersion: 1, planID: UUID().uuidString, runID: stream.runID, kind: uninstall ? .uninstall : .clean, title: uninstall ? "移除应用计划" : "缓存与日志清理计划", engineVersion: EngineRules.engineVersion, engineDigest: engineDigest, rulesVersion: EngineRules.version, configurationDigest: configuration.digest, createdAt: Date(), scopeRoots: uninstall ? selectedApps.map(\.path) : [context.home + "/Library/Caches", context.home + "/Library/Logs"], scanComplete: complete, scanIssues: issues, items: items)
            return SavedPlan(plan: plan, snapshots: snapshots, owners: owners, catalogDigest: fingerprint, catalogRecords: catalogRecords)
        }
        func enumerate(_ directory: String, app: EngineApplication, rule: String, dependencies: [String]) throws {
            try checkCancelled()
            if let reason = rules.fileBlock(directory, configuration: configuration) {
                issues.append(PlanIssue(path: directory, reason: reason)); return
            }
            let parent = try DirectoryFD(path: directory)
            for name in try parent.names() {
                try checkCancelled()
                let path = directory + "/" + name
                if let reason = rules.fileBlock(path, configuration: configuration) { issues.append(PlanIssue(path: path, reason: reason)); continue }
                let info = try identity(parent: parent.fd, name: name)
                if info.type == S_IFDIR { try enumerate(path, app: app, rule: rule, dependencies: dependencies); continue }
                if info.type != S_IFREG || info.links != 1 || info.mode & 0o6022 != 0 || info.owner != getuid() {
                    issues.append(PlanIssue(path: path, reason: "链接、特殊类型、权限或属主不在首批范围，已保留。")); continue
                }
                do {
                    let snapshot = try ObjectSnapshot.capture(path, application: false)
                    let fd = openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw EngineFailure("无法读取文件类型。") }
                    var bytes = [UInt8](repeating: 0, count: 16)
                    let count = Darwin.read(fd, &bytes, 16); close(fd)
                    guard count >= 0 else { throw EngineFailure("无法核验文件内容类型。") }
                    if Data(bytes.prefix(max(0, count))).starts(with: Data("SQLite format 3".utf8)) {
                        issues.append(PlanIssue(path: path, reason: "SQLite 数据库已保留。")); continue
                    }
                    guard snapshot.matches(try ObjectSnapshot.capture(path, application: false)) else { throw EngineFailure("扫描期间文件发生变化。") }
                    let id = UUID().uuidString
                    let item = MaintenanceItem(itemID: id, ruleID: rule, path: path, displayName: name, kind: .file, action: .trashItem, estimatedBytes: snapshot.bytes, reason: "精确匹配 \(app.bundleID) 的普通\(rule == EngineRules.ids[0] ? "缓存" : "日志")文件", impact: "移入废纸篓；缓存可能重新生成，日志移走后历史排错记录不可直接读取。", selection: .optional, blockedReason: nil, dependsOnItemIDs: dependencies)
                    items.append(item); snapshots[id] = snapshot; owners[id] = app
                } catch { complete = false; issues.append(PlanIssue(path: path, reason: error.localizedDescription)) }
            }
        }
    }

    private func execute(progress: ExecutionProgress, request: MaintenanceRequest, rules: EngineRules, engineDigest: String, store: EngineStore, stream: EventStream) async throws -> MaintenanceResult {
        guard let planID = request.planID, UUID(uuidString: planID) != nil else { throw EngineFailure("计划 ID 无效。") }
        let lock = try store.lock(); defer { flock(lock, LOCK_UN); close(lock) }
        let saved = try store.read(SavedPlan.self, "Plans/\(planID).json")
        let plan = saved.plan
        let configuration = try rules.configuration(context: context, protections: protections(store))
        guard plan.schemaVersion == 1, plan.planID == planID, plan.engineVersion == EngineRules.engineVersion, plan.engineDigest == engineDigest, plan.rulesVersion == EngineRules.version, plan.configurationDigest == configuration.digest, plan.scanComplete else { throw EngineFailure("计划版本、保护配置或完整性已变化，请重新扫描。") }
        guard !store.exists("Consumed/\(planID).json") else { throw EngineFailure("此计划已消费，请重新生成计划。") }
        let ids = request.selectedItemIDs!
        let selected = Set(ids)
        guard !ids.isEmpty, selected.count == ids.count, Set(plan.items.map(\.itemID)).count == plan.items.count, selected.isSubset(of: Set(plan.items.map(\.itemID))) else { throw EngineFailure("选择为空、重复或包含未知项目。") }
        guard plan.items.filter({ $0.selection == .required }).allSatisfy({ selected.contains($0.itemID) }) else { throw EngineFailure("应用本体为必选项。") }
        let items = plan.items.filter { selected.contains($0.itemID) }.sorted { a, b in
            if a.kind != b.kind { return a.kind == .application }
            return a.path < b.path
        }
        for item in plan.items {
            guard item.selection != .blocked, item.blockedReason == nil, item.action == .trashItem, UUID(uuidString: item.itemID) != nil, let owner = saved.owners[item.itemID], saved.snapshots[item.itemID] != nil, Set(item.dependsOnItemIDs).isSubset(of: selected) else { throw EngineFailure("计划项目已阻止、快照缺失或依赖未选中。") }
            _ = try canonicalPath(item.path)
            if item.kind == .application {
                guard plan.kind == .uninstall, item.selection == .required, item.ruleID == EngineRules.ids[2], item.path == owner.path, context.appRoots.contains(where: { pathInside(item.path, $0) && item.path != $0 }), item.path.hasSuffix(".app"), item.dependsOnItemIDs.isEmpty else { throw EngineFailure("应用计划范围不合法。") }
            } else {
                guard item.selection == .optional, [EngineRules.ids[0], EngineRules.ids[1]].contains(item.ruleID), validBundle(owner.bundleID) else { throw EngineFailure("文件规则不合法。") }
                let folder = item.ruleID == EngineRules.ids[0] ? "Caches" : "Logs"
                let root = context.home + "/Library/" + folder + "/" + owner.bundleID
                guard pathInside(item.path, root), item.path != root, rules.fileBlock(item.path, configuration: configuration) == nil else { throw EngineFailure("文件不在计划授权范围或已受保护。") }
                if plan.kind == .uninstall {
                    guard item.dependsOnItemIDs.count == 1, plan.items.contains(where: { $0.itemID == item.dependsOnItemIDs[0] && $0.kind == .application && $0.path == owner.path }) else { throw EngineFailure("残留缺少应用本体依赖。") }
                } else if !item.dependsOnItemIDs.isEmpty { throw EngineFailure("清理计划包含非法依赖。") }
            }
            guard rules.appBlock(owner, clean: plan.kind == .clean) == nil else { throw EngineFailure("应用受到固定规则保护。") }
        }
        try checkCancelled()
        guard try await catalogDigest(context.catalog()) == saved.catalogDigest else { throw EngineFailure("安装集合或应用标识已变化，请重新生成计划。") }
        let started = Date(); let selectedBytes = items.reduce(UInt64(0)) { $0 + ($1.estimatedBytes ?? 0) }
        let accepted = MaintenanceResult(planID: planID, runID: stream.runID, title: plan.title, status: .unknown, startedAt: started, finishedAt: started, items: items.map { MaintenanceItemResult(itemID: $0.itemID, path: $0.path, outcome: .unknown, reason: "执行已接受，缺少最终记录时需核对。", trashPath: nil, retainedPath: $0.path, estimatedBytes: $0.estimatedBytes) }, selectedBytes: selectedBytes, trashedBytes: 0, freeBytesDelta: nil, message: "事务尚未完成。")
        progress.accepted = accepted
        try store.write(accepted, "Consumed/\(planID).json")
        try journal(store, stream.runID, state: "accepted", accepted: accepted)
        var results: [MaintenanceItemResult] = []
        var cancellationObserved = false
        for item in items {
            if cancellation.isCancelled || Task.isCancelled { cancellationObserved = true }
            let result: MaintenanceItemResult
            if cancellationObserved {
                result = itemResult(item, .cancelled, "已取消后续项目，当前文件保留。", retained: item.path)
            } else if item.dependsOnItemIDs.contains(where: { id in !results.contains(where: { $0.itemID == id && $0.outcome == .trashed }) }) {
                result = itemResult(item, .skipped, "应用本体未确定移入废纸篓，相关残留全部保留。", retained: item.path)
            } else {
                stream.send(.progress, message: "再次检查：" + item.displayName)
                do {
                    let currentConfiguration = try rules.configuration(context: context, protections: protections(store))
                    guard currentConfiguration.digest == plan.configurationDigest else { throw EngineFailure("执行期间保护配置发生变化，当前及后续目标保留，请重新扫描。") }
                    let removedBodies = Set(results.filter { result in result.outcome == .trashed && plan.items.contains { $0.itemID == result.itemID && $0.kind == .application } }.map(\.path))
                    let expectedRecords = saved.catalogRecords.filter { !removedBodies.contains($0.app.path) }
                    let currentRecords = try await captureCatalog(context.catalog())
                    guard digest(try MaintenanceJSON.encoder().encode(currentRecords)) == digest(try MaintenanceJSON.encoder().encode(expectedRecords)) else { throw EngineFailure("执行期间安装集合或应用身份发生变化，当前目标保留。") }
                    var owner = saved.owners[item.itemID]!
                    if let body = results.first(where: { item.dependsOnItemIDs.contains($0.itemID) && $0.outcome == .trashed }), let trashPath = body.trashPath {
                        owner.originalPath = owner.path
                        owner.path = trashPath
                    }
                    try await context.runtime(owner, item.path)
                    if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
                    result = try move(item, snapshot: saved.snapshots[item.itemID]!, store: store, runID: stream.runID)
                } catch {
                    if error is CancellationError { cancellationObserved = true }
                    result = itemResult(item, error is CancellationError ? .cancelled : .failed, error.localizedDescription, retained: item.path)
                }
            }
            results.append(result)
            progress.items = results
            try journal(store, stream.runID, state: "itemResult", item: item, result: result)
            stream.send(.itemResult, itemResult: result)
        }
        let successful = results.filter { $0.outcome == .trashed }
        let status: MaintenanceStatus = results.contains(where: { $0.outcome == .unknown }) ? .unknown : (successful.count == items.count ? .completed : (!successful.isEmpty ? .partial : (cancellationObserved ? .cancelled : .failed)))
        let result = MaintenanceResult(planID: planID, runID: stream.runID, title: plan.title, status: status, startedAt: started, finishedAt: Date(), items: results, selectedBytes: selectedBytes, trashedBytes: successful.reduce(0) { $0 + ($1.estimatedBytes ?? 0) }, freeBytesDelta: nil, message: "移入废纸篓不会立即释放对应空间；未自动清空废纸篓。")
        try store.write(result, "History/\(stream.runID).json")
        try journal(store, stream.runID, state: "finished")
        return result
    }

    private func move(_ item: MaintenanceItem, snapshot: ObjectSnapshot, store: EngineStore, runID: String) throws -> MaintenanceItemResult {
        guard snapshot.matches(try ObjectSnapshot.capture(item.path, application: item.kind == .application)) else { throw EngineFailure("目标、父目录或应用成员已变化，请重新生成计划。") }
        let sourceURL = URL(fileURLWithPath: item.path)
        let source = try DirectoryFD(path: sourceURL.deletingLastPathComponent().path)
        guard source.identities.count == snapshot.parents.count, zip(source.identities, snapshot.parents).allSatisfy({ $0.sameDirectory($1) }) else { throw EngineFailure("父目录身份已变化。") }
        let runDirectory = store.root + "/Transactions/" + runID
        try EngineStore.privateDirectory(runDirectory)
        let itemDirectory = runDirectory + "/" + item.itemID
        try EngineStore.privateDirectory(itemDirectory)
        let destination = try DirectoryFD(path: itemDirectory)
        let staged = itemDirectory + "/" + sourceURL.lastPathComponent
        guard snapshot.members.first?.identity.device == destination.identities.last?.device else { throw EngineFailure("目标与私有暂存目录不在同一卷，已保留。") }
        try journal(store, runID, state: "moveIntent", item: item, retained: staged)
        try context.hook(.beforeMove, item.path, staged)
        // macOS 没有以源 inode 为条件的 rename；移后复验只能检测可观察到的竞争变化。
        guard renameatx_np(source.fd, sourceURL.lastPathComponent, destination.fd, sourceURL.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw EngineFailure("无法独占移入暂存区，源文件保留。") }
        var knownTrash: String?
        do {
            guard fsync(source.fd) == 0, fsync(destination.fd) == 0 else { throw EngineFailure("暂存目录未能同步。") }
            try journal(store, runID, state: "staged", item: item, retained: staged)
            try context.hook(.afterStaging, item.path, staged)
            guard snapshot.matches(try ObjectSnapshot.capture(staged, application: item.kind == .application), moved: true) else { throw EngineFailure("暂存复验发现对象或成员变化。") }
            // 固定的 fd 父链仍需与原路径核对；若父目录被替换，恢复不能写入替换目录。
            let liveParent = try DirectoryFD(path: sourceURL.deletingLastPathComponent().path)
            guard zip(liveParent.identities, source.identities).allSatisfy({ $0.sameDirectory($1) }), liveParent.identities.count == source.identities.count else { throw EngineFailure("移动期间原父目录被替换。") }
            try journal(store, runID, state: "trashIntent", item: item, retained: staged)
            try context.hook(.beforeTrash, item.path, staged)
            guard snapshot.matches(try ObjectSnapshot.capture(staged, application: item.kind == .application), moved: true) else { throw EngineFailure("移入废纸篓前内容发生变化。") }
            let trashURL = try context.trash(URL(fileURLWithPath: staged))
            knownTrash = trashURL.path
            try context.hook(.afterTrash, item.path, trashURL.path)
            guard !FileManager.default.fileExists(atPath: staged), snapshot.matches(try ObjectSnapshot.captureFinalLocation(trashURL.path, application: item.kind == .application), moved: true) else {
                let result = itemResult(item, .unknown, "系统返回后无法确定最终对象身份，请核对废纸篓和保留位置。", trash: trashURL.path, retained: FileManager.default.fileExists(atPath: staged) ? staged : nil)
                try journal(store, runID, state: "needsReview", item: item, retained: result.retainedPath, result: result)
                return result
            }
            let result = itemResult(item, .trashed, nil, trash: trashURL.path)
            try journal(store, runID, state: "succeeded", item: item, result: result)
            return result
        } catch {
            guard (try? identity(at: staged)) != nil else {
                let result = itemResult(item, .unknown, "暂存对象已不在原位，不能确定系统操作结果：" + error.localizedDescription, trash: knownTrash, retained: knownTrash == nil ? staged : nil)
                try? journal(store, runID, state: "needsReview", item: item, retained: staged, result: result)
                return result
            }
            let liveParent = try? DirectoryFD(path: sourceURL.deletingLastPathComponent().path)
            let sameParent = liveParent.map { $0.identities.count == source.identities.count && zip($0.identities, source.identities).allSatisfy({ $0.sameDirectory($1) }) } ?? false
            if sameParent && renameatx_np(destination.fd, sourceURL.lastPathComponent, source.fd, sourceURL.lastPathComponent, UInt32(RENAME_EXCL)) == 0 {
                _ = fsync(source.fd); _ = fsync(destination.fd)
                let result = itemResult(item, .failed, "操作未完成，已恢复原位：" + error.localizedDescription, retained: item.path)
                try journal(store, runID, state: "restored", item: item, retained: item.path, result: result)
                return result
            }
            let result = itemResult(item, .unknown, "原位置冲突或父目录变化，未覆盖；文件保留在私有暂存区：" + error.localizedDescription, retained: staged)
            try journal(store, runID, state: "needsReview", item: item, retained: staged, result: result)
            return result
        }
    }
    private func itemResult(_ item: MaintenanceItem, _ outcome: ItemOutcome, _ reason: String?, trash: String? = nil, retained: String? = nil) -> MaintenanceItemResult {
        MaintenanceItemResult(itemID: item.itemID, path: item.path, outcome: outcome, reason: reason, trashPath: trash, retainedPath: retained, estimatedBytes: item.estimatedBytes)
    }
    private func journal(_ store: EngineStore, _ runID: String, state: String, item: MaintenanceItem? = nil, retained: String? = nil, result: MaintenanceItemResult? = nil, accepted: MaintenanceResult? = nil) throws {
        var data = try MaintenanceJSON.encoder().encode(JournalEntry(state: state, itemID: item?.itemID, path: item?.path, retainedPath: retained, result: result, accepted: accepted))
        data.append(10)
        try store.writeData(data, "Journals/\(runID).ndjson", exclusive: false, append: true)
    }
    private func history(_ store: EngineStore) throws -> [MaintenanceResult] {
        var results: [MaintenanceResult] = []
        var damagedRuns: [String] = []
        for name in try store.names("History") where name.hasSuffix(".json") {
            do { results.append(try store.read(MaintenanceResult.self, "History/" + name)) }
            catch { damagedRuns.append(String(name.dropLast(5))) }
        }
        for name in try store.names("Consumed") where name.hasSuffix(".json") {
            let accepted = try store.read(MaintenanceResult.self, "Consumed/" + name)
            if results.contains(where: { $0.runID == accepted.runID }) { continue }
            var items = accepted.items
            if let data = try? store.readData("Journals/\(accepted.runID).ndjson") {
                for line in data.split(separator: 10) {
                    guard let entry = try? MaintenanceJSON.decoder().decode(JournalEntry.self, from: Data(line)), let id = entry.itemID, let index = items.firstIndex(where: { $0.itemID == id }) else { continue }
                    if let result = entry.result { items[index] = result }
                    else if let retained = entry.retainedPath { let old = items[index]; items[index] = MaintenanceItemResult(itemID: id, path: old.path, outcome: .unknown, reason: "事务中断，需核对原位与记录中的保留位置。", trashPath: nil, retainedPath: retained, estimatedBytes: old.estimatedBytes) }
                }
            }
            results.append(MaintenanceResult(planID: accepted.planID, runID: accepted.runID, title: accepted.title, status: .unknown, startedAt: accepted.startedAt, finishedAt: accepted.finishedAt, items: items, selectedBytes: accepted.selectedBytes, trashedBytes: items.filter { $0.outcome == .trashed }.reduce(0) { $0 + ($1.estimatedBytes ?? 0) }, freeBytesDelta: nil, message: "缺少最终事务记录，未自动重放；请核对各项目位置。"))
        }
        for runID in damagedRuns where !results.contains(where: { $0.runID == runID }) {
            let observed = Date()
            results.append(MaintenanceResult(planID: "unknown", runID: runID, title: "维护记录损坏", status: .unknown, startedAt: observed, finishedAt: observed, items: [], selectedBytes: 0, trashedBytes: 0, freeBytesDelta: nil, message: "此条最终记录无法读取，且没有可恢复的接受记录。显示时间为发现时间，请人工核对；其它历史不受影响。"))
        }
        return results.sorted { $0.startedAt > $1.startedAt }
    }
}
