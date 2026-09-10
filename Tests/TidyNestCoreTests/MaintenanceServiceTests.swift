import Foundation
import Testing
import Darwin
import TidyNestProtocol
@testable import TidyNestCore

@Suite(.serialized)
struct MaintenanceServiceTests {
    @Test func bridgeEarlyResourceFailureProducesOneTerminalEventBeforeAnyAction() async throws {
        let fixture = try BridgeFixture("exit 99")
        defer { fixture.remove() }
        let packaged = fixture.directory.appendingPathComponent("MissingRules.app/Contents/Helpers/TidyNestBridge")
        try FileManager.default.createDirectory(at: packaged.deletingLastPathComponent(), withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: root.appendingPathComponent(".build/debug/TidyNestBridge"), to: packaged)
        let planID = UUID().uuidString
        for (command, request) in [("scan-clean", MaintenanceRequest()), ("plan-uninstall", MaintenanceRequest(appPath: fixture.directory.appendingPathComponent("Example.app").path, expectedBundleID: "com.example.fixture")), ("apply-plan", MaintenanceRequest(planID: planID, selectedItemIDs: [UUID().uuidString], confirmed: true))] {
            let stream = MaintenanceEventStream(onEvent: { _ in })
            let output = try await BridgeProcessRunner().run(executableURL: packaged, command: command, input: MaintenanceJSON.encoder().encode(request), control: BridgeProcessControl(), onOutput: stream.consume)
            let event = try stream.finish()
            #expect(event.schemaVersion == 1)
            #expect(event.sequence == 1)
            #expect(event.type == .result)
            if command == "apply-plan" {
                #expect(event.applyResult?.planID == planID)
                #expect(event.applyResult?.status == .blocked)
                #expect(event.applyResult?.items.isEmpty == true)
                #expect(event.applyResult?.message?.contains("资源缺失") == true)
                #expect(output.exitCode == 3)
            } else {
                #expect(event.error?.contains("资源缺失") == true)
                #expect(output.exitCode == 4)
            }
        }
    }

    @Test func streamHandlesSplitUTF8CombinedEventsAndUnterminatedTail() throws {
        let collector = MaintenanceEventStream(onEvent: { _ in })
        let data = try events([progress(), finalPlan()])
        for byte in data { collector.consume(Data([byte])) }
        let final = try collector.finish()
        #expect(final.plan?.title == "中文清理")
        let combined = MaintenanceEventStream(onEvent: { _ in })
        combined.consume(data)
        #expect(try combined.finish().sequence == 2)
    }

    @Test func streamRejectsBrokenFramingSequenceIdentityAndFinality() throws {
        var skipped = finalPlan(); skipped["sequence"] = 3
        var wrongRun = finalPlan(); wrongRun["runID"] = "other"
        var wrongSchema = progress(); wrongSchema["schemaVersion"] = 2
        for values in [[progress()], [progress(), skipped], [progress(), wrongRun], [wrongSchema, finalPlan()], [progress(), finalPlan(), finalPlan()], [progress(), finalPlan(), progress()]] {
            let collector = MaintenanceEventStream(onEvent: { _ in })
            collector.consume(try events(values))
            #expect(throws: MaintenanceError.self) { try collector.finish() }
        }
        let oversized = MaintenanceEventStream(onEvent: { _ in })
        oversized.consume(Data(repeating: 65, count: 33_554_433))
        #expect(throws: MaintenanceError.self) { try oversized.finish() }
    }

    @Test func largeValidFinalPlanExceedingOneMiBIsAccepted() throws {
        var event = finalPlan()
        var plan = event["plan"] as! [String: Any]
        plan["items"] = (0..<2500).map { index -> [String: Any] in
            ["itemID": "item\(index)", "ruleID": "cache", "path": "/tmp/fixture/cache-\(index)", "displayName": String(repeating: "中文缓存", count: 20), "kind": "file", "action": "trashItem", "reason": String(repeating: "可检查的普通缓存文件", count: 20), "impact": "缓存可能重新生成", "selection": "optional", "dependsOnItemIDs": []]
        }
        event["plan"] = plan
        let data = try events([progress(), event])
        #expect(data.count > 1_048_576)
        let stream = MaintenanceEventStream(onEvent: { _ in })
        stream.consume(data)
        #expect(try stream.finish().plan?.items.count == 2500)
    }

    @Test func oversizedApplyRequestIsBlockedBeforeAnyProcessStarts() async throws {
        let fixture = try BridgeFixture("printf launched > \"${0}.launched\"")
        defer { fixture.remove() }
        let result = try await MaintenanceService(executableURL: fixture.script).apply(planID: "plan", selectedItemIDs: [String(repeating: "x", count: 33_554_432)]) { _ in }
        #expect(result.status == .blocked)
        #expect(!FileManager.default.fileExists(atPath: fixture.script.path + ".launched"))
    }

    @Test func queriesUseStructuredStdinAndLiteralPaths() async throws {
        let fixture = try BridgeFixture("/bin/cat > \"${0}.request\"\nprintf '[\"/tmp/中文\"]'")
        defer { fixture.remove() }
        let literal = "/tmp/中文 'quote' ; $(touch never)"
        try await MaintenanceService(executableURL: fixture.script).protect(path: literal)
        let request = try MaintenanceJSON.decoder().decode(MaintenanceRequest.self, from: Data(contentsOf: URL(fileURLWithPath: fixture.script.path + ".request")))
        #expect(request.protectedPath == literal)
    }

    @Test func scanStreamsAndDrainsStderr() async throws {
        let fixture = try BridgeFixture("/bin/cat > /dev/null\n/usr/bin/awk 'BEGIN { for (i=0;i<20000;i++) print \"diagnostic\" > \"/dev/stderr\" }'\n/bin/cat \"${0}.response\"")
        defer { fixture.remove() }
        try events([progress(), finalPlan()]).write(to: fixture.response)
        let plan = try await MaintenanceService(executableURL: fixture.script).scanClean { _ in }
        #expect(plan.title == "中文清理")
    }

    @Test func shortProgressReachesCallbackBeforeChildCanProduceFinalResult() async throws {
        let fixture = try BridgeFixture(#"""
        /bin/cat > /dev/null
        /bin/cat "${0}.progress"
        attempt=0
        while [ ! -f "${0}.gate" ] && [ "$attempt" -lt 100 ]; do
          /bin/sleep 0.02
          attempt=$((attempt + 1))
        done
        if [ ! -f "${0}.gate" ]; then
          printf 'short-progress-was-not-delivered-before-final\n' >&2
          exit 9
        fi
        /bin/cat "${0}.response"
        """#)
        defer { fixture.remove() }
        try (events([progress()]) + Data([10])).write(to: URL(fileURLWithPath: fixture.script.path + ".progress"))
        try events([finalPlan()]).write(to: fixture.response)
        let gate = URL(fileURLWithPath: fixture.script.path + ".gate")
        do {
            let plan = try await MaintenanceService(executableURL: fixture.script).scanClean { event in
                if event.type == .progress { try? Data("observed".utf8).write(to: gate) }
            }
            #expect(plan.title == "中文清理")
        } catch {
            Issue.record("短 progress 必须在子进程输出 final 前送达回调；fixture 等待约 2 秒后退出，实际：\(error.localizedDescription)")
        }
    }

    @Test func fixtureSendsIndividualUTF8BytesWithoutCorruptingChinese() async throws {
        let fixture = try BridgeFixture("/bin/cat > /dev/null\n/usr/bin/perl -e '$|=1; open my $f, \"<\", $ARGV[0] or die; binmode $f; while (read($f, my $c, 1)) { print $c; select undef, undef, undef, 0.0001; }' \"${0}.response\"")
        defer { fixture.remove() }
        try events([progress(), finalPlan()]).write(to: fixture.response)
        let observed = EventObservation()
        let plan = try await MaintenanceService(executableURL: fixture.script).scanClean { event in observed.append(event) }
        #expect(plan.title == "中文清理")
        #expect(observed.events.map(\.type) == [.progress, .result])
        #expect(observed.events.first?.message == "正在扫描中文目录")
    }

    @Test func missingOrMalformedApplyResultIsUnknownWithoutRetry() async throws {
        for text in ["", "not JSON", String(decoding: try events([progress()]), as: UTF8.self)] {
            let fixture = try BridgeFixture("/bin/cat > \"${0}.request\"\nprintf x >> \"${0}.launches\"\n/bin/cat \"${0}.response\"")
            defer { fixture.remove() }
            try Data(text.utf8).write(to: fixture.response)
            let result = try await MaintenanceService(executableURL: fixture.script).apply(planID: "plan", selectedItemIDs: ["literal '中文' $(echo bad)"]) { _ in }
            #expect(result.status == .unknown)
            #expect(try String(contentsOf: URL(fileURLWithPath: fixture.script.path + ".launches"), encoding: .utf8) == "x")
            let request = try MaintenanceJSON.decoder().decode(MaintenanceRequest.self, from: Data(contentsOf: URL(fileURLWithPath: fixture.script.path + ".request")))
            #expect(request.confirmed == true)
            #expect(request.selectedItemIDs == ["literal '中文' $(echo bad)"])
        }
    }

    @Test func businessExitCodesPreserveApplyResultsAndRejectConflicts() async throws {
        for (status, code, outcomes) in [("completed", 0, ["trashed"]), ("partial", 2, ["trashed", "skipped"]), ("blocked", 3, []), ("failed", 4, ["failed"]), ("unknown", 4, ["unknown"]), ("cancelled", 130, ["cancelled"])] {
            let fixture = try BridgeFixture("/bin/cat > /dev/null\n/bin/cat \"${0}.response\"\nexit \(code)")
            defer { fixture.remove() }
            let ids = outcomes.indices.map { "item\($0)" }
            try events([finalResult(status: status, itemIDs: ids, outcomes: outcomes)]).write(to: fixture.response)
            let result = try await MaintenanceService(executableURL: fixture.script).apply(planID: "plan", selectedItemIDs: ids.isEmpty ? ["not-accepted"] : ids) { _ in }
            #expect(result.status.rawValue == status)
        }
        let fixture = try BridgeFixture("/bin/cat > /dev/null\n/bin/cat \"${0}.response\"\nexit 4")
        defer { fixture.remove() }
        try events([finalResult(status: "completed", itemIDs: ["item"])]).write(to: fixture.response)
        let result = try await MaintenanceService(executableURL: fixture.script).apply(planID: "plan", selectedItemIDs: ["item"]) { _ in }
        #expect(result.status == .unknown)
        #expect(result.message?.contains("退出码") == true)
    }

    @Test func applyBindsFinalItemsToExactlyTheConfirmedSelection() async throws {
        for ids in [[], ["unselected"], ["selected", "extra"]] {
            let fixture = try BridgeFixture("/bin/cat > /dev/null\n/bin/cat \"${0}.response\"")
            defer { fixture.remove() }
            try events([finalResult(status: "completed", itemIDs: ids)]).write(to: fixture.response)
            let result = try await MaintenanceService(executableURL: fixture.script).apply(planID: "plan", selectedItemIDs: ["selected"]) { _ in }
            #expect(result.status == .unknown)
        }
        let fixture = try BridgeFixture("/bin/cat > /dev/null\n/bin/cat \"${0}.response\"")
        defer { fixture.remove() }
        try events([finalResult(status: "completed", itemIDs: ["selected"])]).write(to: fixture.response)
        let valid = try await MaintenanceService(executableURL: fixture.script).apply(planID: "plan", selectedItemIDs: ["selected"]) { _ in }
        #expect(valid.status == .completed)
    }

    @Test func cancellationWaitsForCooperativeApplyResult() async throws {
        let fixture = try BridgeFixture("/bin/cat > /dev/null\ntrap '/bin/cat \"${0}.response\"; exit 130' INT\nprintf ready > \"${0}.ready\"\nwhile :; do /bin/sleep 0.05; done")
        defer { fixture.remove() }
        try events([finalResult(status: "cancelled", itemIDs: ["item"], outcomes: ["cancelled"])]).write(to: fixture.response)
        let service = MaintenanceService(executableURL: fixture.script)
        let task = Task { try await service.apply(planID: "plan", selectedItemIDs: ["item"]) { _ in } }
        try await fixture.waitUntilReady()
        task.cancel()
        let result = try await task.value
        #expect(result.status == .cancelled)
        #expect(result.runID == "run")
    }

    @Test func finalStatusCannotContradictItemOutcomesOrTrashEvidence() async throws {
        for (status, code, outcomes) in [("completed", 0, []), ("completed", 0, ["failed"]), ("partial", 2, ["trashed"]), ("partial", 2, ["failed", "skipped"]), ("failed", 4, ["trashed"]), ("blocked", 3, ["trashed"])] {
            let fixture = try BridgeFixture("/bin/cat > /dev/null\n/bin/cat \"${0}.response\"\nexit \(code)")
            defer { fixture.remove() }
            let ids = outcomes.indices.map { "item\($0)" }
            try events([finalResult(status: status, itemIDs: ids, outcomes: outcomes)]).write(to: fixture.response)
            let result = try await MaintenanceService(executableURL: fixture.script).apply(planID: "plan", selectedItemIDs: ids) { _ in }
            #expect(result.status == .unknown)
        }
        let fixture = try BridgeFixture("/bin/cat > /dev/null\n/bin/cat \"${0}.response\"")
        defer { fixture.remove() }
        var event = finalResult(status: "completed", itemIDs: ["item"])
        var result = event["applyResult"] as! [String: Any]
        var items = result["items"] as! [[String: Any]]
        items[0].removeValue(forKey: "trashPath")
        result["items"] = items
        event["applyResult"] = result
        try events([event]).write(to: fixture.response)
        let unknown = try await MaintenanceService(executableURL: fixture.script).apply(planID: "plan", selectedItemIDs: ["item"]) { _ in }
        #expect(unknown.status == .unknown)
    }

    @Test func cancellationBeforeStartDoesNotLaunchBridge() async throws {
        let fixture = try BridgeFixture("printf launched > \"${0}.launched\"")
        defer { fixture.remove() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MaintenanceService(executableURL: fixture.script).apply(planID: "plan", selectedItemIDs: []) { _ in }
        }
        do { _ = try await task.value; Issue.record("启动前应直接取消") } catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: fixture.script.path + ".launched"))
    }

    @Test func preAcceptanceCancellationAllowsEmptyItemsButCannotEraseEarlierOutcome() async throws {
        let fixture = try BridgeFixture("/bin/cat > /dev/null\n/bin/cat \"${0}.response\"\nexit 130")
        defer { fixture.remove() }
        try events([finalResult(status: "cancelled")]).write(to: fixture.response)
        let service = MaintenanceService(executableURL: fixture.script)
        let result = try await service.apply(planID: "plan", selectedItemIDs: ["item"]) { _ in }
        #expect(result.status == .cancelled)
        let outcome: [String: Any] = ["schemaVersion": 1, "runID": "run", "sequence": 1, "type": "itemResult", "itemResult": ["itemID": "item", "path": "/tmp/fixture/cache", "outcome": "failed"]]
        var final = finalResult(status: "cancelled")
        final["sequence"] = 2
        try events([outcome, final]).write(to: fixture.response)
        let unknown = try await service.apply(planID: "plan", selectedItemIDs: ["item"]) { _ in }
        #expect(unknown.status == .unknown)
        #expect(unknown.items.first?.outcome == .failed)
    }

    @Test func onlyExplicitForceEscalatesToKillAndMissingResultIsUnknown() async throws {
        let fixture = try BridgeFixture("/bin/cat > /dev/null\ntrap '' INT TERM\nprintf ready > \"${0}.ready\"\nwhile :; do /bin/sleep 0.05; done")
        defer { fixture.remove() }
        let service = MaintenanceService(executableURL: fixture.script)
        let task = Task { try await service.apply(planID: "plan", selectedItemIDs: []) { _ in } }
        try await fixture.waitUntilReady()
        task.cancel()
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        service.forceEndCurrentTask()
        let result = try await task.value
        #expect(result.status == .unknown)
        #expect(Date().timeIntervalSince(start) >= 4.9)
    }

    @Test func simultaneousCallsCannotReplaceCurrentProcess() async throws {
        let fixture = try BridgeFixture("/bin/cat > /dev/null\ntrap 'exit 130' INT\nprintf ready > \"${0}.ready\"\nwhile :; do /bin/sleep 0.05; done")
        defer { fixture.remove() }
        let service = MaintenanceService(executableURL: fixture.script)
        let task = Task { try await service.scanClean { _ in } }
        try await fixture.waitUntilReady()
        await #expect(throws: MaintenanceError.self) { try await service.history() }
        task.cancel()
        do { _ = try await task.value; Issue.record("扫描应取消") } catch is CancellationError {}
    }

    @Test func forceStopsPipeHoldingDescendantAfterLeaderExit() async throws {
        let fixture = try BridgeFixture("/bin/cat > /dev/null\n/bin/sleep 30 &\necho $! > \"${0}.child\"\nprintf ready > \"${0}.ready\"\nexit 0")
        defer { fixture.remove() }
        let service = MaintenanceService(executableURL: fixture.script)
        let task = Task { try await service.apply(planID: "plan", selectedItemIDs: []) { _ in } }
        try await fixture.waitUntilReady()
        service.forceEndCurrentTask()
        #expect(try await task.value.status == .unknown)
        let pid = try #require(Int32(try String(contentsOf: URL(fileURLWithPath: fixture.script.path + ".child"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<100 {
            if kill(pid, 0) == -1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(pid, 0) == -1)
    }

    @Test func interruptedStreamPreservesAlreadyReportedItemOutcome() async throws {
        let fixture = try BridgeFixture("/bin/cat > /dev/null\n/bin/cat \"${0}.response\"")
        defer { fixture.remove() }
        let item: [String: Any] = ["itemID": "item", "path": "/tmp/fixture/cache", "outcome": "trashed", "trashPath": "/tmp/fixture/trash/cache", "estimatedBytes": 12]
        let event: [String: Any] = ["schemaVersion": 1, "runID": "run", "sequence": 1, "type": "itemResult", "itemResult": item]
        try events([event]).write(to: fixture.response)
        let result = try await MaintenanceService(executableURL: fixture.script).apply(planID: "plan", selectedItemIDs: ["item"]) { _ in }
        #expect(result.status == .unknown)
        #expect(result.items.first?.outcome == .trashed)
        #expect(result.items.first?.trashPath == "/tmp/fixture/trash/cache")
    }

    @Test func queryRejectsMalformedPathsAndUnsupportedSchema() async throws {
        let fixture = try BridgeFixture("/bin/cat > /dev/null\n/bin/cat \"${0}.response\"")
        defer { fixture.remove() }
        try Data("[\"relative/path\"]".utf8).write(to: fixture.response)
        await #expect(throws: MaintenanceError.self) { try await MaintenanceService(executableURL: fixture.script).protections() }
        try Data("{\"schemaVersion\":2,\"engineVersion\":\"1\",\"engineDigest\":\"digest\",\"rulesVersion\":\"1\",\"supportedRuleIDs\":[],\"supportedActions\":[]}".utf8).write(to: fixture.response)
        await #expect(throws: MaintenanceError.self) { try await MaintenanceService(executableURL: fixture.script).capabilities() }
    }

    @Test func runtimeInspectionRequiresUnambiguousIdleProcessesAndFiles() async throws {
        let ps = try BridgeFixture("printf '123 501 /Applications/Other.app/Contents/MacOS/Other\\n'")
        let lsof = try BridgeFixture("exit 1")
        defer { ps.remove(); lsof.remove() }
        let application = ps.directory.appendingPathComponent("Test.app")
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: false)
        let service = RuntimeInspectionService(psExecutable: ps.script, lsofExecutable: lsof.script)
        try await service.inspect(applicationPath: application.path, targetPath: "/tmp/fixture/cache")
        for body in ["printf warning >&2; exit 1", "printf 'p123\\nn/tmp/fixture/cache\\n'; exit 1", "exit 0", "exit 2", "printf 'p123\\nn/tmp/fixture/cache\\n'"] {
            let occupied = try BridgeFixture(body)
            defer { occupied.remove() }
            await #expect(throws: MaintenanceError.self) {
                try await RuntimeInspectionService(psExecutable: ps.script, lsofExecutable: occupied.script).inspect(applicationPath: application.path, targetPath: "/tmp/fixture/cache")
            }
        }
    }

    @Test func lsofFileDescriptorRecordsReportOccupiedEvenWithExitOne() async throws {
        let ps = try BridgeFixture("printf '123 501 /Applications/Other.app/Contents/MacOS/Other\\n'")
        defer { ps.remove() }
        let application = ps.directory.appendingPathComponent("Test.app")
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: false)
        for code in [0, 1] {
            let lsof = try BridgeFixture("/bin/cat \"${0}.response\"; exit \(code)")
            defer { lsof.remove() }
            try Data("p123\0cOther\0\nf166\0ar\0l \0tREG\0n\(application.path)/fixture\0\n".utf8).write(to: lsof.response)
            do {
                try await RuntimeInspectionService(psExecutable: ps.script, lsofExecutable: lsof.script).inspect(applicationPath: application.path, targetPath: "/tmp/fixture/cache")
                Issue.record("有效占用记录不能当作空闲")
            } catch let error as MaintenanceError {
                #expect(error.localizedDescription.contains("进程占用"))
            }
        }
        for output in ["p123\nn/tmp/fixture/cache\n", "p123\nf166\n", "p123\nf166\nn/tmp/fixture/cache\nf167\n", "p123\nf166\nn/tmp/fixture/cache\np456\n"] {
            let lsof = try BridgeFixture("/bin/cat \"${0}.response\"; exit 1")
            defer { lsof.remove() }
            try Data(output.utf8).write(to: lsof.response)
            do {
                try await RuntimeInspectionService(psExecutable: ps.script, lsofExecutable: lsof.script).inspect(applicationPath: application.path, targetPath: "/tmp/fixture/cache")
                Issue.record("不完整占用记录不能当作空闲")
            } catch let error as MaintenanceError {
                #expect(error.localizedDescription.contains("不完整"))
            }
        }
    }

    @Test func runtimeInspectionRejectsMalformedProcessListAndOriginalBundleHelpers() async throws {
        let lsof = try BridgeFixture("exit 1")
        defer { lsof.remove() }
        for output in ["incomplete", "", "123 501 /Applications/Test.app/Contents/Helpers/Background Helper"] {
            let ps = try BridgeFixture("/bin/cat \"${0}.response\"")
            defer { ps.remove() }
            let application = ps.directory.appendingPathComponent("Trashed Test.app")
            try FileManager.default.createDirectory(at: application, withIntermediateDirectories: false)
            try Data(output.utf8).write(to: ps.response)
            await #expect(throws: MaintenanceError.self) {
                try await RuntimeInspectionService(psExecutable: ps.script, lsofExecutable: lsof.script).inspect(applicationPath: application.path, targetPath: "/tmp/fixture/cache", originalApplicationPath: "/Applications/Test.app")
            }
        }
    }
}

private final class EventObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MaintenanceEvent] = []
    var events: [MaintenanceEvent] { lock.withLock { storage } }
    func append(_ event: MaintenanceEvent) { lock.withLock { storage.append(event) } }
}

private func progress() -> [String: Any] {
    ["schemaVersion": 1, "runID": "run", "sequence": 1, "type": "progress", "message": "正在扫描中文目录"]
}

private func finalPlan() -> [String: Any] {
    ["schemaVersion": 1, "runID": "run", "sequence": 2, "type": "result", "plan": ["schemaVersion": 1, "planID": "plan", "runID": "run", "kind": "clean", "title": "中文清理", "engineVersion": "1", "engineDigest": "digest", "rulesVersion": "1", "configurationDigest": "digest", "createdAt": "2026-09-07T00:00:00Z", "scopeRoots": ["/tmp/fixture"], "scanComplete": true, "scanIssues": [], "items": []]]
}

private func finalResult(status: String, itemIDs: [String] = [], outcomes: [String]? = nil) -> [String: Any] {
    let items: [[String: Any]] = itemIDs.enumerated().map { index, id in
        let outcome = outcomes?[index] ?? "trashed"
        var item: [String: Any] = ["itemID": id, "path": "/tmp/fixture/" + id, "outcome": outcome]
        if outcome == "trashed" { item["trashPath"] = "/tmp/fixture/trash/" + id }
        return item
    }
    return ["schemaVersion": 1, "runID": "run", "sequence": 1, "type": "result", "applyResult": ["planID": "plan", "runID": "run", "title": "中文清理", "status": status, "startedAt": "2026-09-07T00:00:00Z", "finishedAt": "2026-09-07T00:00:00Z", "items": items, "selectedBytes": 0, "trashedBytes": 0]]
}

private func events(_ values: [[String: Any]]) throws -> Data {
    try values.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }.reduce(Data()) { current, next in current.isEmpty ? next : current + Data([10]) + next }
}

private struct BridgeFixture: Sendable {
    let directory: URL
    let script: URL
    var response: URL { URL(fileURLWithPath: script.path + ".response") }
    init(_ body: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent("work/bridge-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("fixture.sh")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }
    func waitUntilReady() async throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: script.path + ".ready") { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadUnknown)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
