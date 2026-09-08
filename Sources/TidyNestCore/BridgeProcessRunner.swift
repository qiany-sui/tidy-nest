import Foundation
import Darwin

internal struct BridgeProcessOutput: Sendable {
    let exitCode: Int32
    let stderr: Data
}

// 取消只要求引擎收尾；只有用户明确强制结束才允许升级信号。
internal final class BridgeProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var forced = false
    var state: (cancelled: Bool, forced: Bool) { lock.withLock { (cancelled, forced) } }
    func cancel() { lock.withLock { cancelled = true } }
    func force() { lock.withLock { forced = true } }
}

internal struct BridgeProcessRunner: Sendable {
    func run(executableURL: URL, command: String, input: Data, control: BridgeProcessControl, onOutput: @escaping @Sendable (Data) -> Void) async throws -> BridgeProcessOutput {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try execute(executableURL: executableURL, command: command, input: input, control: control, onOutput: onOutput) })
                }
            }
        } onCancel: { control.cancel() }
    }

    private func execute(executableURL: URL, command: String, input: Data, control: BridgeProcessControl, onOutput: @escaping @Sendable (Data) -> Void) throws -> BridgeProcessOutput {
        if control.state.cancelled { throw CancellationError() }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        defer {
            for pipe in [stdin, stdout, stderr] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        let pid = try spawn(executableURL: executableURL, command: command, stdin: stdin, stdout: stdout, stderr: stderr)
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let workers = DispatchGroup()
        let state = BridgePipeState()
        // 短命或拒绝请求的子进程可能先关闭 stdin，不能让 SIGPIPE 杀掉 App。
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        workers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { workers.leave(); try? stdin.fileHandleForWriting.close() }
            do { try stdin.fileHandleForWriting.write(contentsOf: input) }
            catch { state.fail("无法完整写入维护请求。") }
        }
        for (pipe, isStdout) in [(stdout, true), (stderr, false)] {
            workers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { workers.leave(); try? pipe.fileHandleForReading.close() }
                var buffer = [UInt8](repeating: 0, count: 16_384)
                while true {
                    // Foundation 的定长读取可能等到满块或 EOF；单次 read 才能及时交付短进度事件。
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(pipe.fileHandleForReading.fileDescriptor, $0.baseAddress!, $0.count)
                    }
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        state.fail("无法完整读取维护引擎输出。")
                        break
                    }
                    let data = Data(buffer.prefix(count))
                    if isStdout { onOutput(data) } else { state.appendDiagnostic(data) }
                }
            }
        }
        var sentInterrupt = false
        var terminationAt: TimeInterval?
        var sentKill = false
        var ownsChild = true
        var waitError: MaintenanceError?
        while true {
            var info = siginfo_t()
            // 不回收 PID，直到最后一次组信号之后；即使主进程退出，持管道子进程仍属本次组。
            let waited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if waited == -1 {
                if errno == EINTR { continue }
                if errno == ECHILD { ownsChild = false }
                waitError = .process("无法确认维护进程的归属或退出状态。")
                break
            }
            if info.si_pid == pid && workers.wait(timeout: .now()) == .success { break }
            let flags = control.state
            let now = ProcessInfo.processInfo.systemUptime
            if flags.forced && terminationAt == nil {
                _ = kill(-pid, SIGTERM)
                terminationAt = now
            } else if flags.cancelled && !sentInterrupt && terminationAt == nil {
                _ = kill(-pid, SIGINT)
                sentInterrupt = true
            }
            if let terminationAt, !sentKill, now - terminationAt >= 5 {
                _ = kill(-pid, SIGKILL)
                sentKill = true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // ECHILD 时不发送任何信号；归属已不可信，尤其不能冒险命中复用的 PID。
        guard ownsChild else { throw waitError ?? MaintenanceError.process("维护进程归属已丢失。") }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno == EINTR { continue }
            throw MaintenanceError.process("无法回收维护进程。")
        }
        workers.wait()
        if let waitError { throw waitError }
        if let error = state.error { throw MaintenanceError.process(error) }
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return BridgeProcessOutput(exitCode: exitCode, stderr: state.diagnostic)
    }

    private func spawn(executableURL: URL, command: String, stdin: Pipe, stdout: Pipe, stderr: Pipe) throws -> pid_t {
        guard executableURL.isFileURL, !executableURL.path.contains("\0"), !command.contains("\0") else {
            throw MaintenanceError.process("无效的维护引擎路径或命令。")
        }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        // 工作线程可能屏蔽信号；子进程必须能收到合作取消，不能继承调用线程的屏蔽状态。
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGTERM)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, STDIN_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "MO_ANALYZE_PATH")
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let argumentStrings: [String] = [executableURL.path, command]
        let argv = argumentStrings.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { arguments in
            envp.withUnsafeBufferPointer { environment in
                posix_spawn(&pid, executableURL.path, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
            }
        }
        try check(result)
        return pid
    }

    private func check(_ code: Int32) throws {
        guard code == 0 else { throw MaintenanceError.process("无法启动维护引擎：\(String(cString: strerror(code)))") }
    }
}

private final class BridgePipeState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDiagnostic = Data()
    private var storedError: String?
    var diagnostic: Data { lock.withLock { storedDiagnostic } }
    var error: String? { lock.withLock { storedError } }
    func fail(_ message: String) { lock.withLock { storedError = storedError ?? message } }
    func appendDiagnostic(_ data: Data) {
        lock.withLock { storedDiagnostic.append(data.prefix(max(0, 65_536 - storedDiagnostic.count))) }
    }
}
