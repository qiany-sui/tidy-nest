import Foundation
import XCTest
@testable import TidyNest
@testable import TidyNestCore

@MainActor
final class ApplicationBrowsingTests: XCTestCase {
    func testSearchMatchesDisplayNameFilenameAndBundleIdentifier() async {
        let model = await workspace([
            app("Code", path: "/Applications/Visual Studio Code.app", bundle: "com.microsoft.VSCode", size: "1.5 GB"),
            app("编辑器", path: "/Applications/Editor.app", bundle: "com.example.editor", size: "20 MB")
        ])
        model.selectedApplicationID = "/Applications/Visual Studio Code.app"
        for query in ["  cOdE  ", "VISUAL STUDIO", "com.microsoft.vscode"] {
            model.searchText = query
            XCTAssertEqual(model.filteredApplications.map(\.name), ["Code"], query)
            XCTAssertEqual(model.selectedApplication?.name, "Code")
        }
        model.searchText = "编辑器"
        XCTAssertEqual(model.filteredApplications.map(\.name), ["编辑器"])
        XCTAssertNil(model.selectedApplication)
        model.searchText = ""
        XCTAssertEqual(model.selectedApplication?.name, "Code", "搜索不能清除原选择")
    }

    func testSizeSortingUsesNumericUnitsAndKeepsUnknownAfterZero() async {
        let fixtures: [(String, String)] = [
            ("Unknown", "N/A"), ("Bytes", "999 bytes"), ("MB", "950MB"),
            ("GB", "1.2 GB"), ("TB", "1 TB"), ("KB", "2\u{2006}KB"),
            ("Zero", "0 KB"), ("SystemZero", ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)),
            ("Malformed", "1.2.3 MB"), ("Negative", "-1 GB"), ("Empty", ""),
            ("Overflow", "1e309 GB")
        ]
        let model = await workspace(fixtures.map { app($0.0, path: "/Applications/" + $0.0 + ".app", size: $0.1) })
        model.applicationSortOrder = .sizeDescending
        XCTAssertEqual(model.filteredApplications.map(\.name), ["TB", "GB", "MB", "KB", "Bytes", "SystemZero", "Zero", "Empty", "Malformed", "Negative", "Overflow", "Unknown"])
    }

    func testSortingAndSearchingKeepSelectionSnapshotTimeAndOriginalList() async {
        let apps = [app("Code", path: "/Applications/Visual Studio Code.app", bundle: "com.microsoft.VSCode", size: "24 MB"),
                    app("Other", path: "/Applications/Other.app", size: "1 GB")]
        let model = await workspace(apps)
        let updatedAt = model.applicationsUpdatedAt
        model.selectedApplicationID = "/Applications/Visual Studio Code.app"
        XCTAssertEqual(model.filteredApplications.map(\.name), ["Code", "Other"])
        model.applicationSortOrder = .sizeDescending
        XCTAssertEqual(model.filteredApplications.map(\.name), ["Other", "Code"])
        XCTAssertEqual(model.selectedApplication?.name, "Code")
        model.searchText = "visual studio"
        XCTAssertEqual(model.filteredApplications.map(\.name), ["Code"])
        model.searchText = ""
        model.applicationSortOrder = .name
        XCTAssertEqual(model.filteredApplications.map(\.name), ["Code", "Other"])
        XCTAssertEqual(model.selectedApplication?.name, "Code")
        XCTAssertEqual(model.applications, apps)
        XCTAssertEqual(model.applicationsUpdatedAt, updatedAt)
        XCTAssertEqual(model.applicationsPhase, .loaded)
        XCTAssertFalse(model.isBusy)
    }

    func testEqualSizesUseNameAndPathForStableOrdering() async {
        let model = await workspace([
            app("Same", path: "/Applications/z.app", size: "1000 MB"),
            app("Same", path: "/Applications/a.app", size: "1 GB"),
            app("Alpha", path: "/Applications/Alpha.app", size: "1GB")
        ])
        model.applicationSortOrder = .sizeDescending
        XCTAssertEqual(model.filteredApplications.map(\.path), ["/Applications/Alpha.app", "/Applications/a.app", "/Applications/z.app"])
    }

    func testSizeSortingAcceptsSystemFormattedValuesAlongsideMoleValues() async {
        let model = await workspace([
            app("Large", path: "/Applications/Large.app", size: ByteCountFormatter.string(fromByteCount: 1_250_000_000, countStyle: .file)),
            app("Small", path: "/Applications/Small.app", size: ByteCountFormatter.string(fromByteCount: 1_200_000, countStyle: .file)),
            app("Bytes", path: "/Applications/Bytes.app", size: ByteCountFormatter.string(fromByteCount: 12, countStyle: .file)),
            app("Mole", path: "/Applications/Mole.app", size: "950MB"),
            app("Zero", path: "/Applications/Zero.app", size: ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)),
            app("Unknown", path: "/Applications/Unknown.app", size: "N/A")
        ])
        model.applicationSortOrder = .sizeDescending
        XCTAssertEqual(model.filteredApplications.map(\.name), ["Large", "Mole", "Small", "Bytes", "Zero", "Unknown"])
    }

    private func workspace(_ apps: [MoleApplication]) async -> WorkspaceModel {
        let model = WorkspaceModel(detect: { MoleInstallation(executableURL: URL(fileURLWithPath: "/fixture/mole"), version: "1.54.0") }, applications: { _ in apps })
        model.start()
        await settle(model)
        model.loadApplications()
        await settle(model)
        return model
    }

    private func settle(_ model: WorkspaceModel) async {
        for _ in 0..<2_000 {
            if !model.isBusy { return }
            await Task.yield()
        }
        XCTFail("查询未完成")
    }
}

private func app(_ name: String, path: String, bundle: String = "com.example.fixture", size: String) -> MoleApplication {
    MoleApplication(name: name, bundleIdentifier: bundle, source: "App", uninstallName: name, path: path, displaySize: size)
}
