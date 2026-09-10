import Foundation
import TidyNestProtocol

public enum MaintenanceError: Error, LocalizedError, Sendable {
    case busy
    case invalidResponse(String)
    case process(String)

    public var errorDescription: String? {
        switch self {
        case .busy: "已有维护任务正在运行，请先等待它结束。"
        case .invalidResponse(let reason): "维护引擎响应无效：\(MoleError.safeDiagnostic(reason))"
        case .process(let reason): MoleError.safeDiagnostic(reason)
        }
    }
}

public final class MaintenanceService: @unchecked Sendable {
    private let executableURL: URL
    private let lock = NSLock()
    private var active: BridgeProcessControl?

    public convenience init() {
        self.init(executableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TidyNestBridge"))
    }

    // 任意可执行路径仅供模块内隔离测试注入；界面只能使用随包固定的桥接程序。
    internal init(executableURL: URL) { self.executableURL = executableURL }

    public func capabilities() async throws -> EngineCapabilities {
        let value: EngineCapabilities = try await query("capabilities")
        guard value.schemaVersion == 1, !value.engineVersion.isEmpty, !value.engineDigest.isEmpty, !value.rulesVersion.isEmpty else {
            throw MaintenanceError.invalidResponse("不支持的能力协议版本或缺失引擎身份。")
        }
        return value
    }

    public func scanClean(onEvent: @escaping @Sendable (MaintenanceEvent) -> Void) async throws -> MaintenancePlan {
        try await scan(command: "scan-clean", request: MaintenanceRequest(), kind: .clean, onEvent: onEvent)
    }

    public func planUninstall(application: MoleApplication, onEvent: @escaping @Sendable (MaintenanceEvent) -> Void) async throws -> MaintenancePlan {
        try MaintenanceValidation.path(application.path)
        guard !application.bundleIdentifier.isEmpty else { throw MaintenanceError.invalidResponse("缺少应用标识。") }
        return try await scan(command: "plan-uninstall", request: MaintenanceRequest(appPath: application.path, expectedBundleID: application.bundleIdentifier), kind: .uninstall, onEvent: onEvent)
    }

    public func apply(planID: String, selectedItemIDs: [String], onEvent: @escaping @Sendable (MaintenanceEvent) -> Void) async throws -> MaintenanceResult {
        try Task.checkCancellation()
        guard !planID.isEmpty, !planID.contains("\0"), selectedItemIDs.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }), Set(selectedItemIDs).count == selectedItemIDs.count else {
            throw MaintenanceError.invalidResponse("计划或选择项目标识无效。")
        }
        let request = MaintenanceRequest(planID: planID, selectedItemIDs: selectedItemIDs, confirmed: true)
        let input: Data
        do { input = try Self.requestData(request) }
        catch {
            // 请求尚未发出，明确记为未执行，不能让用户误以为存在待核对的文件移动。
            let now = Date()
            let result = MaintenanceResult(planID: planID, runID: UUID().uuidString, title: "维护未执行", status: .blocked, startedAt: now, finishedAt: now, items: [], selectedBytes: 0, trashedBytes: 0, freeBytesDelta: nil, message: error.localizedDescription)
            onEvent(MaintenanceEvent(schemaVersion: 1, runID: result.runID, sequence: 1, type: .result, message: nil, candidate: nil, itemResult: nil, plan: nil, applyResult: result, error: nil))
            return result
        }
        let control = try begin()
        defer { end() }
        let started = Date()
        let stream = MaintenanceEventStream(onEvent: onEvent)
        var diagnostic = ""
        do {
            let output = try await BridgeProcessRunner().run(executableURL: executableURL, command: "apply-plan", input: input, control: control, onOutput: stream.consume)
            diagnostic = MoleError.safeDiagnostic(String(decoding: output.stderr, as: UTF8.self))
            let event = try stream.finish()
            guard let result = event.applyResult, result.planID == planID else {
                throw MaintenanceError.invalidResponse(event.error ?? "最终执行结果或计划标识不匹配。")
            }
            try MaintenanceValidation.result(result)
            let beforeAcceptance = (result.status == .blocked || result.status == .cancelled) && result.items.isEmpty
            guard Set(result.items.map(\.itemID)) == Set(selectedItemIDs) || beforeAcceptance else {
                throw MaintenanceError.invalidResponse("最终项目结果与已确认选择不一致。")
            }
            guard output.exitCode == MaintenanceValidation.exitCode(result.status) else {
                throw MaintenanceError.invalidResponse("退出码 \(output.exitCode) 与最终结果 \(result.status.rawValue) 不一致。")
            }
            onEvent(event)
            return result
        } catch {
            // apply 发出后任何通信中断都不能推测为未执行，也不能自动重试。
            let partial = stream.reportedResult
            let message = [error.localizedDescription, diagnostic].filter { !$0.isEmpty }.joined(separator: "\n")
            let result = MaintenanceResult(planID: planID, runID: stream.runID ?? UUID().uuidString, title: partial?.title ?? "维护结果待核对", status: .unknown, startedAt: partial?.startedAt ?? started, finishedAt: Date(), items: partial?.items ?? stream.itemResults, selectedBytes: partial?.selectedBytes ?? 0, trashedBytes: partial?.trashedBytes ?? 0, freeBytesDelta: nil, message: "结果待核对，请检查历史记录与保留位置，勿直接重试。\n" + MoleError.safeDiagnostic(message))
            onEvent(MaintenanceEvent(schemaVersion: 1, runID: result.runID, sequence: stream.nextSequence, type: .result, message: nil, candidate: nil, itemResult: nil, plan: nil, applyResult: result, error: nil))
            return result
        }
    }

    public func history() async throws -> [MaintenanceResult] {
        let results: [MaintenanceResult] = try await query("history")
        for result in results { try MaintenanceValidation.result(result) }
        guard Set(results.map(\.runID)).count == results.count else { throw MaintenanceError.invalidResponse("历史记录标识重复。") }
        return results
    }

    public func protections() async throws -> [String] {
        try await protectionQuery("protections", request: MaintenanceRequest())
    }

    public func protect(path: String) async throws {
        try MaintenanceValidation.path(path)
        _ = try await protectionQuery("protect-path", request: MaintenanceRequest(protectedPath: path))
    }

    public func unprotect(path: String) async throws {
        try MaintenanceValidation.path(path)
        _ = try await protectionQuery("unprotect-path", request: MaintenanceRequest(protectedPath: path))
    }

    public func forceEndCurrentTask() { lock.withLock { active?.force() } }

    private func begin() throws -> BridgeProcessControl {
        try lock.withLock {
            guard active == nil else { throw MaintenanceError.busy }
            let control = BridgeProcessControl()
            active = control
            return control
        }
    }

    private func end() { lock.withLock { active = nil } }

    private static func requestData(_ request: MaintenanceRequest) throws -> Data {
        let data = try MaintenanceJSON.encoder().encode(request)
        guard data.count <= MaintenanceLimits.maximumRecordBytes else {
            throw MaintenanceError.invalidResponse("维护请求超过 32 MiB 限制，尚未启动引擎。请减少选择项目后重试。")
        }
        return data
    }

    private func query<Value: Decodable & Sendable>(_ command: String, request: MaintenanceRequest = MaintenanceRequest()) async throws -> Value {
        let control = try begin()
        defer { end() }
        let buffer = MaintenanceQueryBuffer()
        let output = try await BridgeProcessRunner().run(executableURL: executableURL, command: command, input: Self.requestData(request), control: control, onOutput: buffer.consume)
        try Task.checkCancellation()
        guard output.exitCode == 0 else {
            throw MaintenanceError.process("维护查询失败（退出码 \(output.exitCode)）。" + MoleError.safeDiagnostic(String(decoding: output.stderr, as: UTF8.self)))
        }
        do { return try MaintenanceJSON.decoder().decode(Value.self, from: buffer.value()) }
        catch { throw MaintenanceError.invalidResponse("查询 JSON 无法完整解码。\(error.localizedDescription)") }
    }

    private func protectionQuery(_ command: String, request: MaintenanceRequest) async throws -> [String] {
        let paths: [String] = try await query(command, request: request)
        for path in paths { try MaintenanceValidation.path(path) }
        guard Set(paths).count == paths.count else { throw MaintenanceError.invalidResponse("保护路径重复。") }
        return paths
    }

    private func scan(command: String, request: MaintenanceRequest, kind: MaintenanceKind, onEvent: @escaping @Sendable (MaintenanceEvent) -> Void) async throws -> MaintenancePlan {
        let control = try begin()
        defer { end() }
        let stream = MaintenanceEventStream(onEvent: onEvent)
        let output = try await BridgeProcessRunner().run(executableURL: executableURL, command: command, input: Self.requestData(request), control: control, onOutput: stream.consume)
        try Task.checkCancellation()
        let event = try stream.finish()
        guard output.exitCode == 0, let plan = event.plan, plan.kind == kind else {
            throw MaintenanceError.invalidResponse(event.error ?? "扫描退出码或最终计划类型不匹配。")
        }
        try MaintenanceValidation.plan(plan)
        onEvent(event)
        return plan
    }
}

internal final class MaintenanceEventStream: @unchecked Sendable {
    private let lock = NSLock()
    private let onEvent: @Sendable (MaintenanceEvent) -> Void
    private var pending = Data()
    private var failure: MaintenanceError?
    private var identity: String?
    private var sequence = 0
    private var final: MaintenanceEvent?
    private var outcomes: [MaintenanceItemResult] = []
    init(onEvent: @escaping @Sendable (MaintenanceEvent) -> Void) { self.onEvent = onEvent }
    var runID: String? { lock.withLock { identity } }
    var nextSequence: Int { lock.withLock { sequence + 1 } }
    var reportedResult: MaintenanceResult? { lock.withLock { final?.applyResult } }
    var itemResults: [MaintenanceItemResult] { lock.withLock { outcomes } }

    func consume(_ data: Data) {
        let delivered: [MaintenanceEvent] = lock.withLock {
            guard failure == nil else { return [] }
            var events: [MaintenanceEvent] = []
            for byte in data {
                if byte == 10 {
                    do {
                        let event = try parseLine()
                        if event.type != .result { events.append(event) }
                    } catch {
                        failure = (error as? MaintenanceError) ?? .invalidResponse("NDJSON 事件不能解码。")
                        pending.removeAll()
                        break
                    }
                    pending.removeAll(keepingCapacity: true)
                } else {
                    if pending.count >= MaintenanceLimits.maximumRecordBytes {
                        failure = .invalidResponse("NDJSON 单行超过 32 MiB。")
                        pending.removeAll()
                        break
                    }
                    pending.append(byte)
                }
            }
            return events
        }
        for event in delivered { onEvent(event) }
    }

    func finish() throws -> MaintenanceEvent {
        if lock.withLock({ !pending.isEmpty && failure == nil }) { consume(Data([10])) }
        return try lock.withLock {
            if let failure { throw failure }
            guard let final else { throw MaintenanceError.invalidResponse("缺少最终 result 事件。") }
            return final
        }
    }

    private func parseLine() throws -> MaintenanceEvent {
        guard !pending.isEmpty, final == nil else { throw MaintenanceError.invalidResponse("出现空行、重复最终事件或最终事件后的输出。") }
        let event = try MaintenanceJSON.decoder().decode(MaintenanceEvent.self, from: pending)
        guard event.schemaVersion == 1, !event.runID.isEmpty, !event.runID.contains("\0"), event.sequence == sequence + 1, identity == nil || identity == event.runID else {
            throw MaintenanceError.invalidResponse("协议版本、runID 或事件序号不匹配。")
        }
        switch event.type {
        case .progress:
            guard event.message != nil, event.candidate == nil, event.itemResult == nil, event.plan == nil, event.applyResult == nil, event.error == nil else { throw MaintenanceError.invalidResponse("阶段事件内容冲突。") }
        case .candidate:
            guard let item = event.candidate, event.itemResult == nil, event.plan == nil, event.applyResult == nil, event.error == nil else { throw MaintenanceError.invalidResponse("候选事件内容冲突。") }
            try MaintenanceValidation.item(item)
        case .itemResult:
            guard let result = event.itemResult, event.candidate == nil, event.plan == nil, event.applyResult == nil, event.error == nil, !outcomes.contains(where: { $0.itemID == result.itemID }) else { throw MaintenanceError.invalidResponse("项目结果内容冲突或重复。") }
            try MaintenanceValidation.itemResult(result)
            outcomes.append(result)
        case .result:
            let payloadCount = [event.plan != nil, event.applyResult != nil, event.error != nil].filter { $0 }.count
            guard payloadCount == 1, event.candidate == nil, event.itemResult == nil else { throw MaintenanceError.invalidResponse("最终事件必须包含唯一结果。") }
            if let plan = event.plan {
                try MaintenanceValidation.plan(plan)
                guard plan.runID == event.runID else { throw MaintenanceError.invalidResponse("计划 runID 不匹配。") }
            }
            if let result = event.applyResult {
                try MaintenanceValidation.result(result)
                guard result.runID == event.runID else { throw MaintenanceError.invalidResponse("执行结果 runID 不匹配。") }
                for outcome in outcomes {
                    guard result.items.contains(outcome) else { throw MaintenanceError.invalidResponse("最终结果与已收到项目结果不一致。") }
                }
            }
            final = event
        }
        identity = event.runID
        sequence = event.sequence
        return event
    }
}

private final class MaintenanceQueryBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var oversized = false
    func consume(_ chunk: Data) {
        lock.withLock {
            guard !oversized else { return }
            if data.count + chunk.count > MaintenanceLimits.maximumRecordBytes { oversized = true; data.removeAll() }
            else { data.append(chunk) }
        }
    }
    func value() throws -> Data {
        try lock.withLock {
            guard !oversized else { throw MaintenanceError.invalidResponse("查询输出超过 32 MiB。") }
            return data
        }
    }
}

private enum MaintenanceValidation {
    static func path(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw MaintenanceError.invalidResponse("包含非绝对路径或无效路径组件。") }
    }
    static func item(_ item: MaintenanceItem) throws {
        try path(item.path)
        guard !item.itemID.isEmpty, !item.ruleID.isEmpty else { throw MaintenanceError.invalidResponse("项目标识缺失。") }
        if item.requiresAuthorization == true {
            guard item.kind == .application, item.selection == .required, item.blockedReason == nil else { throw MaintenanceError.invalidResponse("系统授权标识只能用于可移除的应用本体。") }
        }
    }
    static func itemResult(_ result: MaintenanceItemResult) throws {
        try path(result.path)
        if let value = result.trashPath { try path(value) }
        if let value = result.retainedPath { try path(value) }
        guard !result.itemID.isEmpty, result.outcome != .trashed || result.trashPath != nil else { throw MaintenanceError.invalidResponse("项目结果标识或移入废纸篓的路径证据缺失。") }
    }
    static func plan(_ plan: MaintenancePlan) throws {
        guard plan.schemaVersion == 1, !plan.planID.isEmpty, !plan.runID.isEmpty, !plan.engineDigest.isEmpty, Set(plan.items.map(\.itemID)).count == plan.items.count else { throw MaintenanceError.invalidResponse("计划版本、身份或项目标识无效。") }
        for root in plan.scopeRoots { try path(root) }
        for issue in plan.scanIssues { try path(issue.path) }
        for item in plan.items { try self.item(item) }
    }
    static func result(_ result: MaintenanceResult) throws {
        guard !result.planID.isEmpty, !result.runID.isEmpty, result.finishedAt >= result.startedAt, result.trashedBytes <= result.selectedBytes, Set(result.items.map(\.itemID)).count == result.items.count else { throw MaintenanceError.invalidResponse("执行结果身份、时间或容量无效。") }
        for item in result.items { try itemResult(item) }
        let trashedCount = result.items.filter { $0.outcome == .trashed }.count
        let consistent = switch result.status {
        case .completed: !result.items.isEmpty && trashedCount == result.items.count
        case .partial: trashedCount > 0 && trashedCount < result.items.count
        case .failed, .blocked: trashedCount == 0
        case .cancelled, .unknown: true
        }
        guard consistent else { throw MaintenanceError.invalidResponse("执行状态与逐项结果不一致。") }
    }
    static func exitCode(_ status: MaintenanceStatus) -> Int32 {
        switch status {
        case .completed: 0
        case .partial: 2
        case .blocked: 3
        case .failed, .unknown: 4
        case .cancelled: 130
        }
    }
}
