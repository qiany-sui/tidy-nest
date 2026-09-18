import Foundation

public struct MoleService: Sendable {
    private let candidates: [URL]
    private let runner = ProcessRunner()

    public init() {
        candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/mole"),
            URL(fileURLWithPath: "/usr/local/bin/mole"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/mole"),
            MoleInstaller.managedExecutable
        ]
    }

    internal init(candidates: [URL]) { self.candidates = candidates }

    public func detect() async throws -> MoleInstallation {
        try Task.checkCancellation()
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw MoleError.notInstalled
        }
        let output = try await runner.run(executableURL: executable, arguments: ["--version"], timeout: 10)
        return MoleInstallation(executableURL: executable, version: try MoleParser.version(output.stdout))
    }

    public func applications(using installation: MoleInstallation) async throws -> [MoleApplication] {
        try await validate(installation)
        let output = try await runner.run(executableURL: installation.executableURL, arguments: ["uninstall", "--list"], timeout: 60)
        try Task.checkCancellation()
        return try MoleParser.applications(output.stdout)
    }

    public func analyze(directory: URL, using installation: MoleInstallation) async throws -> MoleDiskReport {
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
              !directory.path.contains("\0"),
              FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MoleError.invalidDirectory
        }
        try await validate(installation)
        let output = try await runner.run(executableURL: installation.executableURL, arguments: ["analyze", "--json", directory.path], timeout: 120)
        try Task.checkCancellation()
        let report = try MoleParser.diskReport(output.stdout)
        guard report.path.hasPrefix("/"),
              URL(fileURLWithPath: report.path).standardizedFileURL.resolvingSymlinksInPath() == directory.standardizedFileURL.resolvingSymlinksInPath() else {
            throw MoleError.invalidResponse("目录路径")
        }
        return report
    }

    private func validate(_ installation: MoleInstallation) async throws {
        try Task.checkCancellation()
        guard installation.isSupported else { throw MoleError.unsupportedVersion(installation.version) }
        guard installation.executableURL.isFileURL,
              candidates.contains(where: { $0.standardizedFileURL == installation.executableURL.standardizedFileURL }) else {
            throw MoleError.invalidExecutable
        }
        // 检测结果可能在外部升级后过期；每次查询前重新核对实际可执行文件。
        let output = try await runner.run(executableURL: installation.executableURL, arguments: ["--version"], timeout: 10)
        let actualVersion = try MoleParser.version(output.stdout)
        guard MoleInstallation.supportedVersions.contains(actualVersion) else { throw MoleError.unsupportedVersion(actualVersion) }
    }
}
