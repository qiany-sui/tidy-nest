import Foundation

/// 只读核验普通应用的包内进程与打开文件，不提供任意命令入口。
public struct RuntimeInspectionService: Sendable {
    private let psExecutable: URL
    private let lsofExecutable: URL

    public init() {
        psExecutable = URL(fileURLWithPath: "/bin/ps")
        lsofExecutable = URL(fileURLWithPath: "/usr/sbin/lsof")
    }

    internal init(psExecutable: URL, lsofExecutable: URL) {
        self.psExecutable = psExecutable
        self.lsofExecutable = lsofExecutable
    }

    public func inspect(applicationPath: String, targetPath: String, originalApplicationPath: String? = nil) async throws {
        let applicationPaths = [applicationPath] + (originalApplicationPath.map { [$0] } ?? [])
        for path in applicationPaths + [targetPath] {
            guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
                throw MaintenanceError.invalidResponse("运行状态核验路径无效。")
            }
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: applicationPath, isDirectory: &directory), directory.boolValue else {
            throw MaintenanceError.process("无法核验应用包的实际位置，已保留项目。")
        }
        do {
            let output = try await ProcessRunner().run(executableURL: psExecutable, arguments: ["-axo", "pid=,uid=,comm="], timeout: 5)
            guard output.stderr.isEmpty, let text = String(data: output.stdout, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MaintenanceError.process("进程列表不可完整核验，已保留项目。")
            }
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard fields.count == 3, let pid = Int32(fields[0]), pid > 0, UInt32(fields[1]) != nil else {
                    throw MaintenanceError.process("进程列表格式不完整，已保留项目。")
                }
                let command = String(fields[2])
                if applicationPaths.contains(where: { command == $0 || command.hasPrefix($0 + "/") }) {
                    throw MaintenanceError.process("应用或包内辅助进程仍在运行，已保留项目。")
                }
            }
            try await inspectOpenFiles(arguments: ["-n", "-P", "-Fpn", "+D", applicationPath])
            try await inspectOpenFiles(arguments: ["-n", "-P", "-Fpn", "--", targetPath])
        } catch is CancellationError { throw CancellationError() }
        catch let error as MaintenanceError { throw error }
        catch { throw MaintenanceError.process("无法完整核验运行状态，已保留项目。" + error.localizedDescription) }
    }

    private func inspectOpenFiles(arguments: [String]) async throws {
        let output = try await ProcessRunner().run(executableURL: lsofExecutable, arguments: arguments, timeout: 8, allowedExitCodes: [0, 1])
        // lsof 的 1 只有在双管道完全为空时才表示无匹配，警告或部分结果都不是空闲证据。
        guard output.stderr.isEmpty else { throw MaintenanceError.process("打开文件核验有警告或权限缺口，已保留项目。") }
        if output.exitCode == 1 && output.stdout.isEmpty { return }
        // 退出 1 也可能包含有效命中；它仍不能证明空闲，但足以说明目标被占用。
        guard let text = String(data: output.stdout, encoding: .utf8) else {
            throw MaintenanceError.process("打开文件核验结果不完整，已保留项目。")
        }
        var process = false
        var descriptor = false
        var file = false
        for line in text.split(whereSeparator: \.isNewline) {
            // -Fpn 仍会输出必选的 f 字段；每个进程、描述符都必须有完整的文件记录。
            if line.first == "p", let pid = Int32(line.dropFirst()), pid > 0, !process || (descriptor && file) {
                process = true; descriptor = false; file = false
            }
            else if line.first == "f", process, line.count > 1, !descriptor || file {
                descriptor = true; file = false
            }
            else if line.first == "n", descriptor, !file, line.count > 1 { file = true }
            else { throw MaintenanceError.process("打开文件核验格式不完整，已保留项目。") }
        }
        guard process, descriptor, file else { throw MaintenanceError.process("打开文件核验记录不完整，已保留项目。") }
        throw MaintenanceError.process("应用包或目标仍有打开文件，已保留项目。")
    }
}
