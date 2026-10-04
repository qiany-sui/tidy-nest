import XCTest
import TidyNestProtocol
@testable import TidyNest

final class MaintenanceResultPresentationTests: XCTestCase {
    func testReviewFilterPreservesOrderAndAllRecordedLocations() {
        let items = [
            resultItem("trashed", .trashed, trash: "/fixture/废纸篓/已移除"),
            resultItem("retained", .skipped, retained: "/fixture/原位置/保留"),
            resultItem("unknown", .unknown, trash: "/fixture/废纸篓/未知", retained: "/fixture/暂存/未知"),
            resultItem("cancelled", .cancelled, retained: "/fixture/取消"),
            resultItem("failed", .failed, retained: "/fixture/原位置/失败")
        ]
        let result = presentationResult(items)
        XCTAssertEqual(result.visibleItems(needingReviewOnly: false).map(\.itemID), ["trashed", "retained", "unknown", "cancelled", "failed"])
        let review = result.visibleItems(needingReviewOnly: true)
        XCTAssertEqual(review.map(\.itemID), ["unknown", "failed"])
        XCTAssertEqual(review.map(\.path), ["/fixture/unknown", "/fixture/failed"])
        XCTAssertEqual(review.first?.trashPath, "/fixture/废纸篓/未知")
        XCTAssertEqual(review.first?.retainedPath, "/fixture/暂存/未知")
        XCTAssertEqual(review.last?.retainedPath, "/fixture/原位置/失败")
        XCTAssertEqual(result.itemCount(for: .trashed), 1)
        XCTAssertEqual(result.itemCount(for: .skipped), 1)
        XCTAssertEqual(result.itemCount(for: .failed), 1)
        XCTAssertEqual(result.itemCount(for: .cancelled), 1)
        XCTAssertEqual(result.itemCount(for: .unknown), 1)
    }

    func testResultCountsIncludeRepeatedOutcomesAndEmptyReviewResults() {
        let result = presentationResult([resultItem("a", .trashed), resultItem("b", .trashed), resultItem("c", .skipped)])
        XCTAssertEqual(result.itemCount(for: .trashed), 2)
        XCTAssertEqual(result.itemCount(for: .skipped), 1)
        XCTAssertEqual(result.itemCount(for: .failed), 0)
        XCTAssertTrue(result.visibleItems(needingReviewOnly: true).isEmpty)
        XCTAssertEqual(result.visibleItems(needingReviewOnly: false).map(\.itemID), ["a", "b", "c"])
        let empty = presentationResult([])
        XCTAssertEqual(empty.itemCount(for: .unknown), 0)
        XCTAssertTrue(empty.visibleItems(needingReviewOnly: false).isEmpty)
    }
}

private func resultItem(_ id: String, _ outcome: ItemOutcome, trash: String? = nil, retained: String? = nil) -> MaintenanceItemResult {
    MaintenanceItemResult(itemID: id, path: "/fixture/" + id, outcome: outcome, reason: nil, trashPath: trash, retainedPath: retained, estimatedBytes: nil)
}

private func presentationResult(_ items: [MaintenanceItemResult]) -> MaintenanceResult {
    MaintenanceResult(planID: "fixture-plan", runID: "fixture-run", title: "隔离结果", status: .partial, startedAt: Date(), finishedAt: Date(), items: items, selectedBytes: 0, trashedBytes: 0, freeBytesDelta: nil, message: nil)
}
