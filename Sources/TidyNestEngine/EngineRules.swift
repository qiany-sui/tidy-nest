// SPDX-License-Identifier: GPL-3.0-or-later
// 保护规则移植自 Mole V1.53.0；原文及许可证见 Resources/MoleUpstream。
import Foundation
import AppKit
import Darwin
import TidyNestCore
import TidyNestProtocol

public final class EngineCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.withLock { value = true } }
    public var isCancelled: Bool { lock.withLock { value } }
}

struct EngineApplication: Codable, Hashable, Sendable {
    var path: String
    let bundleID: String
    let name: String
    let source: String
    var originalPath: String? = nil
    var metadataPath: String? = nil
    var metadataDigest: String? = nil
    var unsupportedReason: String? = nil
    var wrappedBundleRelativePath: String? = nil
    var isWrapped: Bool { wrappedBundleRelativePath != nil }
}
enum ExecutionBoundary: Sendable { case beforeMove, afterStaging, beforeTrash, afterTrash }
struct EngineContext: Sendable {
    let home: String
    let appRoots: [String]
    let catalog: @Sendable () async throws -> [EngineApplication]
    let runtime: @Sendable (EngineApplication, String) async throws -> Void
    let trash: @Sendable (URL) throws -> URL
    let hook: @Sendable (ExecutionBoundary, String, String) throws -> Void
    let environment: @Sendable () -> [String: String]
    var authorizedTrash: (@Sendable (URL, ObjectSnapshot) async throws -> URL)? = nil
    var authorizedTrashRoot: String? = nil
    static func production() -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return Self(home: home, appRoots: ["/Applications", home + "/Applications"], catalog: {
            let service = MoleService()
            let installation = try await service.detect()
            guard installation.isSupported else { throw MoleError.unsupportedVersion(installation.version) }
            let applications = try await service.applications(using: installation)
            var catalog = try applications.map { try catalogApplication(at: $0.path, name: $0.name, source: $0.source, observedBundleID: $0.bundleIdentifier) }
            // 核验范围沿用固定 Mole 的安装目录与挂载卷，避免额外触发桌面/下载隐私权限请求。
            let roots = ["/Applications", "/System/Applications", home + "/Applications", "/Library/Input Methods", home + "/Library/Input Methods", home + "/Library/Application Support/Setapp/Applications", "/opt/homebrew/Caskroom", "/usr/local/Caskroom", "/Volumes"]
            for root in roots {
                if try existingIdentity(root) == nil { continue }
                _ = try DirectoryFD(path: root)
                var enumerationError: String?
                guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { url, _ in
                    enumerationError = url.path
                    return false
                }) else { throw EngineFailure("无法枚举安装位置：\(root)") }
                var count = 0
                let deadline = Date().addingTimeInterval(30)
                while let url = enumerator.nextObject() as? URL {
                    try Task.checkCancellation()
                    count += 1
                    guard count <= 50_000, Date() < deadline else { throw EngineFailure("安装位置枚举超过安全时限或数量范围，未把不完整结果当作唯一归属：\(root)") }
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if url.pathExtension.lowercased() == "app" {
                        enumerator.skipDescendants()
                        guard values.isDirectory == true else { continue }
                        if !catalog.contains(where: { $0.path == url.path }) {
                            catalog.append(try catalogApplication(at: url.path, name: url.deletingPathExtension().lastPathComponent, source: "discovered"))
                        }
                    }
                }
                if let path = enumerationError { throw EngineFailure("安装目录可见性不完整：\(path)") }
            }
            return catalog.sorted { $0.path < $1.path }
        }, runtime: { app, path in
            let running = await MainActor.run {
                NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == app.path || $0.bundleIdentifier?.caseInsensitiveCompare(app.bundleID) == .orderedSame }
                    .map { "「\($0.localizedName ?? app.name)」（PID \($0.processIdentifier)）仍在运行，请退出后点击「重新检查」。" }
            }
            if let running { throw EngineFailure(running) }
            try await RuntimeInspectionService().inspect(applicationPath: app.path, targetPath: path, originalApplicationPath: app.originalPath)
        }, trash: { url in
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            guard let result = resulting as URL? else { throw EngineFailure("系统未返回废纸篓位置，需要人工核对。") }
            return result
        }, hook: { _, _, _ in }, environment: { ProcessInfo.processInfo.environment }, authorizedTrash: { url, snapshot in
            try await FinderTrashService.trash(url, snapshot: snapshot)
        }, authorizedTrashRoot: home + "/.Trash")
    }
}

private struct ApplicationMetadata {
    let bundleID: String
    let path: String
    let digest: String
    let unsupportedReason: String?
    let wrappedBundleRelativePath: String?
}

func catalogApplication(at path: String, name: String, source: String, observedBundleID: String? = nil) throws -> EngineApplication {
    let root = try identity(at: path)
    if root.type == S_IFLNK {
        return EngineApplication(path: path, bundleID: observedBundleID ?? "", name: name, source: source, unsupportedReason: "顶层链接应用仅用于安装归属核验，不执行维护：\(path)")
    }
    let metadata = try applicationMetadata(at: path)
    return EngineApplication(path: path, bundleID: metadata.bundleID, name: name, source: source, metadataPath: metadata.path, metadataDigest: metadata.digest, unsupportedReason: metadata.unsupportedReason, wrappedBundleRelativePath: metadata.wrappedBundleRelativePath)
}

func bundleID(at path: String) throws -> String { try applicationMetadata(at: path).bundleID }

private func applicationMetadata(at path: String) throws -> ApplicationMetadata {
    let root = try DirectoryFD(path: path)
    var infoPath = path + "/Contents/Info.plist"
    var wrappedBundleRelativePath: String?
    if try existingIdentity(infoPath) == nil {
        // Apple Silicon 的已知 iOS 包装布局：只读取链接文本，再以无链接路径打开包内真实 Info。
        guard let link = try existingIdentity(path + "/WrappedBundle"), link.type == S_IFLNK else { throw EngineFailure("应用缺少普通 Info.plist，且不是已知 iOS 包装布局：\(path)") }
        var bytes = [CChar](repeating: 0, count: 4097)
        let count = bytes.withUnsafeMutableBufferPointer { readlinkat(root.fd, "WrappedBundle", $0.baseAddress!, 4096) }
        guard count > 0, count < 4096, let target = String(bytes: bytes.prefix(Int(count)).map { UInt8(bitPattern: $0) }, encoding: .utf8), target.split(separator: "/", omittingEmptySubsequences: false).count == 2, target.hasPrefix("Wrapper/"), target.hasSuffix(".app"), target.count > "Wrapper/.app".count, !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw EngineFailure("iOS 包装链接无法安全识别：\(path)") }
        let payload = try canonicalPath(path + "/" + target)
        guard pathInside(payload, path + "/Wrapper") else { throw EngineFailure("iOS 包装路径超出应用：\(path)") }
        _ = try DirectoryFD(path: payload)
        infoPath = payload + "/Info.plist"
        wrappedBundleRelativePath = target
    }
    let fd = open(infoPath, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw EngineFailure("应用 Info.plist 无法安全读取：\(infoPath)") }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_size <= MaintenanceLimits.maximumRecordBytes else { throw EngineFailure("应用标识文件类型或大小不安全：\(infoPath)") }
    var data = Data(); var bytes = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count >= 0 else { throw EngineFailure("应用标识文件未完整读取：\(infoPath)") }
        if count == 0 { break }
        data.append(contentsOf: bytes.prefix(count))
        guard data.count <= MaintenanceLimits.maximumRecordBytes else { throw EngineFailure("应用标识文件超过读取范围：\(infoPath)") }
    }
    var after = stat()
    guard fstat(fd, &after) == 0, FileIdentity(before) == FileIdentity(after), try identity(at: infoPath) == FileIdentity(before) else { throw EngineFailure("读取时应用元数据发生变化：\(infoPath)") }
    let plist: [String: Any]
    do {
        guard let decoded = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw EngineFailure("结构不正确") }
        plist = decoded
    } catch { throw EngineFailure("应用 Info.plist 无法解析：\(infoPath)") }
    let id = plist["CFBundleIdentifier"] as? String ?? ""
    let unsupported: String?
    if !validBundle(id) { unsupported = id.isEmpty ? "应用未提供可用的 bundle ID，已保留：\(path)" : "应用 bundle ID 不符合首批完整标识规则，已保留：\(path)" }
    else { unsupported = nil }
    return ApplicationMetadata(bundleID: id, path: infoPath, digest: digest(data), unsupportedReason: unsupported, wrappedBundleRelativePath: wrappedBundleRelativePath)
}
func validBundle(_ value: String) -> Bool { value.range(of: #"^[A-Za-z0-9][-A-Za-z0-9]*(\.[A-Za-z0-9][-A-Za-z0-9]*)+$"#, options: .regularExpression) != nil }

struct EngineRules: Sendable {
    static let version = "mole-1.53.0-subset-5"
    static let engineVersion = "2.0.0"
    static let xcodeBundleID = "com.apple.dt.xcode"
    static let ids = ["mole.user-cache.exact-file.v1", "mole.user-log.exact-file.v1", "mole.application.bundle.v1", "tidynest.container-cache.exact-file.v1", "tidynest.container-log.exact-file.v1"]
    let arrays: [String: [String]]
    let resourceDigest: String
    init() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let adjacent = executable.deletingLastPathComponent().appendingPathComponent("TidyNest_TidyNestEngine.bundle")
        let bundle: Bundle
        if executable.lastPathComponent == "TidyNestBridge" && executable.path.contains(".app/Contents/") {
            let packaged = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/TidyNest_TidyNestEngine.bundle")
            guard let packagedBundle = Bundle(url: packaged) else { throw EngineFailure("随 App 分发的固定规则资源缺失。") }
            bundle = packagedBundle
        } else if let adjacentBundle = Bundle(url: adjacent) { bundle = adjacentBundle }
        else { bundle = Bundle.module }
        guard let url = bundle.url(forResource: "protection-data", withExtension: "json", subdirectory: "MoleUpstream") else { throw EngineFailure("固定 Mole 保护数据缺失。") }
        let data = try Data(contentsOf: url)
        guard digest(data) == "8ce6c9636153b8e9da129cb2b9ef50a141917b4446a223d9da096bd3604041ff" else { throw EngineFailure("固定 Mole 保护资源摘要不匹配。") }
        arrays = try JSONDecoder().decode([String: [String]].self, from: data)
        resourceDigest = digest(data)
        let keys = ["SYSTEM_CRITICAL_BUNDLES", "APPLE_UNINSTALLABLE_APPS", "DATA_PROTECTED_BUNDLES", "OFFICIAL_UNINSTALLER_RULES", "ENDPOINT_SECURITY_BUNDLE_PREFIXES", "DEFAULT_WHITELIST_PATTERNS", "SAFETY_WHITELIST_PATTERNS"]
        guard keys.allSatisfy({ !(arrays[$0] ?? []).isEmpty }) else { throw EngineFailure("固定保护数据不完整。") }
    }
    // 来源：Mole V1.53.0 app_protection.sh 的 bundle_matches_pattern 和 should_protect_data。
    // fnmatch 的 * 包含路径分隔符，与上游 [[ value == pattern ]] 一致；这里只扩大保护，不扩大候选。
    func matches(_ value: String, _ pattern: String) -> Bool { fnmatch(pattern.lowercased(), value.lowercased(), 0) == 0 }
    func appBlock(_ app: EngineApplication, clean: Bool) -> String? {
        if let reason = app.unsupportedReason { return reason }
        if app.source.lowercased().contains("brew") || app.path.contains("/Caskroom/") { return "Homebrew 管理的应用需使用原管理器。" }
        if (arrays["SYSTEM_CRITICAL_BUNDLES"] ?? []).contains(where: { matches(app.bundleID, $0) }) { return "Mole 系统组件保护。" }
        // 仅开放 Xcode 本体移除；Apple 组件与 Xcode 的开发数据仍受保护。
        if app.bundleID.lowercased().hasPrefix("com.apple."), clean || app.bundleID.lowercased() != Self.xcodeBundleID {
            return "当前范围保留此 Apple 应用或其开发数据。"
        }
        for rule in arrays["OFFICIAL_UNINSTALLER_RULES"] ?? [] {
            let parts = rule.components(separatedBy: "|")
            guard parts.count == 3 else { return "厂商卸载规则无法解析。" }
            if parts[1].split(separator: ",").contains(where: { app.bundleID.lowercased().hasPrefix($0) }) || parts[2].split(separator: ",").contains(where: { app.name.lowercased().contains($0) || app.path.lowercased().contains($0) }) {
                return "\(parts[0]) 应用需要厂商专用卸载器。"
            }
        }
        if (arrays["ENDPOINT_SECURITY_BUNDLE_PREFIXES"] ?? []).contains(where: { app.bundleID.lowercased().hasPrefix($0.lowercased()) }) { return "终端安全软件保护。" }
        if clean {
            let hot = ["com.apple.*", "org.cups.*", "com.microsoft.*", "com.visualstudio.*", "com.jetbrains.*", "com.docker.*", "com.getpostman.*", "com.insomnia.*", "*inputmethod*", "*InputMethod*", "*IME", "com.nssurge.*", "com.v2ray.*", "com.clash.*", "org.pqrs.Karabiner*"]
            if ((arrays["DATA_PROTECTED_BUNDLES"] ?? []) + hot).contains(where: { matches(app.bundleID, $0) || matches(app.name, $0) }) { return "Mole 敏感应用数据保护。" }
        }
        return nil
    }
    func configuration(context: EngineContext, protections: [String]) throws -> Configuration {
        func expand(_ pattern: String) -> String {
            var result = pattern.replacingOccurrences(of: "$HOME", with: context.home).replacingOccurrences(of: "${HOME}", with: context.home).replacingOccurrences(of: "$FINDER_METADATA_SENTINEL", with: "FINDER_METADATA")
            if result.hasPrefix("~/") { result = context.home + result.dropFirst() }
            return result
        }
        let whitelistPath = context.home + "/.config/mole/whitelist"
        var patterns: [String]
        var whitelistDigest = "absent"
        if let info = try existingIdentity(whitelistPath) {
            guard info.type == S_IFREG, info.links == 1, info.owner == getuid(), info.mode & 0o022 == 0, info.size <= 65536 else { throw EngineFailure("Mole 白名单文件权限、类型或长度不安全。") }
            let data = try Data(contentsOf: URL(fileURLWithPath: whitelistPath))
            guard let text = String(data: data, encoding: .utf8) else { throw EngineFailure("Mole 白名单不是 UTF-8。") }
            whitelistDigest = digest(data)
            patterns = []
            for raw in text.components(separatedBy: .newlines) {
                let line = expand(raw.trimmingCharacters(in: .whitespaces))
                if line.isEmpty || line.hasPrefix("#") { continue }
                guard line == "FINDER_METADATA" || (line.hasPrefix("/") && !line.contains("..") && !line.contains("//") && !line.contains("$") && !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })) else { throw EngineFailure("Mole 白名单包含不合法或无法展开的配置。") }
                let protectedSystemRoots = ["/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/etc", "/var/db"]
                guard line != "/", !protectedSystemRoots.contains(where: { pathInside(line, $0) }) else { throw EngineFailure("Mole 白名单包含不合法的系统根路径。") }
                patterns.append(line)
            }
        } else { patterns = (arrays["DEFAULT_WHITELIST_PATTERNS"] ?? []).map(expand) }
        patterns += (arrays["SAFETY_WHITELIST_PATTERNS"] ?? []).map(expand)
        let deno = try canonicalPath(context.environment()["DENO_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? context.home + "/Library/Caches/deno")
        guard !deno.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), ![context.home, context.home + "/Library", context.home + "/Library/Caches", context.home + "/.cache"].contains(deno) else { throw EngineFailure("DENO_DIR 过宽，无法安全确定保护范围。") }
        let payload = ["patterns": patterns.sorted(), "protected": protections.sorted(), "deno": [deno], "whitelist": [whitelistDigest]]
        return Configuration(patterns: patterns, protections: protections, deno: deno, digest: digest(try MaintenanceJSON.encoder().encode(payload)))
    }
    func fileBlock(_ path: String, configuration: Configuration) -> String? {
        if configuration.protections.contains(where: { protectionContains(path, $0) || protectionContains($0, path) }) { return "用户长期保护。" }
        if protectionContains(path, configuration.deno) || protectionContains(configuration.deno, path) { return "Deno 缓存包含持久状态，已保护。" }
        var ancestors = [path]
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while parent != "/" { ancestors.append(parent); parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path }
        for pattern in configuration.patterns where pattern != "FINDER_METADATA" {
            if ancestors.contains(where: { matches($0, pattern) }) { return "Mole 白名单或硬安全保护。" }
        }
        let lower = path.lowercased()
        let forbidden = [".mlmodel", ".mlmodelc", ".mlpackage", ".e5bundle", "com.apple.e5rt.e5bundlecache"]
        if forbidden.contains(where: { lower.contains($0) }) { return "编译模型保护。" }
        if URL(fileURLWithPath: path).lastPathComponent == ".DS_Store" { return "Finder 元数据保护。" }
        return nil
    }
    func fileImpact(_ path: String, isSQLite: Bool) -> String {
        // 内容风险交由用户判断；路径范围、归属、占用和长期保护仍独立核验。
        let lower = path.lowercased()
        let persistent = [".sqlite", ".sqlite3", ".db", "-wal", "-shm", "keychain", "credential", "session", "cookies", "preferences", "local storage", "indexeddb"]
        if isSQLite || persistent.contains(where: { lower.contains($0) }) {
            return "数据库或会话等持久状态文件，可能包含登录信息或本地数据。移入废纸篓可能导致退出登录、状态丢失或应用异常；默认不勾选，请自行判断，并一并核对相关数据库配套文件。"
        }
        return "移入废纸篓；缓存可能重新生成，日志移走后历史排错记录不可直接读取。"
    }
}
struct Configuration: Sendable {
    let patterns: [String]
    let protections: [String]
    let deno: String
    let digest: String
}
