import Foundation
import CryptoKit
import Darwin

struct EngineFailure: Error, LocalizedError, Sendable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func protectionContains(_ path: String, _ root: String) -> Bool { pathInside(path.lowercased(), root.lowercased()) }
func pathInside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
func canonicalPath(_ path: String) throws -> String {
    guard path.hasPrefix("/"), path != "/", !path.contains("//"),
          !path.contains("\0"),
          !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
        throw EngineFailure("路径不是规范的绝对路径。")
    }
    return path.hasSuffix("/") ? String(path.dropLast()) : path
}

struct FileIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let owner: UInt32
    let group: UInt32
    let mode: UInt16
    let links: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; owner = s.st_uid; group = s.st_gid; mode = s.st_mode
        links = s.st_nlink; size = s.st_size
        modifiedSeconds = Int64(s.st_mtimespec.tv_sec); modifiedNanos = Int64(s.st_mtimespec.tv_nsec)
        changedSeconds = Int64(s.st_ctimespec.tv_sec); changedNanos = Int64(s.st_ctimespec.tv_nsec)
    }
    // 本地快照用固定顺序数组保存全部身份字段，避免大型应用重复字段名超过记录上限。
    init(from decoder: any Decoder) throws {
        var values = try decoder.unkeyedContainer()
        guard values.count == 11 else { throw EngineFailure("快照身份字段不完整。") }
        device = try values.decode(Int32.self); inode = try values.decode(UInt64.self)
        owner = try values.decode(UInt32.self); group = try values.decode(UInt32.self); mode = try values.decode(UInt16.self)
        links = try values.decode(UInt16.self); size = try values.decode(Int64.self)
        modifiedSeconds = try values.decode(Int64.self); modifiedNanos = try values.decode(Int64.self)
        changedSeconds = try values.decode(Int64.self); changedNanos = try values.decode(Int64.self)
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(device); try values.encode(inode); try values.encode(owner); try values.encode(group); try values.encode(mode)
        try values.encode(links); try values.encode(size)
        try values.encode(modifiedSeconds); try values.encode(modifiedNanos)
        try values.encode(changedSeconds); try values.encode(changedNanos)
    }
    var type: UInt16 { mode & UInt16(S_IFMT) }
    func sameDirectory(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && owner == other.owner && group == other.group && mode == other.mode
    }
    func sameMovedObject(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && owner == other.owner && group == other.group && mode == other.mode && links == other.links && size == other.size && modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos
    }
}

final class DirectoryFD {
    let fd: Int32
    let identities: [FileIdentity]
    init(path: String) throws {
        _ = try canonicalPath(path)
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw EngineFailure("无法打开路径根目录。") }
        var chain: [FileIdentity] = []
        do {
            for name in path.split(separator: "/") {
                let next = openat(current, String(name), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw EngineFailure("目录不存在、权限不足或包含符号链接：\(path)") }
                close(current); current = next
                var st = stat()
                guard fstat(current, &st) == 0 else { throw EngineFailure("无法核对目录身份。") }
                chain.append(FileIdentity(st))
            }
        } catch { close(current); throw error }
        fd = current; identities = chain
    }
    deinit { close(fd) }
    func names() throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let directory = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw EngineFailure("无法完整枚举目录。")
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw EngineFailure("目录枚举中断。") }
        return names.sorted()
    }
}

// 缺省仅接受确证的 ENOENT；不能将权限拒绝或悬空链接伪装成“不存在”。
func existingIdentity(_ path: String) throws -> FileIdentity? {
    let components = try canonicalPath(path).split(separator: "/").map(String.init)
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw EngineFailure("无法检查路径可见性。") }
    defer { close(fd) }
    for (index, name) in components.enumerated() {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw EngineFailure("路径不可完整核验：\(path)")
        }
        let value = FileIdentity(info)
        if index == components.count - 1 { return value }
        guard value.type == S_IFDIR else { throw EngineFailure("路径祖先不是普通目录：\(path)") }
        let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw EngineFailure("无法打开路径祖先：\(path)") }
        close(fd); fd = next
    }
    return nil
}

func identity(at path: String) throws -> FileIdentity {
    let url = URL(fileURLWithPath: try canonicalPath(path))
    let parent = try DirectoryFD(path: url.deletingLastPathComponent().path)
    return try identity(parent: parent.fd, name: url.lastPathComponent)
}
func identity(parent: Int32, name: String) throws -> FileIdentity {
    var st = stat()
    guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw EngineFailure("无法读取文件身份：\(name)") }
    return FileIdentity(st)
}

struct SnapshotMember: Codable, Equatable, Sendable {
    let relativePath: String
    let identity: FileIdentity
    let linkTarget: String?
    init(relativePath: String, identity: FileIdentity, linkTarget: String?) {
        self.relativePath = relativePath; self.identity = identity; self.linkTarget = linkTarget
    }
    init(from decoder: any Decoder) throws {
        var values = try decoder.unkeyedContainer()
        guard values.count == 3 else { throw EngineFailure("快照成员字段不完整。") }
        relativePath = try values.decode(String.self)
        identity = try values.decode(FileIdentity.self)
        linkTarget = try values.decodeIfPresent(String.self)
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(relativePath); try values.encode(identity); try values.encode(linkTarget)
    }
}
struct ObjectSnapshot: Codable, Sendable {
    let parents: [FileIdentity]
    let members: [SnapshotMember]
    var bytes: UInt64 {
        var counted: Set<UInt64> = []
        return members.reduce(0) { total, member in
            // 包内硬链接共享同一份数据，体积只计一次；快照仍保留每个路径。
            total + (member.identity.type == S_IFREG && counted.insert(member.identity.inode).inserted ? UInt64(max(0, member.identity.size)) : 0)
        }
    }
    static func capture(_ path: String, application: Bool) throws -> Self {
        let url = URL(fileURLWithPath: try canonicalPath(path))
        let parent = try DirectoryFD(path: url.deletingLastPathComponent().path)
        var members: [SnapshotMember] = []
        try walk(parent: parent.fd, name: url.lastPathComponent, relative: "", root: path, application: application, device: nil, members: &members)
        try validateHardLinks(members)
        return Self(parents: parent.identities, members: members)
    }
    static func captureFinalLocation(_ path: String, application: Bool) throws -> Self {
        let normalized = try canonicalPath(path)
        // 系统可能允许读取本次返回的 Trash 对象，却禁止读取/枚举 Trash 父目录。
        // O_NOFOLLOW_ANY 在内核中拒绝整个路径的链接；这里只打开指定对象，不打开其父目录。
        let flags = O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK | (application ? O_DIRECTORY : 0)
        let fd = open(normalized, flags)
        guard fd >= 0 else { throw EngineFailure("无法直接核验系统返回的具体对象，或路径包含符号链接。") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw EngineFailure("无法读取最终对象身份。") }
        let original = FileIdentity(before)
        var members: [SnapshotMember] = []
        if application {
            // 从应用根自己的 FD 遍历，仅检查包内成员，复用完整成员/链接约束。
            try walk(parent: fd, name: ".", relative: "", root: normalized, application: true, device: original.device, members: &members)
        } else {
            guard original.type == S_IFREG, original.owner == getuid(), original.links == 1, original.mode & 0o6022 == 0 else { throw EngineFailure("最终文件类型、属主、链接数或权限不符合计划。") }
            members = [SnapshotMember(relativePath: "", identity: original, linkTarget: nil)]
        }
        try validateHardLinks(members)
        var after = stat()
        guard fstat(fd, &after) == 0, original == FileIdentity(after), members.first?.identity == original else { throw EngineFailure("最终对象在复验期间发生变化。") }
        let location = open(normalized, flags)
        guard location >= 0 else { throw EngineFailure("最终位置在复验期间发生变化。") }
        defer { close(location) }
        guard fstat(location, &after) == 0, original == FileIdentity(after) else { throw EngineFailure("系统返回位置已不再指向复验对象。") }
        return Self(parents: [], members: members)
    }
    private static func walk(parent: Int32, name: String, relative: String, root: String, application: Bool, device: Int32?, members: inout [SnapshotMember]) throws {
        let info = try identity(parent: parent, name: name)
        // Xcode 的系统安装成员使用 root:wheel 组写；其它共享组及全员写入仍不接受。
        let systemPackageMember = application && info.owner == 0 && info.group == 0
        guard info.owner == getuid() || (application && info.owner == 0),
              info.type == S_IFLNK || (info.mode & 0o6002 == 0 && (info.mode & 0o020 == 0 || systemPackageMember)),
              device == nil || info.device == device else { throw EngineFailure("目标属主、权限或卷不在支持范围。") }
        var link: String?
        if info.type == S_IFLNK {
            guard application, !relative.isEmpty else { throw EngineFailure("目标是符号链接，已保留。") }
            var bytes = [CChar](repeating: 0, count: 4097)
            let count = readlinkat(parent, name, &bytes, 4096)
            guard count > 0, count < 4096 else { throw EngineFailure("无法完整读取包内链接。") }
            bytes[Int(count)] = 0
            let target = String(decoding: bytes.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !target.hasPrefix("/"), !target.contains("\0") else { throw EngineFailure("应用包含指向包外的链接。") }
            let location = URL(fileURLWithPath: root).appendingPathComponent(relative).deletingLastPathComponent()
            let resolved = location.appendingPathComponent(target).standardizedFileURL.path
            guard pathInside(resolved, root) else { throw EngineFailure("应用包含指向包外的链接。") }
            link = target
        } else if info.type == S_IFREG {
            guard info.links == 1 || application else { throw EngineFailure("普通缓存或日志的硬链接已保留。") }
        } else if info.type == S_IFDIR {
            guard application else { throw EngineFailure("首批规则不移动缓存目录。") }
        } else { throw EngineFailure("特殊文件不支持维护。") }
        members.append(SnapshotMember(relativePath: relative, identity: info, linkTarget: link))
        if info.type == S_IFDIR {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw EngineFailure("无法打开应用成员目录。") }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, info == FileIdentity(st) else { throw EngineFailure("扫描时目录发生变化。") }
            let copied = dup(fd)
            guard copied >= 0, let directory = fdopendir(copied) else {
                if copied >= 0 { close(copied) }
                throw EngineFailure("无法完整枚举应用成员。")
            }
            var names: [String] = []
            errno = 0
            while let entry = readdir(directory) {
                let child = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if child != "." && child != ".." { names.append(child) }
                errno = 0
            }
            let failure = errno
            closedir(directory)
            guard failure == 0 else { throw EngineFailure("应用目录枚举不完整。") }
            for child in names.sorted() {
                try walk(parent: fd, name: child, relative: relative.isEmpty ? child : relative + "/" + child, root: root, application: application, device: info.device, members: &members)
            }
            guard fstat(fd, &st) == 0, FileIdentity(st) == info else { throw EngineFailure("扫描时应用目录成员发生变化。") }
        }
    }
    private static func validateHardLinks(_ members: [SnapshotMember]) throws {
        // 只有同卷且所有链接都位于本包的文件才随整包移动，避免授权包外共享对象。
        let groups = Dictionary(grouping: members.filter { $0.identity.type == S_IFREG && $0.identity.links > 1 }, by: { $0.identity.inode })
        for group in groups.values {
            let first = group[0].identity
            guard group.count == Int(first.links), group.allSatisfy({ $0.identity == first }) else {
                throw EngineFailure("应用包含包外硬链接，或链接身份在检查期间发生变化。")
            }
        }
    }
    func matches(_ current: Self, moved: Bool = false) -> Bool {
        guard members.count == current.members.count else { return false }
        if !moved {
            guard parents.count == current.parents.count, zip(parents, current.parents).allSatisfy({ $0.sameDirectory($1) }) else { return false }
        }
        return zip(members, current.members).allSatisfy { old, new in
            old.relativePath == new.relativePath && old.linkTarget == new.linkTarget &&
            ((moved && old.relativePath.isEmpty) ? old.identity.sameMovedObject(new.identity) : old.identity == new.identity)
        }
    }
}

final class EngineStore {
    let root: String
    let directory: DirectoryFD
    init(home: String) throws {
        let base = home + "/Library/Application Support"
        let homeDirectory = try DirectoryFD(path: home)
        if mkdirat(homeDirectory.fd, "Library", 0o700) != 0 && errno != EEXIST { throw EngineFailure("无法建立用户 Library。") }
        let library = try DirectoryFD(path: home + "/Library")
        if mkdirat(library.fd, "Application Support", 0o700) != 0 && errno != EEXIST { throw EngineFailure("无法建立 Application Support。") }
        _ = try DirectoryFD(path: base)
        root = base + "/TidyNest/Engine"
        var current = base
        for component in ["TidyNest", "Engine"] {
            current += "/" + component
            try Self.privateDirectory(current)
        }
        directory = try DirectoryFD(path: root)
        for name in ["Plans", "Consumed", "History", "Journals", "Transactions"] { try Self.privateDirectory(root + "/" + name) }
    }
    static func privateDirectory(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        let parent = try DirectoryFD(path: url.deletingLastPathComponent().path)
        if mkdirat(parent.fd, url.lastPathComponent, 0o700) != 0 && errno != EEXIST { throw EngineFailure("无法建立私有引擎目录。") }
        let info = try identity(parent: parent.fd, name: url.lastPathComponent)
        guard info.type == S_IFDIR, info.owner == getuid(), info.mode & 0o077 == 0 else { throw EngineFailure("已有引擎目录权限不安全，未自动修改权限：\(path)") }
    }
    func read<T: Decodable>(_ type: T.Type, _ relative: String) throws -> T {
        try MaintenanceJSON.decoder().decode(type, from: readData(relative))
    }
    func readData(_ relative: String) throws -> Data {
        let path = root + "/" + relative
        let url = URL(fileURLWithPath: path)
        let parent = try DirectoryFD(path: url.deletingLastPathComponent().path)
        let fd = openat(parent.fd, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw EngineFailure("本地计划或结果不存在。") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size <= MaintenanceLimits.maximumRecordBytes else { throw EngineFailure("本地记录权限、类型或长度不安全。") }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw EngineFailure("本地记录读取失败。") }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= MaintenanceLimits.maximumRecordBytes else { throw EngineFailure("本地记录过大。") }
        }
        return result
    }
    func write<T: Encodable>(_ value: T, _ relative: String, exclusive: Bool = true) throws {
        let data = try MaintenanceJSON.encoder().encode(value)
        guard data.count <= MaintenanceLimits.maximumRecordBytes else { throw EngineFailure("维护记录超过 32 MiB 上限，请缩小范围。") }
        if !exclusive { try writeData(data, relative, exclusive: false); return }
        let url = URL(fileURLWithPath: root + "/" + relative)
        let parent = try DirectoryFD(path: url.deletingLastPathComponent().path)
        let temporary = "." + UUID().uuidString + ".tmp"
        let relativeParent = (relative as NSString).deletingLastPathComponent
        let temporaryRelative = relativeParent.isEmpty ? temporary : relativeParent + "/" + temporary
        defer { unlinkat(parent.fd, temporary, 0) }
        try writeData(data, temporaryRelative)
        guard renameatx_np(parent.fd, temporary, parent.fd, url.lastPathComponent, UInt32(RENAME_EXCL)) == 0, fsync(parent.fd) == 0 else { throw EngineFailure("维护记录无法独占、完整地发布。") }
    }
    func writeData(_ data: Data, _ relative: String, exclusive: Bool = true, append: Bool = false) throws {
        guard data.count <= MaintenanceLimits.maximumRecordBytes else { throw EngineFailure("维护记录超过 32 MiB 上限。") }
        let url = URL(fileURLWithPath: root + "/" + relative)
        let parent = try DirectoryFD(path: url.deletingLastPathComponent().path)
        let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (append ? O_APPEND : (exclusive ? O_EXCL : 0))
        let fd = openat(parent.fd, url.lastPathComponent, flags, 0o600)
        guard fd >= 0 else { throw EngineFailure("本地记录无法安全写入，计划可能已执行。") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw EngineFailure("本地记录权限不安全。") }
        if !append && !exclusive {
            guard ftruncate(fd, 0) == 0 else { throw EngineFailure("本地记录不能安全更新。") }
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw EngineFailure("本地记录写入未完成。") }
                offset += count
            }
        }
        guard fsync(fd) == 0, fsync(parent.fd) == 0 else { throw EngineFailure("本地记录未能同步，停止文件操作。") }
    }
    func exists(_ relative: String) -> Bool { (try? identity(at: root + "/" + relative)) != nil }
    func names(_ relative: String) throws -> [String] { try DirectoryFD(path: root + "/" + relative).names() }
    func lock() throws -> Int32 {
        let fd = openat(directory.fd, "execution.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw EngineFailure("无法打开维护锁。") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw EngineFailure("另一个维护正在执行，或维护锁权限不安全。")
        }
        return fd
    }
}

import TidyNestProtocol
