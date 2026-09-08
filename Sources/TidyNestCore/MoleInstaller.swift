import CryptoKit
import Darwin
import Foundation

internal struct MoleInstallArtifact: Sendable {
    let url: URL
    let sha256: String
}

/// 只在缺失时安装固定版本；不执行上游安装脚本中的升级、提权或回退逻辑。
public struct MoleInstaller: Sendable {
    private let directory: URL
    private let artifacts: [MoleInstallArtifact]
    private let detect: @Sendable () async throws -> MoleInstallation
    private let download: @Sendable (URL, URL) async throws -> Void
    private static let version = "1.53.0"
    private static let maximumDownloadBytes = 64 * 1024 * 1024

    public init() {
        directory = Self.managedDirectory
        artifacts = Self.releaseArtifacts
        detect = { try await MoleService().detect() }
        download = Self.downloadArtifact
    }

    internal init(directory: URL, artifacts: [MoleInstallArtifact] = MoleInstaller.releaseArtifacts,
                  detect: @escaping @Sendable () async throws -> MoleInstallation,
                  download: (@Sendable (URL, URL) async throws -> Void)? = nil) {
        self.directory = directory
        self.artifacts = artifacts
        self.detect = detect
        self.download = download ?? Self.downloadArtifact
    }

    internal static var managedDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TidyNest/Mole")
    }

    internal static var managedExecutable: URL {
        managedDirectory.appendingPathComponent(version + "/mole")
    }

    public func install(onProgress: @escaping @Sendable (MoleInstallPhase) -> Void) async throws -> MoleInstallation {
        try Task.checkCancellation()
        onProgress(.preparing)
        if let existing = try await existingInstallation() { return existing }
        guard artifacts.count == 3 else { throw MoleInstallError.invalidPackage }
        let rootFD = try prepareDirectory()
        defer { close(rootFD) }
        let lockFD = openat(rootFD, ".install.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw MoleInstallError.unsafeDirectory }
        defer { close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_uid == getuid(),
              lockInfo.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
              lockInfo.st_mode & 0o077 == 0, lockInfo.st_nlink == 1 else { throw MoleInstallError.unsafeDirectory }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw MoleInstallError.busy }
        defer { _ = flock(lockFD, LOCK_UN) }
        if let existing = try await existingInstallation() { return existing }
        try requireAbsentVersion(rootFD)

        let stagingName = ".install-" + UUID().uuidString
        guard mkdirat(rootFD, stagingName, 0o700) == 0 else { throw MoleInstallError.unsafeDirectory }
        let staging = directory.appendingPathComponent(stagingName)
        // 只回收本次创建的 staging；已存在的版本和用户配置不进入清理范围。
        defer { try? FileManager.default.removeItem(at: staging) }
        let payload = staging.appendingPathComponent("payload")
        do {
            let names = ["source.tar.gz", "analyze-go", "status-go"]
            for (artifact, name) in zip(artifacts, names) {
                try Task.checkCancellation()
                onProgress(.downloading)
                let file = staging.appendingPathComponent(name)
                try await download(artifact.url, file)
                try Task.checkCancellation()
                onProgress(.verifying)
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size > 0, size <= Self.maximumDownloadBytes else { throw MoleInstallError.invalidPackage }
                let data = try Data(contentsOf: file)
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual == artifact.sha256 else { throw MoleInstallError.checksum }
            }

            onProgress(.installing)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            // 摘要固定且只提取运行目录；仓库内的文档软链、开发工具与安装器不会被执行。
            let members = ["mole", "mo", "bin", "lib", "README.md", "LICENSE"].map { "Mole-1.53.0/" + $0 }
            _ = try await ProcessRunner().run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xzf", staging.appendingPathComponent("source.tar.gz").path, "-C", payload.path,
                            "--strip-components", "1", "--no-same-owner", "--no-same-permissions"] + members, timeout: 30)
            for name in ["analyze-go", "status-go"] {
                try FileManager.default.moveItem(at: staging.appendingPathComponent(name), to: payload.appendingPathComponent("bin/" + name))
            }
            for name in ["mole", "mo", "bin/analyze-go", "bin/status-go"] {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payload.appendingPathComponent(name).path)
            }
            try checkPackage(payload)
            try Task.checkCancellation()
            onProgress(.checking)
            let verified = try await MoleService(candidates: [payload.appendingPathComponent("mole")]).detect()
            guard verified.isSupported else { throw MoleInstallError.invalidPackage }
            // 下载期间外部可能完成了安装；优先复用它，不发布第二份或覆盖已有版本。
            if let existing = try await existingInstallation() { return existing }
            try Task.checkCancellation()
            try requireAbsentVersion(rootFD)
            // 最后一段无 await：同卷 EXCL 发布完整目录，不暴露下载中的半成品。
            guard renameatx_np(rootFD, stagingName + "/payload", rootFD, Self.version, UInt32(RENAME_EXCL)) == 0 else {
                throw errno == EEXIST ? MoleInstallError.destinationConflict : MoleInstallError.installation("无法发布完整安装目录。")
            }
            return MoleInstallation(executableURL: directory.appendingPathComponent(Self.version + "/mole"), version: Self.version)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MoleInstallError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw MoleInstallError.installation(error.localizedDescription)
        }
    }

    private func existingInstallation() async throws -> MoleInstallation? {
        do { return try await detect() }
        catch MoleError.notInstalled { return nil }
    }

    private func requireAbsentVersion(_ rootFD: Int32) throws {
        var value = stat()
        guard fstatat(rootFD, Self.version, &value, AT_SYMLINK_NOFOLLOW) != 0 else { throw MoleInstallError.destinationConflict }
        guard errno == ENOENT else { throw MoleInstallError.unsafeDirectory }
    }

    private func prepareDirectory() throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("\0") else { throw MoleInstallError.unsafeDirectory }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw MoleInstallError.unsafeDirectory }
        do {
            for component in directory.path.split(separator: "/") {
                guard component != ".", component != ".." else { throw MoleInstallError.unsafeDirectory }
                var next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(current, String(component), 0o700) == 0 || errno == EEXIST else { throw MoleInstallError.unsafeDirectory }
                    next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw MoleInstallError.unsafeDirectory }
                close(current); current = next
                var info = stat()
                guard fstat(current, &info) == 0, info.st_mode & 0o022 == 0,
                      info.st_uid == getuid() || info.st_uid == 0 else { throw MoleInstallError.unsafeDirectory }
            }
            var info = stat()
            guard fstat(current, &info) == 0, info.st_uid == getuid() else { throw MoleInstallError.unsafeDirectory }
            return current
        } catch { close(current); throw error }
    }

    private func checkPackage(_ payload: URL) throws {
        for name in ["mole", "mo", "bin/analyze.sh", "bin/status.sh", "bin/uninstall.sh", "lib/core/common.sh", "bin/analyze-go", "bin/status-go", "README.md", "LICENSE"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: payload.appendingPathComponent(name).path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw MoleInstallError.invalidPackage }
        }
    }

    private static func downloadArtifact(_ url: URL, _ destination: URL) async throws {
        do {
            // -q 放首位，避免用户 curlrc 改变输出位置或下载行为；只允许 HTTPS 跳转。
            _ = try await ProcessRunner().run(executableURL: URL(fileURLWithPath: "/usr/bin/curl"), arguments: [
                "--disable", "--fail", "--silent", "--show-error", "--location", "--max-redirs", "5",
                "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "15", "--max-time", "180",
                "--max-filesize", String(maximumDownloadBytes), "--output", destination.path, "--url", url.absoluteString
            ], timeout: 190)
        } catch is CancellationError { throw CancellationError() }
        catch { throw MoleInstallError.download(error.localizedDescription) }
    }

    // 来源为官方 V1.53.0 release API / SHA256SUMS；源码摘要另与 Homebrew 1.53.0 formula 核对。
    internal static var releaseArtifacts: [MoleInstallArtifact] {
        #if arch(arm64)
        let architecture = "arm64"
        let analyze = "637841dda6a56523af65c2befc4628732200cfe994476b38fde67b17432a0afb"
        let status = "46b8aded69d013d00f858908b02d35ea2d39087ccc474bcb8c2e65988fe0028e"
        #else
        let architecture = "amd64"
        let analyze = "9113bfdc226e33eb3ccea548ab0e6012eda032c47ee33d538dd0609acd1b997c"
        let status = "0b310ecc008297ce227813aa077ad3007e7aa1eb86fb7f0daf9cd175e667ebb6"
        #endif
        let base = "https://github.com/tw93/Mole/releases/download/V1.53.0/"
        return [
            MoleInstallArtifact(url: URL(string: "https://github.com/tw93/Mole/archive/refs/tags/V1.53.0.tar.gz")!, sha256: "35c812d5298a08c672062ac4e1d5a523876144ff0708f9c5c77385d52faccc77"),
            MoleInstallArtifact(url: URL(string: base + "analyze-darwin-" + architecture)!, sha256: analyze),
            MoleInstallArtifact(url: URL(string: base + "status-darwin-" + architecture)!, sha256: status)
        ]
    }
}
