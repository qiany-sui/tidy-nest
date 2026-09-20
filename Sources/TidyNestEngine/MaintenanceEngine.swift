import Foundation
import Darwin
import TidyNestProtocol

private struct CatalogRecord: Codable, Equatable, Sendable {
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
    let containerOwners: [String: ContainerOwnership]
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
    private func catalogChangeReason(expected: [CatalogRecord], current: [CatalogRecord]) -> String {
        let before = Dictionary(grouping: expected, by: { $0.app.path })
        let after = Dictionary(grouping: current, by: { $0.app.path })
        let changedPaths = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
        let paths = changedPaths.prefix(3).joined(separator: "、")
        let remainder = changedPaths.count > 3 ? "（另有 \(changedPaths.count - 3) 项）" : ""
        return "执行期间安装集合或应用身份发生变化，已停止后续处理，未处理项目保留。变化应用：" + paths + remainder + "。请核对已处理结果，重新检查后再操作。"
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
        var containerOwners: [String: ContainerOwnership] = [:]
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
                    ?? "应用仍然存在，但标识与应用列表不一致。请先刷新此应用，再重新检查。"
                complete = false; issues.append(PlanIssue(path: path, reason: reason))
                selectedApps = []
                return finishPlan()
            }
            selectedApps = [app]
        }
        for (index, app) in selectedApps.enumerated() {
            try checkCancelled()
            stream.send(.progress, message: "正在检查 \(app.name)（\(index + 1)/\(selectedApps.count) 个应用）")
            let hasUniqueOwner = groups[app.bundleID.lowercased()]?.count == 1
            let bodyOnly = !hasUniqueOwner || app.bundleID.lowercased() == EngineRules.xcodeBundleID
            var block: String?
            var requiresAuthorization = false
            // 应用本体由精确路径和完整快照定位；共享缓存与日志仍要求唯一归属。
            if !uninstall && !hasUniqueOwner { block = "bundle ID 安装归属不唯一，共享缓存与日志已保留。" }
            if !validBundle(app.bundleID) { block = app.unsupportedReason ?? "bundle ID 不完整，不授权维护动作。" }
            if !context.appRoots.contains(where: { pathInside(app.path, $0) && app.path != $0 }) || !app.path.hasSuffix(".app") { block = "应用不在首批普通应用安装范围。" }
            block = block ?? rules.appBlock(app, clean: !uninstall)
            if configuration.protections.contains(where: { protectionContains(app.path, $0) || protectionContains($0, app.path) }) { block = "用户长期保护的应用。" }
            if block == nil {
                do {
                    guard try bundleID(at: app.path) == app.bundleID else { throw EngineFailure("应用标识已变化。") }
                    _ = try DirectoryFD(path: app.path)
                    if uninstall {
                        do { try verifyApplicationMovePermissions(app.path) }
                        catch let error as ApplicationMovePermissionError where error.code == EACCES && context.authorizedTrash != nil && context.authorizedTrashRoot != nil {
                            // 系统授权只补足普通权限，运行状态、保护规则和完整快照仍须通过。
                            requiresAuthorization = true
                        }
                    }
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
                let item = MaintenanceItem(itemID: id, ruleID: EngineRules.ids[2], path: app.path, displayName: app.name, kind: .application, action: .trashItem, estimatedBytes: snapshot?.bytes, reason: app.isWrapped ? "移除选定的 iPhone/iPad 包装应用本体（整个外层应用包）" : "移除选定的普通应用本体", impact: bodyOnly ? "只移除当前路径的应用本体，缓存与日志保留；可从废纸篓手动恢复。" : (app.isWrapped ? "应用将无法启动，可从废纸篓手动恢复。文稿、存档、偏好设置及共享容器保留；缓存与日志单独选择。" : "应用将无法启动，可从废纸篓手动恢复。相关缓存与日志单独选择。"), selection: block == nil ? .required : .blocked, blockedReason: block, dependsOnItemIDs: [], requiresAuthorization: block == nil && requiresAuthorization ? true : nil)
                items.append(item); owners[id] = app
                if let snapshot { snapshots[id] = snapshot }
            }
            if let block { issues.append(PlanIssue(path: app.path, reason: block)); continue }
            if uninstall && bodyOnly {
                let reason = hasUniqueOwner
                    ? "当前仅支持移除 Xcode 应用本体，缓存与日志保留。"
                    : "检测到多个使用相同 Bundle ID 的应用。本计划仅移除所选路径的应用本体，共享缓存与日志已保留。"
                issues.append(PlanIssue(path: app.path, reason: reason))
                continue
            }
            for (folder, rule) in [("Caches", EngineRules.ids[0]), ("Logs", EngineRules.ids[1])] {
                let root = context.home + "/Library/" + folder + "/" + app.bundleID
                if try existingIdentity(root) == nil { continue }
                do { try enumerate(root, app: app, rule: rule, dependencies: appItemID.map { [$0] } ?? []) }
                catch { complete = false; issues.append(PlanIssue(path: root, reason: "枚举不完整：" + error.localizedDescription)) }
            }
            if app.isWrapped {
                let container: ContainerOwnership?
                do { container = try ContainerOwnership.discover(home: context.home, bundleID: app.bundleID, checkCancelled: checkCancelled) }
                catch {
                    if error is CancellationError { throw error }
                    // 容器尚未获授权时保留全部容器数据，不阻止已独立核验的应用本体。
                    issues.append(PlanIssue(path: context.home + "/Library/Containers", reason: "容器缓存与日志已保留：" + error.localizedDescription))
                    continue
                }
                guard let container else {
                    issues.append(PlanIssue(path: context.home + "/Library/Containers", reason: "未找到可确认归属的应用容器，容器数据保留；文稿、存档和共享容器不在处理范围。"))
                    continue
                }
                containerOwners[app.path] = container
                for (folder, rule) in [("Caches", EngineRules.ids[3]), ("Logs", EngineRules.ids[4])] {
                    let root = container.path + "/Data/Library/" + folder
                    do {
                        if try existingIdentity(root) == nil { continue }
                        try enumerate(root, app: app, rule: rule, dependencies: appItemID.map { [$0] } ?? [])
                    } catch {
                        if error is CancellationError { throw error }
                        complete = false; issues.append(PlanIssue(path: root, reason: "容器缓存或日志枚举不完整：" + error.localizedDescription))
                    }
                }
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
            for owner in containerOwners.values { try owner.verifyUnique(home: context.home, checkCancelled: checkCancelled) }
        } catch {
            if error is CancellationError { throw error }
            complete = false; issues.append(PlanIssue(path: context.home, reason: error.localizedDescription))
        }
        try checkCancelled()
        return finishPlan()

        func finishPlan() -> SavedPlan {
            let plan = MaintenancePlan(schemaVersion: 1, planID: UUID().uuidString, runID: stream.runID, kind: uninstall ? .uninstall : .clean, title: uninstall ? "移除应用计划" : "缓存与日志清理计划", engineVersion: EngineRules.engineVersion, engineDigest: engineDigest, rulesVersion: EngineRules.version, configurationDigest: configuration.digest, createdAt: Date(), scopeRoots: (uninstall ? selectedApps.map(\.path) : [context.home + "/Library/Caches", context.home + "/Library/Logs"]) + containerOwners.values.flatMap { [$0.path + "/Data/Library/Caches", $0.path + "/Data/Library/Logs"] }.sorted(), scanComplete: complete, scanIssues: issues, items: items)
            return SavedPlan(plan: plan, snapshots: snapshots, owners: owners, catalogDigest: fingerprint, catalogRecords: catalogRecords, containerOwners: containerOwners)
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
                    let isSQLite = Data(bytes.prefix(max(0, count))).starts(with: Data("SQLite format 3".utf8))
                    guard snapshot.matches(try ObjectSnapshot.capture(path, application: false)) else { throw EngineFailure("扫描期间文件发生变化。") }
                    let id = UUID().uuidString
                    let item = MaintenanceItem(itemID: id, ruleID: rule, path: path, displayName: name, kind: .file, action: .trashItem, estimatedBytes: snapshot.bytes, reason: "\([EngineRules.ids[3], EngineRules.ids[4]].contains(rule) ? "容器元数据确认归属" : "精确匹配") \(app.bundleID) 的普通\([EngineRules.ids[0], EngineRules.ids[3]].contains(rule) ? "缓存" : "日志")文件", impact: rules.fileImpact(path, isSQLite: isSQLite), selection: .optional, blockedReason: nil, dependsOnItemIDs: dependencies)
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
            if item.requiresAuthorization == true {
                guard item.kind == .application, plan.kind == .uninstall, context.authorizedTrash != nil, context.authorizedTrashRoot != nil else { throw EngineFailure("系统授权仅用于已确认的应用本体，当前环境不支持此计划。") }
            }
            guard saved.catalogRecords.contains(where: { $0.app == owner }) else { throw EngineFailure("项目归属未绑定到计划中的安装集合。") }
            if item.kind == .application {
                guard plan.kind == .uninstall, item.selection == .required, item.ruleID == EngineRules.ids[2], item.path == owner.path, context.appRoots.contains(where: { pathInside(item.path, $0) && item.path != $0 }), item.path.hasSuffix(".app"), item.dependsOnItemIDs.isEmpty else { throw EngineFailure("应用计划范围不合法。") }
            } else {
                guard item.selection == .optional, [EngineRules.ids[0], EngineRules.ids[1], EngineRules.ids[3], EngineRules.ids[4]].contains(item.ruleID), validBundle(owner.bundleID) else { throw EngineFailure("文件规则不合法。") }
                guard saved.catalogRecords.filter({ $0.app.bundleID.lowercased() == owner.bundleID.lowercased() }).count == 1,
                      owner.bundleID.lowercased() != EngineRules.xcodeBundleID else { throw EngineFailure("共享缓存与日志或 Xcode 开发数据不在此计划的处理范围。") }
                let folder = [EngineRules.ids[0], EngineRules.ids[3]].contains(item.ruleID) ? "Caches" : "Logs"
                let root: String
                if [EngineRules.ids[3], EngineRules.ids[4]].contains(item.ruleID) {
                    guard owner.isWrapped, let container = saved.containerOwners[owner.path], container.bundleID == owner.bundleID,
                          URL(fileURLWithPath: try canonicalPath(container.path)).deletingLastPathComponent().path == context.home + "/Library/Containers" else { throw EngineFailure("容器文件没有已确认的包装应用归属。") }
                    root = container.path + "/Data/Library/" + folder
                } else { root = context.home + "/Library/" + folder + "/" + owner.bundleID }
                guard pathInside(item.path, root), item.path != root, rules.fileBlock(item.path, configuration: configuration) == nil else { throw EngineFailure("文件不在计划授权范围或已受保护。") }
                if plan.kind == .uninstall {
                    guard item.dependsOnItemIDs.count == 1, plan.items.contains(where: { $0.itemID == item.dependsOnItemIDs[0] && $0.kind == .application && $0.path == owner.path }) else { throw EngineFailure("残留缺少应用本体依赖。") }
                } else if !item.dependsOnItemIDs.isEmpty { throw EngineFailure("清理计划包含非法依赖。") }
            }
            guard rules.appBlock(owner, clean: plan.kind == .clean) == nil else { throw EngineFailure("应用受到固定规则保护。") }
        }
        try checkCancelled()
        guard try await catalogDigest(context.catalog()) == saved.catalogDigest else { throw EngineFailure("安装集合或应用标识已变化，请重新生成计划。") }
        let selectedContainerApps = Set(items.filter { [EngineRules.ids[3], EngineRules.ids[4]].contains($0.ruleID) }.compactMap { saved.owners[$0.itemID]?.path })
        for appPath in selectedContainerApps {
            try saved.containerOwners[appPath]!.verifyUnique(home: context.home, checkCancelled: checkCancelled)
        }
        let started = Date(); let selectedBytes = items.reduce(UInt64(0)) { $0 + ($1.estimatedBytes ?? 0) }
        let accepted = MaintenanceResult(planID: planID, runID: stream.runID, title: plan.title, status: .unknown, startedAt: started, finishedAt: started, items: items.map { MaintenanceItemResult(itemID: $0.itemID, path: $0.path, outcome: .unknown, reason: "执行已接受，缺少最终记录时需核对。", trashPath: nil, retainedPath: $0.path, estimatedBytes: $0.estimatedBytes) }, selectedBytes: selectedBytes, trashedBytes: 0, freeBytesDelta: nil, message: "事务尚未完成。")
        progress.accepted = accepted
        try store.write(accepted, "Consumed/\(planID).json")
        try journal(store, stream.runID, state: "accepted", accepted: accepted)
        var results: [MaintenanceItemResult] = []
        var cancellationObserved = false
        var catalogInvalidationReason: String?
        for item in items {
            if cancellation.isCancelled || Task.isCancelled { cancellationObserved = true }
            let result: MaintenanceItemResult
            if cancellationObserved {
                result = itemResult(item, .cancelled, "已取消后续项目，当前文件保留。", retained: item.path)
            } else if catalogInvalidationReason != nil {
                result = itemResult(item, .skipped, "安装集合复核未通过，本次计划已停止；此项未执行，原位置保留。", retained: item.path)
            } else if item.dependsOnItemIDs.contains(where: { id in !results.contains(where: { $0.itemID == id && $0.outcome == .trashed }) }) {
                result = itemResult(item, .skipped, "应用本体未确定移入废纸篓，相关残留全部保留。", retained: item.path)
            } else {
                stream.send(.progress, message: "再次检查：" + item.displayName)
                do {
                    let currentConfiguration = try rules.configuration(context: context, protections: protections(store))
                    guard currentConfiguration.digest == plan.configurationDigest else { throw EngineFailure("执行期间保护配置发生变化，当前及后续目标保留，请重新扫描。") }
                    let removedBodies = Set(results.filter { result in result.outcome == .trashed && plan.items.contains { $0.itemID == result.itemID && $0.kind == .application } }.map(\.path))
                    let expectedRecords = saved.catalogRecords.filter { !removedBodies.contains($0.app.path) }
                    let currentRecords: [CatalogRecord]
                    do {
                        currentRecords = try await captureCatalog(context.catalog())
                    } catch {
                        if error is CancellationError { throw error }
                        let reason = "执行期间无法完整复核安装集合，已停止后续处理，未处理项目保留。" + error.localizedDescription
                        catalogInvalidationReason = reason
                        throw EngineFailure(reason)
                    }
                    guard digest(try MaintenanceJSON.encoder().encode(currentRecords)) == digest(try MaintenanceJSON.encoder().encode(expectedRecords)) else {
                        // 整批授权依据已失效，后续只记录保留结果，不重复扫描或尝试移除。
                        let reason = catalogChangeReason(expected: expectedRecords, current: currentRecords)
                        catalogInvalidationReason = reason
                        throw EngineFailure(reason)
                    }
                    var owner = saved.owners[item.itemID]!
                    if let body = results.first(where: { item.dependsOnItemIDs.contains($0.itemID) && $0.outcome == .trashed }), let trashPath = body.trashPath {
                        owner.originalPath = owner.path
                        owner.path = trashPath
                    }
                    let container = [EngineRules.ids[3], EngineRules.ids[4]].contains(item.ruleID) ? saved.containerOwners[saved.owners[item.itemID]!.path] : nil
                    try await context.runtime(owner, item.path)
                    if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
                    if item.requiresAuthorization == true {
                        stream.send(.progress, message: "正在交给 Finder 移除 " + item.displayName + "；请在系统窗口完成授权或取消。")
                        result = try await moveWithSystemAuthorization(item, snapshot: saved.snapshots[item.itemID]!, store: store, runID: stream.runID)
                    } else {
                        result = try move(item, snapshot: saved.snapshots[item.itemID]!, container: container, store: store, runID: stream.runID)
                    }
                } catch {
                    if error is CancellationError { cancellationObserved = true }
                    result = itemResult(item, error is CancellationError ? .cancelled : .failed, error.localizedDescription, retained: item.path)
                }
            }
            if result.outcome == .cancelled { cancellationObserved = true }
            results.append(result)
            progress.items = results
            try journal(store, stream.runID, state: "itemResult", item: item, result: result)
            stream.send(.itemResult, itemResult: result)
        }
        let successful = results.filter { $0.outcome == .trashed }
        let status: MaintenanceStatus = results.contains(where: { $0.outcome == .unknown }) ? .unknown : (successful.count == items.count ? .completed : (!successful.isEmpty ? .partial : (cancellationObserved ? .cancelled : .failed)))
        let result = MaintenanceResult(planID: planID, runID: stream.runID, title: plan.title, status: status, startedAt: started, finishedAt: Date(), items: results, selectedBytes: selectedBytes, trashedBytes: successful.reduce(0) { $0 + ($1.estimatedBytes ?? 0) }, freeBytesDelta: nil, message: (catalogInvalidationReason.map { $0 + "\n" } ?? "") + "移入废纸篓不会立即释放对应空间；未自动清空废纸篓。")
        try store.write(result, "History/\(stream.runID).json")
        try journal(store, stream.runID, state: "finished")
        return result
    }

    private func moveWithSystemAuthorization(_ item: MaintenanceItem, snapshot: ObjectSnapshot, store: EngineStore, runID: String) async throws -> MaintenanceItemResult {
        guard item.kind == .application, let operation = context.authorizedTrash, let trashRoot = context.authorizedTrashRoot else { throw EngineFailure("当前环境不能请求系统授权。") }
        _ = try canonicalPath(trashRoot)
        guard snapshot.matches(try ObjectSnapshot.capture(item.path, application: true)) else { throw EngineFailure("应用或父目录发生变化，请重新检查。") }
        guard snapshot.members.first?.identity.device == (try identity(at: store.root)).device else { throw EngineFailure("应用与本用户维护目录不在同一卷，已保留。") }
        try checkCancelled()
        // 授权和移动由 Finder 完成；交接后任何通信不确定都不能当作“尚未执行”重试。
        try journal(store, runID, state: "systemTrashIntent", item: item, retained: item.path)
        var returnedPath: String?
        do {
            let destination = try await operation(URL(fileURLWithPath: item.path), snapshot)
            returnedPath = destination.path
            let normalizedDestination = try canonicalPath(destination.path)
            let isExpectedTrash = destination.isFileURL && pathInside(normalizedDestination, trashRoot) && normalizedDestination != trashRoot
            guard isExpectedTrash, try existingIdentity(item.path) == nil,
                  snapshot.matches(try ObjectSnapshot.captureFinalLocation(destination.path, application: true), moved: true) else {
                throw SystemTrashError.uncertain("系统返回的位置或应用身份未通过复核。")
            }
            let result = itemResult(item, .trashed, "已由 Finder 完成系统移除并核验应用身份。", trash: destination.path)
            try journal(store, runID, state: "succeeded", item: item, result: result)
            return result
        } catch {
            let unchanged = (try? ObjectSnapshot.capture(item.path, application: true)).map { snapshot.matches($0) } ?? false
            let outcome: ItemOutcome
            switch error {
            case SystemTrashError.cancelled, SystemTrashError.denied, is CancellationError:
                outcome = unchanged && returnedPath == nil ? .cancelled : .unknown
            case SystemTrashError.uncertain:
                outcome = .unknown
            default:
                outcome = unchanged && returnedPath == nil ? .failed : .unknown
            }
            let result = itemResult(item, outcome, error.localizedDescription, trash: returnedPath, retained: FileManager.default.fileExists(atPath: item.path) ? item.path : nil)
            try? journal(store, runID, state: outcome == .unknown ? "needsReview" : "systemTrashStopped", item: item, retained: result.retainedPath, result: result)
            return result
        }
    }

    private func move(_ item: MaintenanceItem, snapshot: ObjectSnapshot, container: ContainerOwnership?, store: EngineStore, runID: String) throws -> MaintenanceItemResult {
        guard snapshot.matches(try ObjectSnapshot.capture(item.path, application: item.kind == .application)) else { throw EngineFailure("目标、父目录或应用成员已变化，请重新生成计划。") }
        let sourceURL = URL(fileURLWithPath: item.path)
        let source = try DirectoryFD(path: sourceURL.deletingLastPathComponent().path)
        guard source.identities.count == snapshot.parents.count, zip(source.identities, snapshot.parents).allSatisfy({ $0.sameDirectory($1) }) else { throw EngineFailure("父目录身份已变化。") }
        if item.kind == .application { try verifyApplicationMovePermissions(item.path) }
        let runDirectory = store.root + "/Transactions/" + runID
        try EngineStore.privateDirectory(runDirectory)
        let itemDirectory = runDirectory + "/" + item.itemID
        try EngineStore.privateDirectory(itemDirectory)
        let destination = try DirectoryFD(path: itemDirectory)
        let staged = itemDirectory + "/" + sourceURL.lastPathComponent
        guard snapshot.members.first?.identity.device == destination.identities.last?.device else { throw EngineFailure("目标与私有暂存目录不在同一卷，已保留。") }
        try journal(store, runID, state: "moveIntent", item: item, retained: staged)
        try context.hook(.beforeMove, item.path, staged)
        try container?.verifyUnique(home: context.home, checkCancelled: checkCancelled)
        // macOS 没有以源 inode 为条件的 rename；移后复验只能检测可观察到的竞争变化。
        guard renameatx_np(source.fd, sourceURL.lastPathComponent, destination.fd, sourceURL.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            let reason: String
            switch code {
            case EACCES:
                reason = "当前账户没有移动此项目的权限，源文件保留。请在 Finder 中核对权限，或按系统提示授权移除。"
            case EPERM:
                reason = "系统拒绝移动此项目，源文件保留。可能受系统保护或应用管理权限限制，请在 Finder 中核对。"
            case EEXIST:
                reason = "暂存位置已存在同名项目，未覆盖；源文件保留。请重新检查后重试。"
            default:
                reason = "无法移入暂存区，移动未完成。请重新检查。"
            }
            throw EngineFailure("\(reason)（系统错误 \(code)：\(String(cString: strerror(code)))）")
        }
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
            // 已暂存的当前项完成复核与记账；正常取消只停止后续项。
            try container?.verifyUnique(home: context.home, checkCancelled: {})
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
