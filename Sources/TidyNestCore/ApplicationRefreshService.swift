import Foundation
import Darwin

/// 只读取所选应用的信息和占用；维护计划仍由独立引擎重新核验。
public struct ApplicationRefreshService: Sendable {
    private let duExecutable: URL
    private let timeout: TimeInterval

    public init() {
        duExecutable = URL(fileURLWithPath: "/usr/bin/du")
        timeout = 30
    }

    internal init(duExecutable: URL, timeout: TimeInterval) {
        self.duExecutable = duExecutable
        self.timeout = timeout
    }

    public func refresh(_ application: MoleApplication) async throws -> MoleApplication {
        try Task.checkCancellation()
        let path = application.path
        guard path.hasPrefix("/"), path.hasSuffix(".app"), !path.contains("//"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw ApplicationRefreshFailure("应用路径不是规范的绝对 .app 路径。")
        }
        let root = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard root >= 0 else { throw ApplicationRefreshFailure("无法读取所选应用包，应用可能已移动、不可访问或包含路径链接。") }
        defer { close(root) }
        let rootIdentity = try ApplicationRefreshIdentity(descriptor: root)
        var infoPath = path + "/Contents/Info.plist"
        var info = open(infoPath, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        var payloadPath: String?
        var payload: Int32 = -1
        defer { if payload >= 0 { close(payload) } }
        if info < 0, errno == ENOENT {
            var wrapper = stat()
            guard fstatat(root, "WrappedBundle", &wrapper, AT_SYMLINK_NOFOLLOW) == 0,
                  wrapper.st_mode & S_IFMT == S_IFLNK else {
                throw ApplicationRefreshFailure("无法安全读取此应用的 Info.plist，请确认应用安装完整。")
            }
            // 只读取包装链接的文本，再用无链接路径打开包内元数据，不跟随任意链接。
            var bytes = [CChar](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBufferPointer { buffer in
                readlinkat(root, "WrappedBundle", buffer.baseAddress, buffer.count)
            }
            guard count > 0, count < bytes.count,
                  let target = String(bytes: bytes.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8),
                  !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ApplicationRefreshFailure("包装应用的位置无法完整识别。")
            }
            let components = target.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2, components[0] == "Wrapper",
                  components[1].hasSuffix(".app"), components[1].count > 4 else {
                throw ApplicationRefreshFailure("包装应用的链接不在支持的包内位置。")
            }
            let location = path + "/" + target
            payload = open(location, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard payload >= 0 else { throw ApplicationRefreshFailure("包装应用内容不可访问或包含路径链接。") }
            payloadPath = location
            infoPath = location + "/Info.plist"
            info = open(infoPath, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        }
        guard info >= 0 else { throw ApplicationRefreshFailure("无法安全读取此应用的 Info.plist，请确认应用安装完整。") }
        defer { close(info) }
        let infoIdentity = try ApplicationRefreshIdentity(descriptor: info)
        let payloadIdentity = payload >= 0 ? try ApplicationRefreshIdentity(descriptor: payload) : nil
        let maximumBytes = 1024 * 1024
        guard infoIdentity.mode & S_IFMT == S_IFREG, infoIdentity.size >= 0, infoIdentity.size <= maximumBytes else {
            throw ApplicationRefreshFailure("应用 Info.plist 的类型或大小不符合读取要求。")
        }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(info, &bytes, bytes.count)
            guard count >= 0 else { throw ApplicationRefreshFailure("应用信息未能完整读取。") }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= maximumBytes else { throw ApplicationRefreshFailure("应用 Info.plist 超过读取范围。") }
        }
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw ApplicationRefreshFailure("应用 Info.plist 已损坏或无法解析。")
        }
        guard let identifier = plist["CFBundleIdentifier"] as? String,
              !identifier.isEmpty, identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ApplicationRefreshFailure("应用没有提供可用的 Bundle ID，无法刷新。")
        }
        let name = [plist["CFBundleDisplayName"] as? String, plist["CFBundleName"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        try rootIdentity.verify(at: path, descriptor: root)
        try infoIdentity.verify(at: infoPath, descriptor: info)
        if let payloadPath, let payloadIdentity { try payloadIdentity.verify(at: payloadPath, descriptor: payload) }
        // du 默认不跟随包内链接；只传所选包的绝对路径，不读取同级应用或 Mole 列表。
        let output: ProcessOutput
        do {
            output = try await ProcessRunner().run(executableURL: duExecutable, arguments: ["-sk", path], timeout: timeout)
        } catch MoleError.timedOut {
            throw ApplicationRefreshFailure("读取此应用的体积超时，请稍后重试。")
        } catch MoleError.processFailed(_, let diagnostic) {
            throw ApplicationRefreshFailure("未能完整统计此应用的体积。" + diagnostic)
        }
        try Task.checkCancellation()
        guard output.stderr.isEmpty, let text = String(data: output.stdout, encoding: .utf8) else {
            throw ApplicationRefreshFailure("应用体积未能完整读取，请重试。")
        }
        let fields = text.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2, fields[1] == path + "\n", !fields[0].isEmpty,
              fields[0].allSatisfy({ $0 >= "0" && $0 <= "9" }), let kibibytes = Int64(fields[0]) else {
            throw ApplicationRefreshFailure("应用体积结果无法识别，请重试。")
        }
        let (byteCount, overflow) = kibibytes.multipliedReportingOverflow(by: 1024)
        guard !overflow else { throw ApplicationRefreshFailure("应用体积超出可显示范围。") }
        // 不把刷新前的名称与刷新途中被替换的应用体积拼成一个结果。
        try rootIdentity.verify(at: path, descriptor: root)
        try infoIdentity.verify(at: infoPath, descriptor: info)
        if let payloadPath, let payloadIdentity { try payloadIdentity.verify(at: payloadPath, descriptor: payload) }
        try Task.checkCancellation()
        return MoleApplication(name: name, bundleIdentifier: identifier, source: application.source,
                               uninstallName: application.uninstallName, path: path,
                               displaySize: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
    }
}

private struct ApplicationRefreshIdentity: Equatable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64

    init(descriptor: Int32) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw ApplicationRefreshFailure("无法核对此应用的位置与信息。") }
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
    }

    func verify(at path: String, descriptor: Int32) throws {
        let current = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard current >= 0 else { throw ApplicationRefreshFailure("刷新期间应用位置或信息发生变化，请重新检查。") }
        defer { close(current) }
        guard try self == ApplicationRefreshIdentity(descriptor: descriptor), try self == ApplicationRefreshIdentity(descriptor: current) else {
            throw ApplicationRefreshFailure("刷新期间应用位置或信息发生变化，请重新检查。")
        }
    }
}

private struct ApplicationRefreshFailure: Error, LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}
