import Foundation
import Testing
@testable import TidyNestCore

// 显式启用才联网，目标始终是项目内新建目录，不修改用户的现有 Mole。
@Test(.enabled(if: ProcessInfo.processInfo.environment["TIDYNEST_VERIFY_MOLE_INSTALL"] == "1"))
func officialMoleInstallsAndRunsFromPublishedDirectory() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("work/mole-install-integration/\(UUID().uuidString)")
    let managed = root.appendingPathComponent("managed")
    let executable = managed.appendingPathComponent("1.53.0/mole")
    let service = MoleService(candidates: [executable])
    let installer = MoleInstaller(directory: managed, detect: { try await service.detect() })
    let installed = try await installer.install { phase in print("Mole 安装验收：\(phase.message)") }
    #expect(installed.executableURL == executable)
    #expect(try await service.detect() == installed)

    let empty = root.appendingPathComponent("中文 空目录")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let report = try await service.analyze(directory: empty, using: installed)
    #expect(report.entries.isEmpty)
    #expect(try await installer.install { _ in } == installed)
    #expect(try FileManager.default.contentsOfDirectory(atPath: managed.path).allSatisfy { !$0.hasPrefix(".install-") })
    print("Mole 真实安装与目录查询通过：\(executable.path)")
}
