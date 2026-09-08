import CryptoKit
import Foundation
import Testing
@testable import TidyNestCore

@Suite(.serialized)
struct MoleInstallerTests {
    @Test func publishesCompleteInstallationWithoutChangingExistingFiles() async throws {
        let fixture = try await InstallerFixture()
        let result = try await fixture.installer().install { _ in }
        #expect(result.version == "1.53.0")
        #expect(result.executableURL == fixture.root.appendingPathComponent("managed/1.53.0/mole"))
        #expect(try String(contentsOf: fixture.sentinel, encoding: .utf8) == "existing user content")
        #expect(FileManager.default.isExecutableFile(atPath: result.executableURL.deletingLastPathComponent().appendingPathComponent("bin/analyze-go").path))
        #expect(!fixture.hasStaging())
        let detected = try await MoleService(candidates: [result.executableURL]).detect()
        #expect(detected == result)
    }

    @Test func checksumMismatchNeverExecutesOrPublishesPayload() async throws {
        let fixture = try await InstallerFixture()
        let installer = fixture.installer(sourceDigest: String(repeating: "0", count: 64))
        await #expect(throws: MoleInstallError.self) { try await installer.install { _ in } }
        #expect(!FileManager.default.fileExists(atPath: fixture.executionMarker.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("managed/1.53.0").path))
        #expect(!fixture.hasStaging())
    }

    @Test func existingMoleIsDetectedWithoutDownloadingOrOverwriting() async throws {
        let fixture = try await InstallerFixture()
        let existing = MoleInstallation(executableURL: fixture.root.appendingPathComponent("existing-mole"), version: "9.0.0")
        let installer = fixture.installer(detect: { existing }, download: { _, _ in
            Issue.record("存在 Mole 时不应下载或降级")
            throw MoleInstallError.download("unexpected")
        })
        #expect(try await installer.install { _ in } == existing)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("managed").path))
    }

    @Test func detectionFailureDoesNotBecomePermissionToInstall() async throws {
        let fixture = try await InstallerFixture()
        let installer = fixture.installer(detect: { throw MoleError.invalidVersion }, download: { _, _ in
            Issue.record("检测错误不能当作未安装")
            throw MoleInstallError.download("unexpected")
        })
        await #expect(throws: MoleError.self) { try await installer.install { _ in } }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("managed").path))
    }

    @Test func downloadFailureAndWrongVersionLeaveNoPublishedInstallation() async throws {
        let failed = try await InstallerFixture()
        await #expect(throws: MoleInstallError.self) {
            try await failed.installer(download: { _, _ in throw MoleInstallError.download("fixture offline") }).install { _ in }
        }
        #expect(!failed.hasStaging())
        #expect(!FileManager.default.fileExists(atPath: failed.root.appendingPathComponent("managed/1.53.0").path))
        let wrong = try await InstallerFixture(version: "9.0.0")
        await #expect(throws: MoleInstallError.self) { try await wrong.installer().install { _ in } }
        #expect(!wrong.hasStaging())
        #expect(!FileManager.default.fileExists(atPath: wrong.root.appendingPathComponent("managed/1.53.0").path))
    }

    @Test func existingDestinationAndSymlinkParentsArePreserved() async throws {
        let fixture = try await InstallerFixture()
        let destination = fixture.root.appendingPathComponent("managed/1.53.0")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        await #expect(throws: MoleInstallError.self) { try await fixture.installer().install { _ in } }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")

        let linked = try await InstallerFixture()
        let outside = linked.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linked.root.appendingPathComponent("managed"), withDestinationURL: outside)
        await #expect(throws: MoleInstallError.self) { try await linked.installer().install { _ in } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func cancellationAndLockKeepOtherInstallerOutAndAllowRetry() async throws {
        let fixture = try await InstallerFixture()
        let gate = InstallerDownloadGate()
        let installer = fixture.installer(download: { _, _ in
            await gate.started()
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        })
        let first = Task { try await installer.install { _ in } }
        await gate.waitUntilStarted()
        await #expect(throws: MoleInstallError.self) { try await fixture.installer().install { _ in } }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(!fixture.hasStaging())
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("managed/1.53.0").path))
        #expect(try await fixture.installer().install { _ in }.isSupported)
    }

    @Test func cancellationBeforeStartCreatesNoFiles() async throws {
        let fixture = try await InstallerFixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.installer().install { _ in }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("managed").path))
    }
}

private struct InstallerFixture: Sendable {
    let root: URL
    let sourceData: Data
    let helperData = Data("#!/bin/bash\nexit 0\n".utf8)
    var sentinel: URL { root.appendingPathComponent("unrelated.txt") }
    var executionMarker: URL { root.appendingPathComponent("payload-executed") }

    init(version: String = "1.53.0") async throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/mole-installer-tests/\(UUID().uuidString)")
        let source = root.appendingPathComponent("source/Mole-1.53.0")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("lib/core"), withIntermediateDirectories: true)
        let script = "#!/bin/bash\nprintf executed > '\(root.path)/payload-executed'\nprintf 'Mole version \(version)\\n'\n"
        try Data(script.utf8).write(to: source.appendingPathComponent("mole"))
        for name in ["mo", "bin/analyze.sh", "bin/status.sh", "bin/uninstall.sh", "lib/core/common.sh", "README.md", "LICENSE"] {
            try Data("fixture\n".utf8).write(to: source.appendingPathComponent(name))
        }
        try Data("existing user content".utf8).write(to: root.appendingPathComponent("unrelated.txt"))
        let archive = root.appendingPathComponent("source.tar.gz")
        _ = try await ProcessRunner().run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-czf", archive.path, "-C", source.deletingLastPathComponent().path, "Mole-1.53.0"], timeout: 10)
        sourceData = try Data(contentsOf: archive)
    }

    func installer(
        sourceDigest: String? = nil,
        detect: @escaping @Sendable () async throws -> MoleInstallation = { throw MoleError.notInstalled },
        download: (@Sendable (URL, URL) async throws -> Void)? = nil
    ) -> MoleInstaller {
        let sourceURL = URL(string: "https://example.invalid/source.tar.gz")!
        let helperURL = URL(string: "https://example.invalid/helper")!
        let artifacts = [
            MoleInstallArtifact(url: sourceURL, sha256: sourceDigest ?? digest(sourceData)),
            MoleInstallArtifact(url: helperURL, sha256: digest(helperData)),
            MoleInstallArtifact(url: helperURL, sha256: digest(helperData))
        ]
        return MoleInstaller(directory: root.appendingPathComponent("managed"), artifacts: artifacts, detect: detect, download: download ?? { url, destination in
            try (url == sourceURL ? sourceData : helperData).write(to: destination, options: .withoutOverwriting)
        })
    }

    func hasStaging() -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("managed").path)) ?? []).contains { $0.hasPrefix(".install-") }
    }
}

private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private actor InstallerDownloadGate {
    private var didStart = false
    func started() { didStart = true }
    func waitUntilStarted() async {
        for _ in 0..<1_000 {
            if didStart { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("安装下载未开始")
    }
}
