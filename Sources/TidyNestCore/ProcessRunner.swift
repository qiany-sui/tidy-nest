import Foundation
import Darwin

internal struct ProcessOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

internal struct ProcessRunner: Sendable {
    func run(executableURL: URL, arguments: [String], timeout: TimeInterval, allowedExitCodes: Set<Int32> = [0]) async throws -> ProcessOutput {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try execute(executableURL: executableURL, arguments: arguments, timeout: timeout, allowedExitCodes: allowedExitCodes, cancellation: cancellation) })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func execute(executableURL: URL, arguments: [String], timeout: TimeInterval, allowedExitCodes: Set<Int32>, cancellation: CancellationFlag) throws -> ProcessOutput {
        if cancellation.isCancelled { throw CancellationError() }
        guard !([executableURL.path] + arguments).contains(where: { $0.contains("\0") }) else {
            throw MoleError.launchFailed("参数包含无效字符。")
        }
        let stdout = Pipe()
        let stderr = Pipe()
        let pid = try spawn(executableURL: executableURL, arguments: arguments, stdout: stdout, stderr: stderr)
        // 父进程不保留写端，否则即使任务已经结束，读端仍等不到 EOF。
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let readers = DispatchGroup()
        let out = PipeResult()
        let err = PipeResult()
        for (pipe, result) in [(stdout, out), (stderr, err)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave(); try? pipe.fileHandleForReading.close() }
                result.set(Result { try pipe.fileHandleForReading.readToEnd() ?? Data() })
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stopped: (any Error)?
        var exited = false
        var ownsChild = true
        while !exited || readers.wait(timeout: .now()) == .timedOut {
            // WNOWAIT 保留本次子进程的 PID；最后一次组信号之前绝不回收，避免 PID 复用。
            var info = siginfo_t()
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if result == -1 {
                if errno == EINTR { continue }
                if errno == ECHILD { ownsChild = false }
                stopped = MoleError.outputFailed
                break
            }
            exited = info.si_pid == pid
            if cancellation.isCancelled { stopped = CancellationError(); break }
            if ProcessInfo.processInfo.systemUptime >= deadline { stopped = MoleError.timedOut; break }
            if !exited || readers.wait(timeout: .now()) == .timedOut { Thread.sleep(forTimeInterval: 0.01) }
        }
        if cancellation.isCancelled && stopped == nil { stopped = CancellationError() }
        if stopped != nil && ownsChild {
            // pgid 在 spawn 时显式设为本次 PID，而且尚未 reap，只终止本任务的进程组。
            _ = kill(-pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.15)
            _ = kill(-pid, SIGKILL)
        }
        var status: Int32 = 0
        if ownsChild {
            while waitpid(pid, &status, 0) == -1 {
                if errno == EINTR { continue }
                stopped = stopped ?? MoleError.outputFailed
                break
            }
        }
        // ECHILD 表示归属丢失，不能再发送组信号。此时返回错误，而不是无限等待管道。
        if !ownsChild { throw stopped ?? MoleError.outputFailed }
        readers.wait()
        if let stopped { throw stopped }
        if cancellation.isCancelled { throw CancellationError() }
        guard let stdoutData = out.value, let stderrData = err.value else { throw MoleError.outputFailed }
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        guard allowedExitCodes.contains(exitCode) else {
            throw MoleError.processFailed(exitCode, MoleError.safeDiagnostic(String(decoding: stderrData, as: UTF8.self)))
        }
        return ProcessOutput(stdout: stdoutData, stderr: stderrData, exitCode: exitCode)
    }

    private func spawn(executableURL: URL, arguments: [String], stdout: Pipe, stderr: Pipe) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO))

        // Finder 不继承交互式 shell 的 PATH；使用已知工具目录，不加载 shell 启动文件。
        var environment = ProcessInfo.processInfo.environment
        // 此变量在 Mole 内优先于目录参数，必须去掉，确保只查询用户明确选择的目录。
        environment.removeValue(forKey: "MO_ANALYZE_PATH")
        environment["PATH"] = ([executableURL.deletingLastPathComponent().path] + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        let argv = ([executableURL.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argumentBuffer in
            envp.withUnsafeBufferPointer { environmentBuffer in
                posix_spawn(&pid, executableURL.path, &actions, &attributes, argumentBuffer.baseAddress!, environmentBuffer.baseAddress!)
            }
        }
        try check(result)
        return pid
    }

    private func check(_ result: Int32) throws {
        guard result == 0 else { throw MoleError.launchFailed(String(cString: strerror(result))) }
    }

}

// 取消回调和后台等待线程共享这个标志；进程与管道不从取消回调直接操作。
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

private final class PipeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, any Error>?
    func set(_ result: Result<Data, any Error>) { lock.withLock { self.result = result } }
    var value: Data? { lock.withLock { try? result?.get() } }
}
