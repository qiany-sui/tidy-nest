import Foundation
import Darwin
import TidyNestProtocol
import TidyNestEngine

private final class BridgeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32 = 0
    private var outputFailed = false
    private var eventCount = 0
    private var hasFinal = false
    func event(_ event: MaintenanceEvent) {
        lock.withLock { writeEvent(event) }
    }
    func query(_ data: Data) {
        lock.withLock {
            guard !outputFailed else { return }
            do {
                try FileHandle.standardOutput.write(contentsOf: data)
                try FileHandle.standardOutput.write(contentsOf: Data([10]))
            } catch { outputFailed = true }
        }
    }

    func earlyFailure(command: String, request: MaintenanceRequest?, message: String, cancelled: Bool) -> Bool {
        lock.withLock {
            guard ["scan-clean", "plan-uninstall", "apply-plan"].contains(command), eventCount == 0, !outputFailed else { return false }
            let runID = UUID().uuidString
            let result: MaintenanceResult?
            if command == "apply-plan", let planID = request?.planID, UUID(uuidString: planID) != nil {
                let now = Date()
                result = MaintenanceResult(planID: planID, runID: runID, title: "维护未执行", status: cancelled ? .cancelled : .blocked, startedAt: now, finishedAt: now, items: [], selectedBytes: 0, trashedBytes: 0, freeBytesDelta: nil, message: "维护尚未接受，未执行文件移动：" + message)
            } else { result = nil }
            writeEvent(MaintenanceEvent(schemaVersion: 1, runID: runID, sequence: 1, type: .result, message: nil, candidate: nil, itemResult: nil, plan: nil, applyResult: result, error: result == nil ? (cancelled ? "扫描已取消。" : message) : nil))
            return true
        }
    }

    private func writeEvent(_ event: MaintenanceEvent) {
        guard !hasFinal else { outputFailed = true; return }
        eventCount += 1
        hasFinal = event.type == .result
        if !outputFailed {
            do {
                var data = try MaintenanceJSON.encoder().encode(event); data.append(10)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch { outputFailed = true }
        }
        if event.type == .result {
            if event.error != nil { status = event.error == "扫描已取消。" ? 130 : 4 }
            if let result = event.applyResult {
                switch result.status {
                case .completed: status = 0
                case .partial: status = 2
                case .blocked: status = 3
                case .failed, .unknown: status = 4
                case .cancelled: status = 130
                }
            }
        }
    }
    var exitStatus: Int32 { lock.withLock { outputFailed ? 4 : status } }
    var didFailWriting: Bool { lock.withLock { outputFailed } }
}

private final class BridgeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let engineCancellation: EngineCancellation
    private var task: Task<Data?, any Error>?
    private var requested = false
    init(_ engineCancellation: EngineCancellation) { self.engineCancellation = engineCancellation }
    func cancel() {
        engineCancellation.cancel()
        let bound = lock.withLock { requested = true; return task }
        // Mole 查询有自己的进程组，Task 取消使 Core 回收该组。
        bound?.cancel()
    }
    func bind(_ task: Task<Data?, any Error>) {
        let alreadyRequested = lock.withLock { self.task = task; return requested }
        if alreadyRequested { task.cancel() }
    }
}

private final class BridgeSignals: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]
    init(cancellation: BridgeCancellation) {
        let queue = DispatchQueue(label: "TidyNestBridge.signals")
        sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { cancellation.cancel() }
            return source
        }
    }
    func register() async {
        await withCheckedContinuation { continuation in
            let readiness = SignalReadiness(remaining: sources.count, continuation: continuation)
            for source in sources {
                source.setRegistrationHandler { readiness.registered() }
                source.resume()
            }
        }
    }
    func cancel() { sources.forEach { $0.cancel() } }
}

private final class SignalReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private let continuation: CheckedContinuation<Void, Never>
    init(remaining: Int, continuation: CheckedContinuation<Void, Never>) {
        self.remaining = remaining
        self.continuation = continuation
    }
    func registered() {
        let ready = lock.withLock { remaining -= 1; return remaining == 0 }
        if ready { continuation.resume() }
    }
}

@main
struct TidyNestBridge {
    static func main() async {
        // dispatch source 的 resume 并不等于注册完成；就绪前保持默认处置，不能丢掉单次取消。
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        guard CommandLine.arguments.count == 2 else {
            fail("仅接受一个固定维护命令。", status: 3)
        }
        let command = CommandLine.arguments[1]
        let cancellation = EngineCancellation()
        let engine = MaintenanceEngine(cancellation: cancellation)
        let output = BridgeOutput()
        var request: MaintenanceRequest?
        do {
            var input = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
                input.append(chunk)
                guard input.count <= MaintenanceLimits.maximumRecordBytes else { throw MaintenanceProtocolError.invalidRequest }
            }
            if input.isEmpty { input = Data("{}".utf8) }
            let parsedRequest = try MaintenanceJSON.request(from: input, command: command)
            request = parsedRequest
            let taskCancellation = BridgeCancellation(cancellation)
            let signals = BridgeSignals(cancellation: taskCancellation)
            await signals.register()
            defer { signals.cancel() }
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let task = Task { try await engine.handle(command: command, request: parsedRequest, emit: { output.event($0) }) }
            taskCancellation.bind(task)
            if let data = try await task.value {
                output.query(data)
            }
            exit(output.exitStatus)
        } catch {
            if output.earlyFailure(command: command, request: request, message: error.localizedDescription, cancelled: cancellation.isCancelled) { exit(output.exitStatus) }
            fail(error.localizedDescription, status: output.didFailWriting ? 4 : (cancellation.isCancelled ? 130 : 4))
        }
    }
    private static func fail(_ message: String, status: Int32) -> Never {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
        exit(status)
    }
}
