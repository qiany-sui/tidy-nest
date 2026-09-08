import Foundation
import Testing
import Darwin
@testable import TidyNestCore

struct ApplicationRefreshServiceTests {
    @Test func refreshesSelectedUnicodeApplicationWithoutReadingSiblingApps() async throws {
        let fixture = try ApplicationRefreshFixture()
        let service = ApplicationRefreshService()
        let first = try await service.refresh(fixture.application)
        #expect(first.name == "新的·测试 应用")
        #expect(first.bundleIdentifier == "com.example.Refreshed")
        #expect(first.path == fixture.app.path)
        #expect(first.source == fixture.application.source)
        #expect(first.uninstallName == fixture.application.uninstallName)
        #expect(!first.displaySize.isEmpty && first.displaySize != "未知")
        #expect(first.displaySize != fixture.application.displaySize)

        let sibling = fixture.directory.appendingPathComponent("旁边的损坏应用.app")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4 * 1024 * 1024).write(to: sibling.appendingPathComponent("large.bin"))
        #expect(chmod(sibling.path, 0) == 0)
        defer { chmod(sibling.path, 0o700) }
        let refreshed = try await service.refresh(fixture.application)
        #expect(refreshed == first)
        #expect(try Data(contentsOf: fixture.info) == fixture.metadata)
    }

    @Test func doesNotCountTargetsOfLinksInsideTheSelectedApplication() async throws {
        let fixture = try ApplicationRefreshFixture()
        let outside = fixture.directory.appendingPathComponent("outside.bin")
        try Data("small".utf8).write(to: outside)
        let link = fixture.app.appendingPathComponent("Contents/external-data")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let service = ApplicationRefreshService()
        let first = try await service.refresh(fixture.application)
        let changed = Data(repeating: 8, count: 4 * 1024 * 1024)
        try changed.write(to: outside)
        let second = try await service.refresh(fixture.application)
        #expect(second.displaySize == first.displaySize)
        #expect(try Data(contentsOf: outside) == changed)
    }

    @Test(arguments: ["missing", "corrupt", "no-id", "blank-id", "oversized", "linked"])
    func rejectsUnreadableOrInvalidMetadata(_ kind: String) async throws {
        let fixture = try ApplicationRefreshFixture()
        switch kind {
        case "missing": try FileManager.default.removeItem(at: fixture.info)
        case "corrupt": try Data("not a plist".utf8).write(to: fixture.info)
        case "no-id": try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "No ID"], format: .binary, options: 0).write(to: fixture.info)
        case "blank-id": try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "   "], format: .binary, options: 0).write(to: fixture.info)
        case "oversized": try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.large", "Padding": String(repeating: "x", count: 1024 * 1024 + 1)], format: .binary, options: 0).write(to: fixture.info)
        default:
            let outside = fixture.directory.appendingPathComponent("outside.plist")
            try fixture.metadata.write(to: outside)
            try FileManager.default.removeItem(at: fixture.info)
            try FileManager.default.createSymbolicLink(at: fixture.info, withDestinationURL: outside)
        }
        await #expect(throws: (any Error).self) { try await ApplicationRefreshService().refresh(fixture.application) }
    }

    @Test func wrapperReportsCurrentSupportLimitInsteadOfMissingApplication() async throws {
        let fixture = try ApplicationRefreshFixture()
        try FileManager.default.removeItem(at: fixture.info)
        let payload = fixture.app.appendingPathComponent("Wrapper/CloudGame.app")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try fixture.metadata.write(to: payload.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: fixture.app.appendingPathComponent("WrappedBundle").path, withDestinationPath: "Wrapper/CloudGame.app")
        do {
            _ = try await ApplicationRefreshService().refresh(fixture.application)
            Issue.record("包装应用应说明当前不支持单项刷新")
        } catch {
            #expect(error.localizedDescription.contains("iPhone/iPad"))
            #expect(error.localizedDescription.contains("暂不支持"))
            #expect(!error.localizedDescription.contains("已缺失"))
        }
    }

    @Test func rejectsMissingApplicationAndTopLevelLink() async throws {
        let fixture = try ApplicationRefreshFixture()
        let missing = fixture.directory.appendingPathComponent("Missing.app")
        await #expect(throws: (any Error).self) { try await ApplicationRefreshService().refresh(fixture.application(at: missing.path)) }
        let link = fixture.directory.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.app)
        await #expect(throws: (any Error).self) { try await ApplicationRefreshService().refresh(fixture.application(at: link.path)) }
        #expect(try Data(contentsOf: fixture.info) == fixture.metadata)
    }

    @Test(arguments: ["relative.app", "/Applications/../Example.app", "/Applications/./Example.app", "/Applications//Example.app", "/Applications/Example", "/Applications/Bad\0.app"])
    func rejectsNonstandardApplicationPaths(_ path: String) async throws {
        let fixture = try ApplicationRefreshFixture()
        await #expect(throws: (any Error).self) { try await ApplicationRefreshService().refresh(fixture.application(at: path)) }
    }

    @Test func cancellationBeforeRefreshDoesNotReadTheApplication() async throws {
        let fixture = try ApplicationRefreshFixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ApplicationRefreshService().refresh(fixture.application(at: "/does/not/exist.app"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellationDuringSizeQueryStopsItsProcess() async throws {
        let fixture = try ApplicationRefreshFixture()
        let executable = try fixture.script(#"""
        echo $$ > "$2/Contents/du-pid"
        exec /bin/sleep 30
        """#)
        let service = ApplicationRefreshService(duExecutable: executable, timeout: 10)
        let task = Task { try await service.refresh(fixture.application) }
        do {
            let marker = fixture.app.appendingPathComponent("Contents/du-pid")
            var startedPID: Int32?
            // 并行套件中的新脚本启动曾超过一秒；以完整 PID 作为取消前的就绪条件。
            for _ in 0..<500 {
                if let text = try? String(contentsOf: marker, encoding: .utf8),
                   let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    startedPID = pid
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let pid = startedPID else {
                task.cancel()
                let result = await task.result
                Issue.record("体积查询未到达取消测试的就绪点，实际任务结果：\(result)")
                return
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(kill(pid, 0) == -1 && errno == ESRCH)
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
    }

    @Test(arguments: ["malformed", "warning", "failed"])
    func incompleteSizeOutputDoesNotBecomeZero(_ kind: String) async throws {
        let fixture = try ApplicationRefreshFixture()
        let body: String
        let expectedReason: String
        switch kind {
        case "malformed": body = "printf 'not a size\\n'"; expectedReason = "无法识别"
        case "warning": body = "printf '0\\t%s\\n' \"$2\"; printf denied >&2"; expectedReason = "未能完整读取"
        default: body = "printf '0\\t%s\\n' \"$2\"; exit 1"; expectedReason = "未能完整统计"
        }
        let service = ApplicationRefreshService(duExecutable: try fixture.script(body), timeout: 3)
        do {
            _ = try await service.refresh(fixture.application)
            Issue.record("不完整体积不能作为零值发布")
        } catch {
            #expect(error.localizedDescription.contains(expectedReason))
        }
    }

    @Test func sizeQueryTimeoutIsReported() async throws {
        let fixture = try ApplicationRefreshFixture()
        let service = ApplicationRefreshService(duExecutable: try fixture.script("exec /bin/sleep 30"), timeout: 0.05)
        do {
            _ = try await service.refresh(fixture.application)
            Issue.record("体积查询超时不能返回旧值或零值")
        } catch {
            #expect(error.localizedDescription.contains("超时"))
        }
    }

    @Test func metadataChangedDuringSizeQueryDoesNotPublishMixedInformation() async throws {
        let fixture = try ApplicationRefreshFixture()
        let executable = try fixture.script(#"""
        printf changed > "$2/Contents/Info.plist"
        printf '4\t%s\n' "$2"
        """#)
        let service = ApplicationRefreshService(duExecutable: executable, timeout: 3)
        do {
            _ = try await service.refresh(fixture.application)
            Issue.record("刷新期间元数据变化不能发布混合信息")
        } catch {
            #expect(error.localizedDescription.contains("发生变化"))
        }
        #expect(try Data(contentsOf: fixture.info) == Data("changed".utf8))
    }
}

private struct ApplicationRefreshFixture {
    let directory: URL
    let app: URL
    let info: URL
    let metadata: Data
    var application: MoleApplication { application(at: app.path) }

    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent("work/application-refresh-tests/\(UUID().uuidString)")
        app = directory.appendingPathComponent("中文·空格 App.app")
        info = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        metadata = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.Refreshed", "CFBundleDisplayName": "新的·测试 应用", "CFBundleName": "Fallback"], format: .binary, options: 0)
        try metadata.write(to: info)
        try Data(repeating: 4, count: 64 * 1024).write(to: app.appendingPathComponent("Contents/payload.bin"))
    }

    func application(at path: String) -> MoleApplication {
        MoleApplication(name: "Old", bundleIdentifier: "unknown", source: "App", uninstallName: "old-uninstall-name", path: path, displaySize: "未知")
    }

    func script(_ body: String) throws -> URL {
        let executable = directory.appendingPathComponent("du-fixture.sh")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}
