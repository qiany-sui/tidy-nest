import Foundation

public struct MoleInstallation: Sendable, Equatable {
    public let executableURL: URL
    public let version: String
    public var isSupported: Bool { version == "1.53.0" }

    public init(executableURL: URL, version: String) {
        self.executableURL = executableURL
        self.version = version
    }
}

public struct MoleApplication: Identifiable, Sendable, Hashable, Codable {
    public let name: String
    public let bundleIdentifier: String
    public let source: String
    public let uninstallName: String
    public let path: String
    public let displaySize: String
    public var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name, source, path
        case bundleIdentifier = "bundle_id"
        case uninstallName = "uninstall_name"
        case displaySize = "size"
    }
}

public struct MoleDiskEntry: Identifiable, Sendable, Hashable, Decodable {
    public let name: String
    public let path: String
    public let size: UInt64
    public let isDirectory: Bool
    public var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name, path, size
        case isDirectory = "is_dir"
    }
}

public struct MoleDiskReport: Sendable, Decodable {
    public let path: String
    public let overview: Bool
    public let entries: [MoleDiskEntry]
    public let largeFiles: [MoleDiskEntry]
    public let totalSize: UInt64
    public let totalFiles: UInt64

    enum CodingKeys: String, CodingKey {
        case path, overview, entries
        case largeFiles = "large_files"
        case totalSize = "total_size"
        case totalFiles = "total_files"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        overview = try values.decode(Bool.self, forKey: .overview)
        entries = try values.decode([MoleDiskEntry].self, forKey: .entries)
        // 大文件记录没有 is_dir；仅在此分支确定为文件，普通 entries 仍严格校验该字段。
        largeFiles = values.contains(.largeFiles) ? try values.decode([LargeFile].self, forKey: .largeFiles).map {
            MoleDiskEntry(name: $0.name, path: $0.path, size: $0.size, isDirectory: false)
        } : []
        totalSize = try values.decode(UInt64.self, forKey: .totalSize)
        // Mole 1.53.0 使用 omitempty 表达零文件数，空目录的 JSON 会省略此键。
        totalFiles = values.contains(.totalFiles) ? try values.decode(UInt64.self, forKey: .totalFiles) : 0
    }

    private struct LargeFile: Decodable {
        let name: String
        let path: String
        let size: UInt64
    }
}

public enum MoleError: Error, LocalizedError, Sendable {
    case notInstalled
    case invalidVersion
    case unsupportedVersion(String)
    case invalidDirectory
    case invalidExecutable
    case invalidResponse(String)
    case launchFailed(String)
    case processFailed(Int32, String)
    case timedOut
    case outputFailed

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "未找到 Mole。请确认已在本机安装。"
        case .invalidVersion: "无法识别 Mole 版本，请检查本机安装。"
        case .unsupportedVersion(let version): "当前 Mole 版本 \(Self.safeDiagnostic(version)) 尚未验证，暂时无法查询。已验证版本为 1.53.0。"
        case .invalidDirectory: "请选择一个存在的本地目录。"
        case .invalidExecutable: "Mole 路径不在已知安装位置，请重新检测。"
        case .invalidResponse(let context): "Mole 返回的\(context)格式不正确，无法显示结果。"
        case .launchFailed(let detail): "无法启动 Mole：\(Self.safeDiagnostic(detail))"
        case .processFailed(let status, let detail): "Mole 查询失败（退出码 \(status)）。\(Self.safeDiagnostic(detail))"
        case .timedOut: "Mole 查询超时，请缩小查询范围后重试。"
        case .outputFailed: "无法完整读取 Mole 的查询结果。"
        }
    }

    static func safeDiagnostic(_ text: String) -> String {
        let noANSI = text.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        let scalars = noANSI.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
        return String(String.UnicodeScalarView(scalars)).prefix(2000).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

internal enum MoleParser {
    static func applications(_ data: Data) throws -> [MoleApplication] {
        do { return try JSONDecoder().decode([MoleApplication].self, from: data) }
        catch { throw MoleError.invalidResponse("应用列表") }
    }

    static func diskReport(_ data: Data) throws -> MoleDiskReport {
        do { return try JSONDecoder().decode(MoleDiskReport.self, from: data) }
        catch { throw MoleError.invalidResponse("磁盘信息") }
    }

    static func version(_ data: Data) throws -> String {
        let text = MoleError.safeDiagnostic(String(decoding: data, as: UTF8.self))
        let pattern = #"(?m)^Mole(?: version)?\s+v?([0-9]+\.[0-9]+\.[0-9]+)\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { throw MoleError.invalidVersion }
        return String(text[range])
    }
}
