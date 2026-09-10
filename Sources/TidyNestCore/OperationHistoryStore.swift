import Darwin
import Foundation
import TidyNestProtocol

public enum OperationKind: String, Codable, Sendable, Hashable {
    case applicationList, applicationRefresh, diskAnalysis, cleanScan, uninstallPlan, execution
}

public struct OperationRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: OperationKind
    public let status: MaintenanceStatus
    public let title: String
    public let targetPath: String?
    public let startedAt: Date
    public let finishedAt: Date
    public let summary: String
    public let execution: MaintenanceResult?

    public init(id: String = UUID().uuidString, kind: OperationKind, status: MaintenanceStatus, title: String, targetPath: String? = nil, startedAt: Date, finishedAt: Date = Date(), summary: String, execution: MaintenanceResult? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.title = title
        self.targetPath = targetPath
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.summary = summary
        self.execution = execution
    }

    public init(execution result: MaintenanceResult) {
        self.init(id: "execution:" + result.runID, kind: .execution, status: result.status, title: result.title, startedAt: result.startedAt, finishedAt: result.finishedAt, summary: result.message ?? "", execution: result)
    }
}

public struct OperationHistorySnapshot: Codable, Sendable, Equatable {
    public var records: [OperationRecord]
    public var deletedExecutionRunIDs: Set<String>

    public init(records: [OperationRecord] = [], deletedExecutionRunIDs: Set<String> = []) {
        self.records = records
        self.deletedExecutionRunIDs = deletedExecutionRunIDs
    }
}

public struct OperationHistoryStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var standard: OperationHistoryStore {
        OperationHistoryStore(fileURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TidyNest/operation-history.json"))
    }

    public func load() throws -> OperationHistorySnapshot {
        guard let parent = try openParent(createIfMissing: false) else { return OperationHistorySnapshot() }
        defer { close(parent) }
        return try readSnapshot(parent: parent)?.snapshot ?? OperationHistorySnapshot()
    }

    public func save(_ snapshot: OperationHistorySnapshot) throws {
        try validate(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(OperationHistoryDocument(snapshot))
        guard data.count <= MaintenanceLimits.maximumRecordBytes else {
            throw OperationHistoryFailure("操作记录超过 32 MiB 上限，原有记录已保留。")
        }
        guard let parent = try openParent(createIfMissing: true) else {
            throw OperationHistoryFailure("无法建立操作记录目录。")
        }
        defer { close(parent) }
        // 损坏或未知版本不能当成空记录覆盖，页面删除也只更新这份展示快照。
        let previous = try readSnapshot(parent: parent)
        let temporary = ".operation-history-" + UUID().uuidString + ".tmp"
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw OperationHistoryFailure("无法建立私有操作记录文件。") }
        defer { close(descriptor); unlinkat(parent, temporary, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw OperationHistoryFailure("无法设置新记录文件的私有权限。") }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw OperationHistoryFailure("操作记录写入未完成，原有记录已保留。") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw OperationHistoryFailure("操作记录同步失败，原有记录已保留。") }
        try verifyParent(parent)
        switch (previous?.identity, try currentIdentity(parent: parent)) {
        case (nil, nil): break
        case let (original?, current?) where sameFile(original, current): break
        default: throw OperationHistoryFailure("操作记录在保存期间发生变化，请重新载入后再试。")
        }
        let result: Int32
        if previous == nil {
            result = renameatx_np(parent, temporary, parent, fileURL.lastPathComponent, UInt32(RENAME_EXCL))
        } else {
            result = renameat(parent, temporary, parent, fileURL.lastPathComponent)
        }
        guard result == 0 else { throw OperationHistoryFailure("无法原子替换操作记录，原有记录已保留。") }
        guard fsync(parent) == 0 else { throw OperationHistoryFailure("操作记录已替换，但目录同步失败，请重新载入核对。") }
    }

    private func validate(_ snapshot: OperationHistorySnapshot) throws {
        guard Set(snapshot.records.map(\.id)).count == snapshot.records.count else {
            throw OperationHistoryFailure("操作记录包含重复标识，原有文件已保留。")
        }
        for record in snapshot.records {
            if let result = record.execution {
                guard record.kind == .execution, record.id == "execution:" + result.runID,
                      record.status == result.status, record.title == result.title,
                      record.startedAt == result.startedAt, record.finishedAt == result.finishedAt else {
                    throw OperationHistoryFailure("操作记录与执行结果不一致，原有文件已保留。")
                }
            }
        }
    }

    private func openParent(createIfMissing: Bool) throws -> Int32? {
        let path = fileURL.path
        guard fileURL.isFileURL, path.hasPrefix("/"), path != "/", !path.contains("\0"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw OperationHistoryFailure("操作记录路径无效。")
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw OperationHistoryFailure("无法打开操作记录路径根目录。") }
        do {
            for name in fileURL.deletingLastPathComponent().path.split(separator: "/") {
                var next = openat(current, String(name), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    if !createIfMissing { close(current); return nil }
                    guard mkdirat(current, String(name), 0o700) == 0 || errno == EEXIST else {
                        throw OperationHistoryFailure("无法建立操作记录目录。")
                    }
                    next = openat(current, String(name), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else {
                    throw OperationHistoryFailure("操作记录目录不可读取、不是普通目录或包含符号链接。")
                }
                close(current)
                current = next
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private func verifyParent(_ parent: Int32) throws {
        guard let current = try openParent(createIfMissing: false) else {
            throw OperationHistoryFailure("操作记录目录在保存期间发生变化。")
        }
        defer { close(current) }
        var original = stat(), latest = stat()
        guard fstat(parent, &original) == 0, fstat(current, &latest) == 0,
              original.st_dev == latest.st_dev, original.st_ino == latest.st_ino else {
            throw OperationHistoryFailure("操作记录目录在保存期间发生变化。")
        }
    }

    private func currentIdentity(parent: Int32) throws -> stat? {
        var info = stat()
        if fstatat(parent, fileURL.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw OperationHistoryFailure("无法核对操作记录文件。")
        }
        try validateFile(info)
        return info
    }

    private func validateFile(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
            throw OperationHistoryFailure("操作记录不是当前用户的私有普通文件，或包含链接。")
        }
        guard info.st_size >= 0, info.st_size <= MaintenanceLimits.maximumRecordBytes else {
            throw OperationHistoryFailure("操作记录超过 32 MiB 上限，原有文件已保留。")
        }
    }

    private func readSnapshot(parent: Int32) throws -> (snapshot: OperationHistorySnapshot, identity: stat)? {
        guard let expected = try currentIdentity(parent: parent) else { return nil }
        let descriptor = openat(parent, fileURL.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw OperationHistoryFailure("无法安全读取操作记录文件。") }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, sameFile(expected, initial) else {
            throw OperationHistoryFailure("操作记录在读取前发生变化。")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw OperationHistoryFailure("操作记录读取未完成，原有文件已保留。") }
            if count == 0 { break }
            guard data.count + count <= MaintenanceLimits.maximumRecordBytes else {
                throw OperationHistoryFailure("操作记录超过 32 MiB 上限，原有文件已保留。")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0, sameFile(initial, final) else {
            throw OperationHistoryFailure("操作记录在读取期间发生变化。")
        }
        let document: OperationHistoryDocument
        do { document = try JSONDecoder().decode(OperationHistoryDocument.self, from: data) }
        catch { throw OperationHistoryFailure("本地操作记录已损坏，原有文件已保留。") }
        guard document.schemaVersion == 1 else {
            throw OperationHistoryFailure("本地操作记录版本不受支持，原有文件已保留。")
        }
        let snapshot = OperationHistorySnapshot(records: document.records, deletedExecutionRunIDs: document.deletedExecutionRunIDs)
        try validate(snapshot)
        return (snapshot, initial)
    }

    private func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_mode == second.st_mode &&
        first.st_uid == second.st_uid && first.st_gid == second.st_gid && first.st_nlink == second.st_nlink &&
        first.st_size == second.st_size && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec &&
        first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec &&
        first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}

private struct OperationHistoryDocument: Codable {
    let schemaVersion: Int
    let records: [OperationRecord]
    let deletedExecutionRunIDs: Set<String>

    init(_ snapshot: OperationHistorySnapshot) {
        schemaVersion = 1
        records = snapshot.records
        deletedExecutionRunIDs = snapshot.deletedExecutionRunIDs
    }
}

private struct OperationHistoryFailure: Error, LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}
