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
            var processes: [Int32: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard fields.count == 3, let pid = Int32(fields[0]), pid > 0, UInt32(fields[1]) != nil else {
                    throw MaintenanceError.process("进程列表格式不完整，已保留项目。")
                }
                let command = String(fields[2])
                guard processes.updateValue(command, forKey: pid) == nil else { throw MaintenanceError.process("进程列表格式不完整，已保留项目。") }
                if applicationPaths.contains(where: { command == $0 || command.hasPrefix($0 + "/") }) {
                    throw MaintenanceError.process("「\(runtimeDisplayText(URL(fileURLWithPath: command).lastPathComponent))」（PID \(pid)）仍在运行，已保留项目。\n位置：\(runtimeDisplayText(command))\n退出应用及其后台进程后，点击「重新检查」。")
                }
            }
            // 本体整体移动可容忍外部只读普通文件；目录句柄仍可通过 openat 改写成员，不能据 ar 放行。
            let bodyOnly = targetPath == applicationPath
            try await inspectOpenFiles(path: applicationPath, recursive: true, allowReadOnly: bodyOnly, processes: processes)
            if !bodyOnly {
                try await inspectOpenFiles(path: targetPath, recursive: false, allowReadOnly: false, processes: processes)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as MaintenanceError { throw error }
        catch { throw MaintenanceError.process("无法完整核验运行状态，已保留项目。" + error.localizedDescription) }
    }

    private func inspectOpenFiles(path: String, recursive: Bool, allowReadOnly: Bool, processes: [Int32: String]) async throws {
        // NUL 分隔避免文件名中的换行混入进程记录；同时读取访问方式、锁和文件类型。
        let arguments = ["-n", "-P", "+c", "0", "-F0pcfatln", recursive ? "+D" : "--", path]
        let output = try await ProcessRunner().run(executableURL: lsofExecutable, arguments: arguments, timeout: 8, allowedExitCodes: [0, 1])
        guard output.stderr.isEmpty else { throw MaintenanceError.process("打开文件核验有警告或权限缺口，已保留项目。") }
        if output.exitCode == 1 && output.stdout.isEmpty { return }
        let records = try openFileRecords(output.stdout, path: path, recursive: recursive)
        let blocked = records.filter { record in
            let knownProcess = processes[record.pid]?.hasPrefix("/") == true
            let numericDescriptor = !record.descriptor.isEmpty && record.descriptor.utf8.allSatisfy { (48...57).contains($0) }
            return !(allowReadOnly && knownProcess && numericDescriptor && record.access == "r" && record.lock == " " && record.type == "REG")
        }
        guard !blocked.isEmpty else { return }
        var details: [String] = []
        for record in blocked {
            let changed = processes[record.pid] == nil ? "；进程状态待复核" : ""
            let detail = "「\(runtimeDisplayText(record.command))」（PID \(record.pid)）· \(record.accessDescription)\(changed)\n\(runtimeDisplayText(record.path))"
            if !details.contains(detail) { details.append(detail) }
        }
        let remaining = details.count > 3 ? "\n另有 \(details.count - 3) 项占用。" : ""
        throw MaintenanceError.process("检测到其他进程占用，已保留项目。\n" + details.prefix(3).joined(separator: "\n") + remaining + "\n等待后台访问结束，或关闭相关窗口后，点击「重新检查」。")
    }
}

private struct OpenFileRecord {
    let pid: Int32
    let command: String
    let descriptor: String
    let access: String
    let lock: String
    let type: String
    let path: String

    var accessDescription: String {
        if access == "w" || access == "u" { return "可写打开" }
        if lock != " " { return "文件已加锁" }
        if ["txt", "mem", "mmap"].contains(descriptor) { return "文件映射，读写方式未确认" }
        if descriptor == "cwd" { return "进程的当前工作目录" }
        if type == "DIR" { return "目录仍被访问，不能确认仅用于浏览" }
        if access == "r" { return "只读文件访问" }
        return "访问方式未确认"
    }
}

private func openFileRecords(_ data: Data, path: String, recursive: Bool) throws -> [OpenFileRecord] {
    let invalid = MaintenanceError.process("打开文件核验记录不完整，已保留项目。")
    guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\0\n") else { throw invalid }
    let fields = text.split(separator: "\0", omittingEmptySubsequences: false)
    guard fields.last == "\n" else { throw invalid }
    var records: [OpenFileRecord] = []
    var pid: Int32?
    var command: String?
    var file: [Character: String] = [:]
    var processHasFile = false
    func finishFile() throws {
        guard !file.isEmpty else { return }
        guard let pid, let command, Set(file.keys) == Set("fatln"),
              let descriptor = file["f"], !descriptor.isEmpty,
              let access = file["a"], ["r", "w", "u", " ", "-"].contains(access),
              let lock = file["l"], lock.count == 1,
              let type = file["t"], !type.isEmpty,
              let encodedName = file["n"] else { throw invalid }
        let name = try lsofFieldText(encodedName)
        guard name == path || (recursive && name.hasPrefix(path + "/")),
              !name.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw invalid }
        records.append(OpenFileRecord(pid: pid, command: command, descriptor: descriptor, access: access, lock: lock, type: type, path: name))
        file.removeAll(keepingCapacity: true)
        processHasFile = true
    }
    for (index, part) in fields.dropLast().enumerated() {
        var field = part
        let boundary = field.first == "\n"
        if boundary { field = field.dropFirst() }
        guard let key = field.first else { throw invalid }
        let value = String(field.dropFirst())
        switch key {
        case "p":
            guard index == 0 || boundary else { throw invalid }
            try finishFile()
            guard (pid == nil || processHasFile), let next = Int32(value), next > 0 else { throw invalid }
            pid = next; command = nil; processHasFile = false
        case "c":
            guard !boundary, pid != nil, command == nil, file.isEmpty, !processHasFile, !value.isEmpty else { throw invalid }
            command = try lsofFieldText(value)
        case "f":
            guard boundary, pid != nil, command != nil else { throw invalid }
            try finishFile()
            file[key] = value
        case "a", "t", "l", "n":
            guard !boundary, file["f"] != nil, file[key] == nil else { throw invalid }
            file[key] = value
        default: throw invalid
        }
    }
    try finishFile()
    guard processHasFile, !records.isEmpty else { throw invalid }
    return records
}

// -F0 只改变分隔符，lsof 仍会转义反斜杠、控制字符及非当前 locale 的字节。
// 按字节仅解码一次，避免把文件名中原本的字面“\x..”再次解释成另一个路径。
private func lsofFieldText(_ value: String) throws -> String {
    let invalid = MaintenanceError.process("打开文件核验转义记录不完整，已保留项目。")
    let bytes = Array(value.utf8)
    var decoded: [UInt8] = []
    var index = 0
    func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 65 + 10
        case 97...102: byte - 97 + 10
        default: nil
        }
    }
    while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if byte != 92 { decoded.append(byte); continue }
        guard index < bytes.count else { throw invalid }
        let escape = bytes[index]
        index += 1
        switch escape {
        case 92: decoded.append(92)
        case 98: decoded.append(8)
        case 102: decoded.append(12)
        case 110: decoded.append(10)
        case 114: decoded.append(13)
        case 116: decoded.append(9)
        case 120:
            guard index + 1 < bytes.count, let high = hex(bytes[index]), let low = hex(bytes[index + 1]) else { throw invalid }
            decoded.append(high * 16 + low)
            index += 2
        default: throw invalid
        }
    }
    guard !decoded.contains(0), let result = String(bytes: decoded, encoding: .utf8) else { throw invalid }
    return result
}

private func runtimeDisplayText(_ value: String) -> String {
    value.prefix(1_024).unicodeScalars.map { scalar in
        switch scalar.value {
        case 10: "\\n"
        case 13: "\\r"
        case 9: "\\t"
        default: CharacterSet.controlCharacters.contains(scalar) || scalar.properties.generalCategory == .format ? "\\u{\(String(scalar.value, radix: 16))}" : String(scalar)
        }
    }.joined()
}
