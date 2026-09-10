import Foundation
import Darwin

// 只授权已明确识别的单应用容器；不以 UUID、显示名称或相似前缀猜测归属。
struct ContainerOwnership: Codable, Sendable {
    let path: String
    let bundleID: String
    let parents: [FileIdentity]
    let metadataIdentity: FileIdentity
    let metadataDigest: String

    static func discover(home: String, bundleID: String, checkCancelled: () throws -> Void) throws -> Self? {
        let containers = home + "/Library/Containers"
        guard try existingIdentity(containers) != nil else { return nil }
        let directory = try DirectoryFD(path: containers)
        let before = try identity(at: containers)
        let names = try directory.names()
        guard names.count <= 10_000 else { throw EngineFailure("容器数量超过核验范围。") }
        let deadline = Date().addingTimeInterval(30)
        var matches: [Self] = []
        var evidence: [Self] = []
        for name in names {
            try checkCancelled()
            guard Date() < deadline else { throw EngineFailure("容器归属核验超时。") }
            let entry = try identity(parent: directory.fd, name: name)
            if entry.type == S_IFREG { continue }
            guard entry.type == S_IFDIR else { throw EngineFailure("容器目录包含无法核验的链接或特殊对象。") }
            let owner = try capture(containers + "/" + name)
            evidence.append(owner)
            if owner.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame { matches.append(owner) }
        }
        // 不匹配的元数据也是唯一性证据；只复核命中的容器会漏掉扫描中改成同 ID 的其它容器。
        for owner in evidence {
            try checkCancelled()
            guard Date() < deadline else { throw EngineFailure("容器归属复核超时。") }
            try owner.verify(home: home)
        }
        guard try identity(at: containers) == before else { throw EngineFailure("核验期间容器集合发生变化。") }
        guard matches.count <= 1 else { throw EngineFailure("存在多个使用相同标识的容器，归属不唯一。") }
        guard let result = matches.first else { return nil }
        guard result.bundleID == bundleID else { throw EngineFailure("容器标识与应用大小写不一致。") }
        return result
    }

    func matches(_ other: Self) -> Bool {
        path == other.path && bundleID == other.bundleID && metadataIdentity == other.metadataIdentity && metadataDigest == other.metadataDigest && parents.count == other.parents.count && zip(parents, other.parents).allSatisfy { $0.sameDirectory($1) }
    }

    func verifyUnique(home: String, checkCancelled: () throws -> Void) throws {
        guard let current = try Self.discover(home: home, bundleID: bundleID, checkCancelled: checkCancelled), matches(current) else { throw EngineFailure("容器归属已变化，请重新生成计划。") }
    }

    func verify(home: String) throws {
        guard URL(fileURLWithPath: try canonicalPath(path)).deletingLastPathComponent().path == home + "/Library/Containers",
              matches(try Self.capture(path)) else { throw EngineFailure("容器归属信息或路径身份已变化，文件已保留。") }
    }

    private static func capture(_ path: String) throws -> Self {
        let directory = try DirectoryFD(path: path)
        guard let root = directory.identities.last, root.owner == getuid(), root.mode & 0o6022 == 0 else { throw EngineFailure("容器属主或权限无法确认。") }
        let metadata = path + "/.com.apple.containermanagerd.metadata.plist"
        let fd = open(metadata, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw EngineFailure("容器归属信息不可读取，可能受系统权限限制。") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw EngineFailure("无法读取容器元数据身份。") }
        let metadataIdentity = FileIdentity(before)
        guard metadataIdentity.type == S_IFREG, metadataIdentity.links == 1, metadataIdentity.owner == getuid(), metadataIdentity.mode & 0o6022 == 0, metadataIdentity.size > 0, metadataIdentity.size <= 1_048_576 else { throw EngineFailure("容器元数据类型、大小或权限不在支持范围。") }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count >= 0 else { throw EngineFailure("容器元数据读取不完整。") }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= 1_048_576 else { throw EngineFailure("容器元数据超过读取范围。") }
        }
        var after = stat()
        let current = try DirectoryFD(path: path)
        guard fstat(fd, &after) == 0, metadataIdentity == FileIdentity(after),
              try identity(at: metadata) == metadataIdentity,
              directory.identities.count == current.identities.count,
              zip(directory.identities, current.identities).allSatisfy({ $0.sameDirectory($1) }) else { throw EngineFailure("读取期间容器元数据或路径发生变化。") }
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["MCMMetadataIdentifier"] as? String, validBundle(bundleID) else { throw EngineFailure("容器未提供可确认的完整应用标识。") }
        return Self(path: path, bundleID: bundleID, parents: directory.identities, metadataIdentity: metadataIdentity, metadataDigest: digest(data))
    }
}
