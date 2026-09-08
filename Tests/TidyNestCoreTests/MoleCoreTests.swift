import Foundation
import Testing
import Darwin
@testable import TidyNestCore

@Suite(.serialized)
struct MoleCoreTests {
    @Test func diskAllowsMissingLargeFiles() throws {
        let report = try MoleParser.diskReport(Data(#"{"path":"/tmp/example","overview":false,"entries":[{"name":"notes.txt","path":"/tmp/example/notes.txt","size":12,"is_dir":false}],"total_size":12,"total_files":1}"#.utf8))
        #expect(report.largeFiles.isEmpty)
        #expect(report.entries.first?.size == 12)
        #expect(report.totalFiles == 1)
    }

    @Test func emptyDiskDefaultsOmittedFileCountToZero() throws {
        let report = try MoleParser.diskReport(Data(#"{"path":"/tmp/empty","overview":false,"entries":[],"total_size":0}"#.utf8))
        #expect(report.totalFiles == 0)
        #expect(report.entries.isEmpty)
    }

    @Test func largeFileRecordsDoNotRequireDirectoryFlag() throws {
        let report = try MoleParser.diskReport(Data(#"{"path":"/tmp/large","overview":false,"entries":[{"name":"large.bin","path":"/tmp/large/large.bin","size":2097152,"is_dir":false}],"large_files":[{"name":"large.bin","path":"/tmp/large/large.bin","size":2097152}],"total_size":2097152,"total_files":1}"#.utf8))
        #expect(report.largeFiles.first?.size == 2097152)
        #expect(report.largeFiles.first?.isDirectory == false)
        #expect(throws: MoleError.self) {
            try MoleParser.diskReport(Data(#"{"path":"/tmp/invalid","overview":false,"entries":[{"name":"missing-flag","path":"/tmp/invalid/missing-flag","size":0}],"total_size":0}"#.utf8))
        }
    }

    @Test func diskRejectsMalformedMissingAndNegativeFields() {
        for json in ["not JSON", "{}", #"{"error":"permission denied"}"#, #"{"path":"/tmp","overview":false,"entries":[],"total_size":-1,"total_files":0}"#] {
            #expect(throws: MoleError.self) { try MoleParser.diskReport(Data(json.utf8)) }
        }
    }

    @Test func applicationIdentityUsesPathAndUnknownSizeStaysUnknown() throws {
        let apps = try MoleParser.applications(Data(#"[{"name":"Example","bundle_id":"com.example.app","source":"App","uninstall_name":"Example","path":"/Applications/Example.app","size":"24 MB"},{"name":"Example","bundle_id":"com.example.app","source":"App","uninstall_name":"Example","path":"/Users/example/Applications/Example.app","size":"N/A"}]"#.utf8))
        #expect(Set(apps.map(\.id)).count == 2)
        #expect(apps[1].displaySize == "N/A")
        #expect(throws: MoleError.self) { try MoleParser.applications(Data(#"[{"name":"incomplete"}]"#.utf8)) }
        #expect(throws: MoleError.self) { try MoleParser.applications(Data(#"{"error":"denied"}"#.utf8)) }
    }

    @Test func parsesOnlyRecognizableVersionOutput() throws {
        #expect(try MoleParser.version(Data("\nMole version 1.53.0\nmacOS: 15.5\nArchitecture: arm64\n".utf8)) == "1.53.0")
        #expect(throws: MoleError.self) { try MoleParser.version(Data("error 1.53.0 failed".utf8)) }
    }

    @Test func processPreservesLiteralArguments() async throws {
        let literal = "a space 'quote' ; $(touch should-never-exist) 中文"
        let output = try await ProcessRunner().run(executableURL: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", literal], timeout: 3)
        #expect(String(decoding: output.stdout, as: UTF8.self) == literal)
    }

    @Test func processDrainsBothLargePipes() async throws {
        let fixture = try ScriptFixture("/usr/bin/awk 'BEGIN { for (i=0;i<20000;i++) { print \"stdout-line-0123456789\"; print \"stderr-line-0123456789\" > \"/dev/stderr\" } }'")
        defer { fixture.remove() }
        let output = try await ProcessRunner().run(executableURL: fixture.script, arguments: [], timeout: 5)
        #expect(output.stdout.count == 460000)
        #expect(output.stderr.count == 460000)
    }

    @Test func processFindsCompanionToolWithoutShellStartupFiles() async throws {
        let fixture = try ScriptFixture("tidynest-isolated-helper")
        defer { fixture.remove() }
        let helper = fixture.directory.appendingPathComponent("tidynest-isolated-helper")
        try Data("#!/bin/sh\nprintf companion-found".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let output = try await ProcessRunner().run(executableURL: fixture.script, arguments: [], timeout: 3)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "companion-found")
    }

    @Test func nonzeroExitUsesSanitizedStderr() async throws {
        let fixture = try ScriptFixture("printf '\\033[31mdenied\\033[0m\\007' >&2; exit 7")
        defer { fixture.remove() }
        do {
            _ = try await ProcessRunner().run(executableURL: fixture.script, arguments: [], timeout: 3)
            Issue.record("非零退出不能当成成功")
        } catch let error as MoleError {
            guard case .processFailed(let status, let diagnostic) = error else { Issue.record("错误类型不正确"); return }
            #expect(status == 7)
            #expect(diagnostic.contains("denied"))
            #expect(!diagnostic.contains("\u{1b}"))
            #expect(!diagnostic.contains("\u{7}"))
        }
    }

    @Test func timeoutStopsProcessAndDescendant() async throws {
        let fixture = try ScriptFixture("echo $$ > \"$1/parent\"; /bin/sleep 30 & child=$!; echo $child > \"$1/child\"; wait")
        defer { fixture.remove() }
        do {
            _ = try await ProcessRunner().run(executableURL: fixture.script, arguments: [fixture.directory.path], timeout: 1)
            Issue.record("应报告超时")
        } catch let error as MoleError {
            guard case .timedOut = error else { Issue.record("应报告超时，实际 \(error)"); return }
        }
        try await assertStopped(fixture)
    }

    @Test func cancellationStopsProcessAndDescendant() async throws {
        let fixture = try ScriptFixture("echo $$ > \"$1/parent\"; /bin/sleep 30 & child=$!; echo $child > \"$1/child\"; wait")
        defer { fixture.remove() }
        let task = Task { try await ProcessRunner().run(executableURL: fixture.script, arguments: [fixture.directory.path], timeout: 5) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("child").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("应取消") } catch is CancellationError {} catch { Issue.record("取消类型错误：\(error)") }
        try await assertStopped(fixture)
    }

    @Test func cancellationBeforeStartDoesNotLaunchProcess() async throws {
        let fixture = try ScriptFixture("echo launched > \"$1/launched\"")
        defer { fixture.remove() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner().run(executableURL: fixture.script, arguments: [fixture.directory.path], timeout: 3)
        }
        do { _ = try await task.value; Issue.record("应取消") } catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("launched").path))
    }

    @Test func timeoutKillsChildHoldingPipeAfterParentExits() async throws {
        let fixture = try ScriptFixture("echo $$ > \"$1/parent\"; /bin/sleep 30 & echo $! > \"$1/child\"; exit 0")
        defer { fixture.remove() }
        do {
            _ = try await ProcessRunner().run(executableURL: fixture.script, arguments: [fixture.directory.path], timeout: 1)
            Issue.record("子进程持有管道应触发超时")
        } catch let error as MoleError {
            guard case .timedOut = error else { Issue.record("超时类型错误"); return }
        }
        try await assertStopped(fixture)
    }

    @Test func timeoutEscalatesWhenProcessIgnoresTermination() async throws {
        let fixture = try ScriptFixture("trap '' TERM; echo $$ > \"$1/parent\"; /bin/sleep 30 & echo $! > \"$1/child\"; wait")
        defer { fixture.remove() }
        do {
            _ = try await ProcessRunner().run(executableURL: fixture.script, arguments: [fixture.directory.path], timeout: 1)
            Issue.record("应超时")
        } catch let error as MoleError {
            guard case .timedOut = error else { Issue.record("超时类型错误"); return }
        }
        try await assertStopped(fixture)
    }

    @Test func launchFailureIsReported() async {
        do {
            _ = try await ProcessRunner().run(executableURL: URL(fileURLWithPath: "/does/not/exist"), arguments: [], timeout: 1)
            Issue.record("缺失程序不应启动成功")
        } catch let error as MoleError {
            guard case .launchFailed = error else { Issue.record("应报告启动失败"); return }
        } catch { Issue.record("错误类型不正确") }
    }

    @Test func serviceDetectsAndUsesOnlyReadOnlyQueries() async throws {
        let fixture = try ScriptFixture(#"""
        if [ "$#" = 1 ] && [ "$1" = --version ]; then
          printf 'Mole version 1.53.0\n'
        elif [ "$#" = 2 ] && [ "$1" = uninstall ] && [ "$2" = --list ]; then
          printf '[{"name":"Example","bundle_id":"com.example","source":"App","uninstall_name":"Example","path":"/Applications/Example.app","size":"N/A"}]'
        elif [ "$#" = 3 ] && [ "$1" = analyze ] && [ "$2" = --json ]; then
          printf '%s' "$3" > "${0%/*}/received-directory"
          /bin/cat "${0}.report"
        else
          exit 99
        fi
        """#)
        defer { fixture.remove() }
        let service = MoleService(candidates: [URL(fileURLWithPath: "/does/not/exist"), fixture.script])
        let installation = try await service.detect()
        #expect(installation.isSupported)
        #expect(installation.executableURL == fixture.script)
        let apps = try await service.applications(using: installation)
        #expect(apps.first?.name == "Example")
        let directory = fixture.directory.appendingPathComponent("目录 'quote' ; $literal")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportJSON: [String: Any] = ["path": directory.path, "overview": false, "entries": [], "total_size": 0, "total_files": 0]
        try JSONSerialization.data(withJSONObject: reportJSON).write(to: URL(fileURLWithPath: fixture.script.path + ".report"))
        let report = try await service.analyze(directory: directory, using: installation)
        #expect(report.totalFiles == 0)
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("received-directory"), encoding: .utf8) == directory.path)
    }

    @Test func queriesRejectExecutableOutsideDetectionCandidates() async throws {
        let fixture = try ScriptFixture(#"""
        printf launched > "${0}.launched"
        if [ "$1" = --version ]; then printf 'Mole version 1.53.0\n'; else printf '[]'; fi
        """#)
        defer { fixture.remove() }
        let installation = MoleInstallation(executableURL: fixture.script, version: "1.53.0")
        do {
            _ = try await MoleService(candidates: []).applications(using: installation)
            Issue.record("候选目录以外的程序应拒绝启动")
        } catch is MoleError {}
        #expect(!FileManager.default.fileExists(atPath: fixture.script.path + ".launched"))
    }

    @Test func processIgnoresInheritedAnalyzePath() async throws {
        let fixture = try ScriptFixture("printf '%s' \"${MO_ANALYZE_PATH-unset}\"")
        defer { fixture.remove() }
        let previous = ProcessInfo.processInfo.environment["MO_ANALYZE_PATH"]
        setenv("MO_ANALYZE_PATH", fixture.directory.path, 1)
        defer {
            if let previous { setenv("MO_ANALYZE_PATH", previous, 1) }
            else { unsetenv("MO_ANALYZE_PATH") }
        }
        let output = try await ProcessRunner().run(executableURL: fixture.script, arguments: [], timeout: 3)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "unset")
    }

    @Test func analyzeRejectsReportForAnotherDirectory() async throws {
        let fixture = try ScriptFixture(#"""
        if [ "$1" = --version ]; then
          printf 'Mole version 1.53.0\n'
        else
          printf '{"path":"/tmp/wrong-directory","overview":false,"entries":[],"total_size":0,"total_files":0}'
        fi
        """#)
        defer { fixture.remove() }
        let service = MoleService(candidates: [fixture.script])
        let installation = try await service.detect()
        do {
            _ = try await service.analyze(directory: fixture.directory, using: installation)
            Issue.record("返回路径与选择目录不一致时不能显示成功")
        } catch is MoleError {}
    }

    @Test func queryRechecksVersionAfterInstallationChanges() async throws {
        let fixture = try ScriptFixture(#"""
        if [ "$1" = --version ]; then
          /bin/cat "${0}.version"
        else
          printf queried > "${0}.queried"
          printf '[]'
        fi
        """#)
        defer { fixture.remove() }
        let versionFile = URL(fileURLWithPath: fixture.script.path + ".version")
        try Data("Mole version 1.53.0\n".utf8).write(to: versionFile)
        let service = MoleService(candidates: [fixture.script])
        let installation = try await service.detect()
        try Data("Mole version 1.54.0\n".utf8).write(to: versionFile)
        do {
            _ = try await service.applications(using: installation)
            Issue.record("检测后版本变化应阻止查询")
        } catch let error as MoleError {
            guard case .unsupportedVersion = error else { Issue.record("应报告版本未验证"); return }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.script.path + ".queried"))
    }

    @Test func detectMissingInstallationIsActionable() async {
        do { _ = try await MoleService(candidates: [URL(fileURLWithPath: "/does/not/exist")]).detect(); Issue.record("应报告未安装") }
        catch let error as MoleError { guard case .notInstalled = error else { Issue.record("错误类型不正确"); return } }
        catch { Issue.record("错误类型不正确") }
    }

    @Test func unsupportedVersionPreventsExecution() async throws {
        let installation = MoleInstallation(executableURL: URL(fileURLWithPath: "/does/not/exist"), version: "1.54.0")
        do { _ = try await MoleService().applications(using: installation); Issue.record("未知版本应拒绝查询") }
        catch let error as MoleError { guard case .unsupportedVersion = error else { Issue.record("应在启动进程前拒绝未知版本"); return } }
    }

    @Test func analyzeRejectsNonFileURL() async throws {
        let installation = MoleInstallation(executableURL: URL(fileURLWithPath: "/does/not/exist"), version: "1.53.0")
        do { _ = try await MoleService().analyze(directory: URL(string: "https://example.com")!, using: installation); Issue.record("只接受本地目录") }
        catch let error as MoleError { guard case .invalidDirectory = error else { Issue.record("应先校验目录"); return } }
    }
}

private struct ScriptFixture: Sendable {
    let directory: URL
    let script: URL
    init(_ body: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent("work/core-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("fixture.sh")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func assertStopped(_ fixture: ScriptFixture) async throws {
    for name in ["parent", "child"] {
        let text = try String(contentsOf: fixture.directory.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(text))
        for _ in 0..<100 { if kill(pid, 0) != 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) == -1, "本任务进程 \(name) 应已退出")
    }
}
