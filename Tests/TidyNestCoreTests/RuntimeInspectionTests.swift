import Foundation
import Testing
import Darwin
@testable import TidyNestCore

@Suite(.serialized)
struct RuntimeInspectionTests {
    @Test func externalReadOnlyRegularFilesAllowBodyInspection() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try fixture.bundle([
            ["p123", "cQSpace Pro"],
            ["f4", "ar", "l ", "tREG", "n" + fixture.resource.path]
        ])
        try await fixture.inspectBody()
    }

    @Test(arguments: ["write", "read-write", "mapping", "unknown-access", "lock", "cwd", "directory", "missing-process"])
    func unsafeOrUnconfirmedAccessRetainsBodyAndExplainsOwner(_ kind: String) async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let pid = kind == "missing-process" ? "456" : "123"
        let descriptor = kind == "mapping" ? "txt" : (kind == "cwd" ? "cwd" : "4")
        let access = kind == "write" ? "w" : (kind == "read-write" ? "u" : (["mapping", "unknown-access", "cwd"].contains(kind) ? " " : "r"))
        try fixture.bundle([["p" + pid, "cQSpace Pro"], ["f" + descriptor, "a" + access, kind == "lock" ? "lR" : "l ", ["cwd", "directory"].contains(kind) ? "tDIR" : "tREG", "n" + fixture.resource.path]])
        do {
            try await fixture.inspectBody()
            Issue.record("写入、映射、锁和未知进程不能放行")
        } catch let error as MaintenanceError {
            #expect(error.localizedDescription.contains("QSpace Pro"))
            #expect(error.localizedDescription.contains("PID " + pid))
            #expect(error.localizedDescription.contains(fixture.resource.path))
            #expect(error.localizedDescription.contains("重新检查"))
            if kind == "mapping" { #expect(error.localizedDescription.contains("映射")) }
        }
    }

    @Test func readOnlyCacheFileStillRequiresRelease() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try fixture.target([["p123", "cQSpace Pro"], ["f4", "ar", "l ", "tREG", "n" + fixture.cache.path]])
        do {
            try await fixture.service.inspect(applicationPath: fixture.app.path, targetPath: fixture.cache.path)
            Issue.record("缓存文件的只读占用仍然阻止处理")
        } catch let error as MaintenanceError {
            #expect(error.localizedDescription.contains("QSpace Pro"))
            #expect(error.localizedDescription.contains(fixture.cache.path))
            #expect(error.localizedDescription.contains("只读"))
        }
    }

    @Test func laterWriterIsNotHiddenByEarlierReadOnlyRecords() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        var records = [["p123", "cQSpace Pro"]]
        for fd in 4...8 { records.append(["f\(fd)", "ar", "l ", "tREG", "n" + fixture.resource.path]) }
        records += [["p456", "cFixture Writer"], ["f9", "aw", "l ", "tREG", "n" + fixture.resource.path]]
        try fixture.bundle(records)
        do {
            try await fixture.inspectBody()
            Issue.record("不能在见到只读记录或达到显示数量后提前放行")
        } catch let error as MaintenanceError {
            #expect(error.localizedDescription.contains("Fixture Writer"))
            #expect(error.localizedDescription.contains("PID 456"))
            #expect(error.localizedDescription.contains("可写"))
        }
    }

    @Test(arguments: ["no-type", "no-access", "no-lock", "no-command", "duplicate-access", "no-path", "trailing-process", "truncated", "unexpected-field", "out-of-scope", "bad-escape", "nul-escape", "escaped-traversal"])
    func incompleteOrAmbiguousFieldOutputNeverAuthorizesBody(_ variant: String) async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        var process = ["p123", "cQSpace Pro"]
        var file = ["f4", "ar", "l ", "tREG", "n" + fixture.resource.path]
        switch variant {
        case "no-type": file.removeAll { $0.first == "t" }
        case "no-access": file.removeAll { $0.first == "a" }
        case "no-lock": file.removeAll { $0.first == "l" }
        case "no-command": process.removeLast()
        case "duplicate-access": file.append("ar")
        case "no-path": file.removeLast()
        case "unexpected-field": file.append("zunknown")
        case "out-of-scope": file[file.count - 1] = "n" + fixture.cache.path
        case "bad-escape": file[file.count - 1] = "n" + fixture.app.path + "/\\xGG"
        case "nul-escape": file[file.count - 1] = "n" + fixture.app.path + "/\\x00"
        case "escaped-traversal": file[file.count - 1] = "n" + fixture.app.path + "/\\x2e\\x2e/cache.txt"
        default: break
        }
        var data = runtimeFields([process, file])
        if variant == "trailing-process" { data.append(runtimeFields([["p456", "cOther"]])) }
        if variant == "truncated" { data.removeLast(2) }
        try data.write(to: fixture.bundleResponse)
        await #expect(throws: MaintenanceError.self) { try await fixture.inspectBody() }
    }

    @Test(arguments: [false, true])
    func runningApplicationOrOriginalHelperIsNamed(_ original: Bool) async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let origin = "/Applications/Original Fixture.app"
        let executable = (original ? origin : fixture.app.path) + "/Contents/Helpers/Background Helper"
        try Data("321 501 \(executable)\n".utf8).write(to: fixture.psResponse)
        do {
            try await fixture.service.inspect(applicationPath: fixture.app.path, targetPath: fixture.app.path, originalApplicationPath: original ? origin : nil)
            Issue.record("运行中的本体或原位置辅助进程仍需退出")
        } catch let error as MaintenanceError {
            #expect(error.localizedDescription.contains("Background Helper"))
            #expect(error.localizedDescription.contains("PID 321"))
            #expect(error.localizedDescription.contains(executable))
        }
    }

    @Test func newlinesInFileNamesCannotForgeOwnerDetails() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let path = fixture.app.path + "/Contents/Resources/two\nlines.txt"
        try fixture.bundle([["p123", "cQSpace Pro"], ["f4", "aw", "l ", "tREG", "n" + path]])
        do {
            try await fixture.inspectBody()
            Issue.record("可写文件仍应保留")
        } catch let error as MaintenanceError {
            #expect(error.localizedDescription.contains("two\\nlines.txt"))
            #expect(!error.localizedDescription.contains(path))
        }
    }

    @Test func readOnlyDirectoryDescriptorStillPermitsWritingMembersAndMustBlock() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let directory = open(fixture.app.path, O_RDONLY | O_DIRECTORY)
        #expect(directory >= 0)
        defer { if directory >= 0 { close(directory) } }
        let member = openat(directory, "Contents/Resources/fixture.txt", O_WRONLY)
        #expect(member >= 0, "目录句柄的只读标记不能证明成员不可写")
        guard member >= 0 else { return }
        let bytes = Array("changed via directory".utf8)
        #expect(bytes.withUnsafeBytes { write(member, $0.baseAddress, $0.count) } == bytes.count)
        close(member)
        #expect(try String(contentsOf: fixture.resource, encoding: .utf8) == "changed via directory")
        do {
            try await RuntimeInspectionService().inspect(applicationPath: fixture.app.path, targetPath: fixture.app.path)
            Issue.record("成员写句柄已关，但目录句柄仍可重新写入，不能当作只读内容放行")
        } catch let error as MaintenanceError {
            #expect(error.localizedDescription.contains("目录"))
            #expect(error.localizedDescription.contains("PID \(getpid())"))
        }
    }

    @Test(arguments: ["unset", "C", "en_US.UTF-8"])
    func realLsofLocalesPreserveChineseAndLiteralEscapes(_ locale: String) async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let app = fixture.root.appendingPathComponent("中文\\Literal.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let resource = app.appendingPathComponent("literal\\xe4-line\n-tab\t.txt")
        try Data("locale fixture".utf8).write(to: resource)
        let reader = open(resource.path, O_RDONLY)
        #expect(reader >= 0)
        defer { if reader >= 0 { close(reader) } }
        let localeArgument = locale == "unset" ? "" : "LC_ALL=" + locale
        try Data("#!/bin/sh\nexec /usr/bin/env -u LANG -u LC_ALL -u LC_CTYPE \(localeArgument) /usr/sbin/lsof \"$@\"\n".utf8).write(to: fixture.lsof)
        let service = RuntimeInspectionService(psExecutable: URL(fileURLWithPath: "/bin/ps"), lsofExecutable: fixture.lsof)
        try await service.inspect(applicationPath: app.path, targetPath: app.path)
        let writer = open(resource.path, O_WRONLY)
        #expect(writer >= 0)
        defer { if writer >= 0 { close(writer) } }
        do {
            try await service.inspect(applicationPath: app.path, targetPath: app.path)
            Issue.record("转义路径下的可写句柄仍须保留")
        } catch let error as MaintenanceError {
            #expect(error.localizedDescription.contains("中文"))
            #expect(error.localizedDescription.contains("literal\\xe4-line\\n-tab\\t.txt"))
            #expect(error.localizedDescription.contains("PID \(getpid())"))
        }
    }

    @Test func realSystemReadOnlyFileAllowsBodyButWriteDoesNot() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let reader = open(fixture.resource.path, O_RDONLY)
        #expect(reader >= 0)
        defer { if reader >= 0 { close(reader) } }
        try await RuntimeInspectionService().inspect(applicationPath: fixture.app.path, targetPath: fixture.app.path)
        let writer = open(fixture.resource.path, O_RDWR)
        #expect(writer >= 0)
        defer { if writer >= 0 { close(writer) } }
        do {
            try await RuntimeInspectionService().inspect(applicationPath: fixture.app.path, targetPath: fixture.app.path)
            Issue.record("系统实际可写句柄不能通过")
        } catch let error as MaintenanceError {
            #expect(error.localizedDescription.contains("PID \(getpid())"))
            #expect(error.localizedDescription.contains("可写"))
        }
    }
}

private func runtimeFields(_ records: [[String]]) -> Data {
    Data(records.map { $0.joined(separator: "\0") + "\0\n" }.joined().utf8)
}

private struct RuntimeFixture {
    let root: URL
    var app: URL { root.appendingPathComponent("Test.app") }
    var resource: URL { app.appendingPathComponent("Contents/Resources/fixture.txt") }
    var cache: URL { root.appendingPathComponent("cache.txt") }
    var ps: URL { root.appendingPathComponent("ps.sh") }
    var lsof: URL { root.appendingPathComponent("lsof.sh") }
    var psResponse: URL { root.appendingPathComponent("ps.sh.response") }
    var bundleResponse: URL { root.appendingPathComponent("lsof.sh.bundle") }
    var targetResponse: URL { root.appendingPathComponent("lsof.sh.target") }
    var service: RuntimeInspectionService { RuntimeInspectionService(psExecutable: ps, lsofExecutable: lsof) }
    init() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/runtime-inspection-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("runtime fixture".utf8).write(to: resource)
        try Data("cache fixture".utf8).write(to: cache)
        try Data("#!/bin/sh\n/bin/cat \"${0}.response\"\n".utf8).write(to: ps)
        try Data("#!/bin/sh\nfor target in \"$@\"; do :; done\nif [ \"$target\" = \"${0%/*}/Test.app\" ]; then /bin/cat \"${0}.bundle\"; else /bin/cat \"${0}.target\"; fi\nexit 1\n".utf8).write(to: lsof)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ps.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lsof.path)
        try Data("123 501 /Applications/QSpace Pro.app/Contents/MacOS/QSpace Pro\n".utf8).write(to: psResponse)
        try Data().write(to: bundleResponse)
        try Data().write(to: targetResponse)
    }
    func bundle(_ records: [[String]]) throws { try runtimeFields(records).write(to: bundleResponse) }
    func target(_ records: [[String]]) throws { try runtimeFields(records).write(to: targetResponse) }
    func inspectBody() async throws { try await service.inspect(applicationPath: app.path, targetPath: app.path) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
