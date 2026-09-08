import Foundation
import Testing
@testable import TidyNestCore

struct ApplicationListCacheTests {
    @Test func roundTripPreservesApplicationsAndUpdateTime() throws {
        let fixture = try ApplicationListCacheFixture()
        let snapshot = ApplicationListSnapshot(
            applications: [
                MoleApplication(name: "测试 App", bundleIdentifier: "com.example.test", source: "App", uninstallName: "测试 App", path: "/Applications/测试 App.app", displaySize: "24 MB"),
                MoleApplication(name: "另一应用", bundleIdentifier: "com.example.other", source: "App", uninstallName: "另一应用", path: "/Users/example/Applications/另一应用.app", displaySize: "N/A")
            ],
            updatedAt: Date(timeIntervalSince1970: 1_725_753_600.125)
        )

        try ApplicationListCache(fileURL: fixture.fileURL).save(snapshot)

        #expect(ApplicationListCache(fileURL: fixture.fileURL).load() == snapshot)
    }

    @Test func emptyApplicationListRemainsAValidSnapshot() throws {
        let fixture = try ApplicationListCacheFixture()
        let snapshot = ApplicationListSnapshot(applications: [], updatedAt: Date(timeIntervalSince1970: 1_725_753_601))

        try ApplicationListCache(fileURL: fixture.fileURL).save(snapshot)

        let loaded = try #require(ApplicationListCache(fileURL: fixture.fileURL).load())
        #expect(loaded.applications.isEmpty)
        #expect(loaded.updatedAt == snapshot.updatedAt)
    }

    @Test func missingCacheReturnsNilWithoutCreatingAFile() throws {
        let fixture = try ApplicationListCacheFixture()

        #expect(ApplicationListCache(fileURL: fixture.fileURL).load() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    @Test(arguments: ["not JSON", "{}", #"{"applications":[{"name":"incomplete"}],"updatedAt":0}"#])
    func corruptCacheReturnsNil(_ content: String) throws {
        let fixture = try ApplicationListCacheFixture()
        try FileManager.default.createDirectory(at: fixture.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: fixture.fileURL)

        #expect(ApplicationListCache(fileURL: fixture.fileURL).load() == nil)
    }

    @Test func savingReplacesThePreviousSnapshot() throws {
        let fixture = try ApplicationListCacheFixture()
        let cache = ApplicationListCache(fileURL: fixture.fileURL)
        let previous = ApplicationListSnapshot(
            applications: [MoleApplication(name: "Old", bundleIdentifier: "com.example.old", source: "App", uninstallName: "Old", path: "/Applications/Old.app", displaySize: "12 MB")],
            updatedAt: Date(timeIntervalSince1970: 1_725_753_600)
        )
        let latest = ApplicationListSnapshot(applications: [], updatedAt: Date(timeIntervalSince1970: 1_725_753_700))
        try cache.save(previous)

        try cache.save(latest)

        #expect(ApplicationListCache(fileURL: fixture.fileURL).load() == latest)
    }

    @Test func savingThrowsWhenTheDestinationIsADirectory() throws {
        let fixture = try ApplicationListCacheFixture()
        try FileManager.default.createDirectory(at: fixture.fileURL, withIntermediateDirectories: true)
        let snapshot = ApplicationListSnapshot(applications: [], updatedAt: Date(timeIntervalSince1970: 1_725_753_600))

        #expect(throws: (any Error).self) {
            try ApplicationListCache(fileURL: fixture.fileURL).save(snapshot)
        }
    }
}

private struct ApplicationListCacheFixture {
    let fileURL: URL

    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("work/application-list-cache-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("nested/applications.json")
    }
}
