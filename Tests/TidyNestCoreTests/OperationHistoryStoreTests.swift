import Darwin
import Foundation
import Testing
import TidyNestProtocol
@testable import TidyNestCore

struct OperationHistoryStoreTests {
    @Test func missingHistoryReturnsEmptyWithoutCreatingDirectories() throws {
        let fixture = try OperationHistoryStoreFixture()

        #expect(try fixture.store.load() == OperationHistorySnapshot())
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.deletingLastPathComponent().path))
    }

    @Test func roundTripPreservesEveryOperationKindDetailsAndDeletionMarkers() throws {
        let fixture = try OperationHistoryStoreFixture()
        let started = Date(timeIntervalSince1970: 1_725_753_600.125)
        let finished = Date(timeIntervalSince1970: 1_725_753_601.875)
        let kinds: [OperationKind] = [.applicationList, .applicationRefresh, .diskAnalysis, .cleanScan, .uninstallPlan, .execution]
        let statuses: [MaintenanceStatus] = [.completed, .failed, .cancelled, .partial, .blocked, .unknown]
        let records = zip(kinds, statuses).enumerated().map { index, pair in
            OperationRecord(id: "record-\(index)", kind: pair.0, status: pair.1, title: "读取测试 \(index)", targetPath: "/测试目录/含 空格", startedAt: started, finishedAt: finished, summary: "保留完整结果\n第二行")
        } + [OperationRecord(execution: fixture.execution)]
        let snapshot = OperationHistorySnapshot(records: records, deletedExecutionRunIDs: ["earlier-run", "../display-only-id"])

        try fixture.store.save(snapshot)

        #expect(try OperationHistoryStore(fileURL: fixture.fileURL).load() == snapshot)
    }

    @Test func executionRecordMapsTheCompleteResult() throws {
        let fixture = try OperationHistoryStoreFixture()
        let record = OperationRecord(execution: fixture.execution)

        #expect(record.id == "execution:fixture-run")
        #expect(record.kind == .execution)
        #expect(record.status == .partial)
        #expect(record.title == "测试移除")
        #expect(record.targetPath == nil)
        #expect(record.startedAt == Date(timeIntervalSince1970: 1_725_753_600.125))
        #expect(record.finishedAt == Date(timeIntervalSince1970: 1_725_753_601.875))
        #expect(record.summary == "一项保留")
        #expect(record.execution?.items.first?.retainedPath == "/isolated/retained")
        #expect(record.execution?.trashedBytes == 5)
    }

    @Test func replacementKeepsExistingReaderCompleteAndWritesPrivateFile() throws {
        let fixture = try OperationHistoryStoreFixture()
        let original = OperationHistorySnapshot(records: [fixture.query])
        try fixture.store.save(original)
        let oldBytes = try Data(contentsOf: fixture.fileURL)
        let reader = try FileHandle(forReadingFrom: fixture.fileURL)
        defer { try? reader.close() }
        let replacement = OperationHistorySnapshot(deletedExecutionRunIDs: ["fixture-run"])

        try fixture.store.save(replacement)

        #expect(try fixture.store.load() == replacement)
        #expect(try reader.readToEnd() == oldBytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.fileURL.deletingLastPathComponent().path)
        #expect(names == ["operation-history.json"])
    }

    @Test func malformedHistoryIsRejectedAndPreservedOnSave() throws {
        let fixture = try OperationHistoryStoreFixture()
        try fixture.writeRaw(Data("not JSON".utf8))
        let original = try Data(contentsOf: fixture.fileURL)

        #expect(throws: (any Error).self) { try fixture.store.load() }
        #expect(throws: (any Error).self) { try fixture.store.save(OperationHistorySnapshot()) }
        #expect(try Data(contentsOf: fixture.fileURL) == original)
    }

    @Test func unknownSchemaIsRejectedAndPreservedOnSave() throws {
        let fixture = try OperationHistoryStoreFixture()
        try fixture.store.save(OperationHistorySnapshot(records: [fixture.query]))
        try fixture.rewriteDocument { $0["schemaVersion"] = 999 }
        let original = try Data(contentsOf: fixture.fileURL)

        #expect(throws: (any Error).self) { try fixture.store.load() }
        #expect(throws: (any Error).self) { try fixture.store.save(OperationHistorySnapshot()) }
        #expect(try Data(contentsOf: fixture.fileURL) == original)
    }

    @Test func duplicateRecordIdentifiersAreRejectedOnLoad() throws {
        let fixture = try OperationHistoryStoreFixture()
        try fixture.store.save(OperationHistorySnapshot(records: [fixture.query]))
        try fixture.rewriteDocument { document in
            let records = try #require(document["records"] as? [[String: Any]])
            document["records"] = records + records
        }

        #expect(throws: (any Error).self) { try fixture.store.load() }
    }

    @Test func duplicateRecordIdentifiersCannotReplacePreviousHistory() throws {
        let fixture = try OperationHistoryStoreFixture()
        let original = OperationHistorySnapshot(records: [fixture.query])
        try fixture.store.save(original)

        #expect(throws: (any Error).self) {
            try fixture.store.save(OperationHistorySnapshot(records: [fixture.query, fixture.query]))
        }
        #expect(try fixture.store.load() == original)
    }

    @Test(arguments: ["kind", "id", "status", "title", "startedAt", "finishedAt"])
    func inconsistentExecutionPayloadIsRejected(_ field: String) throws {
        let fixture = try OperationHistoryStoreFixture()
        let result = fixture.execution
        let inconsistent = OperationRecord(
            id: field == "id" ? "different" : "execution:fixture-run",
            kind: field == "kind" ? .uninstallPlan : .execution,
            status: field == "status" ? .completed : result.status,
            title: field == "title" ? "different" : result.title,
            startedAt: field == "startedAt" ? result.startedAt.addingTimeInterval(1) : result.startedAt,
            finishedAt: field == "finishedAt" ? result.finishedAt.addingTimeInterval(1) : result.finishedAt,
            summary: "一项保留", execution: result
        )

        #expect(throws: (any Error).self) {
            try fixture.store.save(OperationHistorySnapshot(records: [inconsistent]))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    @Test func inconsistentExecutionPayloadIsRejectedOnLoad() throws {
        let fixture = try OperationHistoryStoreFixture()
        try fixture.store.save(OperationHistorySnapshot(records: [OperationRecord(execution: fixture.execution)]))
        try fixture.rewriteDocument { document in
            var records = try #require(document["records"] as? [[String: Any]])
            records[0]["status"] = "completed"
            document["records"] = records
        }

        #expect(throws: (any Error).self) { try fixture.store.load() }
    }

    @Test(arguments: [false, true])
    func symbolicLinkTargetsAreRejectedWithoutTouchingTheDestination(_ dangling: Bool) throws {
        let fixture = try OperationHistoryStoreFixture()
        let destination = fixture.directory.appendingPathComponent("destination.json")
        let bytes = Data("destination stays unchanged".utf8)
        if !dangling { try bytes.write(to: destination) }
        try FileManager.default.createDirectory(at: fixture.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.fileURL, withDestinationURL: destination)

        #expect(throws: (any Error).self) { try fixture.store.load() }
        #expect(throws: (any Error).self) { try fixture.store.save(OperationHistorySnapshot()) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.fileURL.path) == destination.path)
        if dangling {
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        } else {
            #expect(try Data(contentsOf: destination) == bytes)
        }
    }

    @Test(arguments: ["operation-history.json", "nested/operation-history.json"])
    func linkedParentDirectoriesAreRejectedWithoutCreatingHistory(_ suffix: String) throws {
        let fixture = try OperationHistoryStoreFixture()
        let destination = fixture.directory.appendingPathComponent("real-directory")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let link = fixture.directory.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let store = OperationHistoryStore(fileURL: link.appendingPathComponent(suffix))

        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(OperationHistorySnapshot()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test(arguments: ["directory", "fifo"])
    func nonRegularTargetsAreRejected(_ kind: String) throws {
        let fixture = try OperationHistoryStoreFixture()
        try FileManager.default.createDirectory(at: fixture.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if kind == "directory" {
            try FileManager.default.createDirectory(at: fixture.fileURL, withIntermediateDirectories: true)
        } else {
            #expect(mkfifo(fixture.fileURL.path, 0o600) == 0)
        }

        #expect(throws: (any Error).self) { try fixture.store.load() }
        #expect(throws: (any Error).self) { try fixture.store.save(OperationHistorySnapshot()) }
        var info = stat()
        #expect(lstat(fixture.fileURL.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == (kind == "directory" ? S_IFDIR : S_IFIFO))
    }

    @Test func regularFileInParentPathIsNotTreatedAsMissingHistory() throws {
        let fixture = try OperationHistoryStoreFixture()
        let parent = fixture.fileURL.deletingLastPathComponent()
        let original = Data("parent remains a file".utf8)
        try original.write(to: parent)

        #expect(throws: (any Error).self) { try fixture.store.load() }
        #expect(throws: (any Error).self) { try fixture.store.save(OperationHistorySnapshot()) }
        #expect(try Data(contentsOf: parent) == original)
    }

    @Test func nonPrivateHistoryIsRejectedWithoutChangingPermissions() throws {
        let fixture = try OperationHistoryStoreFixture()
        try fixture.store.save(OperationHistorySnapshot(records: [fixture.query]))
        let original = try Data(contentsOf: fixture.fileURL)
        #expect(chmod(fixture.fileURL.path, 0o644) == 0)

        #expect(throws: (any Error).self) { try fixture.store.load() }
        #expect(throws: (any Error).self) { try fixture.store.save(OperationHistorySnapshot()) }
        #expect(try Data(contentsOf: fixture.fileURL) == original)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
    }

    @Test func hardLinkedHistoryIsRejectedWithoutChangingEitherName() throws {
        let fixture = try OperationHistoryStoreFixture()
        try fixture.store.save(OperationHistorySnapshot(records: [fixture.query]))
        let original = try Data(contentsOf: fixture.fileURL)
        let alias = fixture.directory.appendingPathComponent("hard-link.json")
        #expect(link(fixture.fileURL.path, alias.path) == 0)

        #expect(throws: (any Error).self) { try fixture.store.load() }
        #expect(throws: (any Error).self) { try fixture.store.save(OperationHistorySnapshot()) }
        #expect(try Data(contentsOf: fixture.fileURL) == original)
        #expect(try Data(contentsOf: alias) == original)
    }

    @Test func maximumSizeHistoryRemainsReadableAndCanBeReplaced() throws {
        let fixture = try OperationHistoryStoreFixture()
        let original = OperationHistorySnapshot(records: [fixture.query])
        try fixture.store.save(original)
        var bytes = try Data(contentsOf: fixture.fileURL)
        bytes.append(Data(repeating: 0x20, count: 32 * 1024 * 1024 - bytes.count))
        try bytes.write(to: fixture.fileURL)

        #expect(try fixture.store.load() == original)
        try fixture.store.save(OperationHistorySnapshot())
        #expect(try fixture.store.load() == OperationHistorySnapshot())
    }

    @Test func oversizedFileIsRejectedBeforeReadingItsContents() throws {
        let fixture = try OperationHistoryStoreFixture()
        try fixture.writeRaw(Data())
        let writer = try FileHandle(forWritingTo: fixture.fileURL)
        defer { try? writer.close() }
        try writer.truncate(atOffset: UInt64(32 * 1024 * 1024 + 1))

        #expect(throws: (any Error).self) { try fixture.store.load() }
        #expect(throws: (any Error).self) { try fixture.store.save(OperationHistorySnapshot()) }
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
        #expect((attributes[.size] as? NSNumber)?.intValue == 32 * 1024 * 1024 + 1)
    }

    @Test func oversizedSnapshotCannotReplaceOrTrimPreviousRecords() throws {
        let fixture = try OperationHistoryStoreFixture()
        let original = OperationHistorySnapshot(records: [fixture.query])
        try fixture.store.save(original)
        let oversized = OperationRecord(kind: .applicationList, status: .completed, title: "过大记录", startedAt: fixture.query.startedAt, summary: String(repeating: "x", count: 32 * 1024 * 1024))

        #expect(throws: (any Error).self) {
            try fixture.store.save(OperationHistorySnapshot(records: [fixture.query, oversized]))
        }
        #expect(try fixture.store.load() == original)
    }
}

private struct OperationHistoryStoreFixture {
    let directory: URL
    let fileURL: URL
    var store: OperationHistoryStore { OperationHistoryStore(fileURL: fileURL) }
    var query: OperationRecord {
        OperationRecord(id: "query-1", kind: .applicationList, status: .completed, title: "读取应用列表", startedAt: Date(timeIntervalSince1970: 1_725_753_600.125), finishedAt: Date(timeIntervalSince1970: 1_725_753_601.875), summary: "读取 2 项")
    }
    var execution: MaintenanceResult {
        MaintenanceResult(
            planID: "fixture-plan", runID: "fixture-run", title: "测试移除", status: .partial,
            startedAt: Date(timeIntervalSince1970: 1_725_753_600.125), finishedAt: Date(timeIntervalSince1970: 1_725_753_601.875),
            items: [MaintenanceItemResult(itemID: "fixture-item", path: "/isolated/input", outcome: .skipped, reason: "保留", trashPath: nil, retainedPath: "/isolated/retained", estimatedBytes: 9)],
            selectedBytes: 14, trashedBytes: 5, freeBytesDelta: -2, message: "一项保留"
        )
    }

    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent("work/operation-history-store-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("nested/operation-history.json")
    }

    func writeRaw(_ data: Data) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
        #expect(chmod(fileURL.path, 0o600) == 0)
    }

    func rewriteDocument(_ update: (inout [String: Any]) throws -> Void) throws {
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        try update(&document)
        try JSONSerialization.data(withJSONObject: document).write(to: fileURL)
    }
}
