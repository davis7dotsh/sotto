import XCTest
@testable import V07

final class ConfirmedInsertionRebasesTests: XCTestCase {
    private struct Target: Equatable {
        let field: String
        let cursor: Int
    }

    func testThreeQueuedTakesAdvancePastOnlyTheirOwnConfirmedInsertions() {
        let original = Target(field: "editor", cursor: 10)
        let afterFirst = Target(field: "editor", cursor: 15)
        let afterSecond = Target(field: "editor", cursor: 21)
        var rebases = ConfirmedInsertionRebases<Target>()
        rebases.inserted(at: original, confirmed: afterFirst)
        XCTAssertEqual(rebases.destination(for: original) { $0 == afterFirst }, afterFirst)
        rebases.inserted(at: afterFirst, confirmed: afterSecond)
        XCTAssertEqual(rebases.destination(for: original) { $0 == afterSecond }, afterSecond)
        XCTAssertEqual(rebases.destination(for: afterFirst) { $0 == afterSecond }, afterSecond)
    }

    func testSettledDeliveryRetainsRebaseUntilOverlappingCaptureAndItsDeliveryFinish() {
        let original = Target(field: "editor", cursor: 10)
        let afterFirst = Target(field: "editor", cursor: 15)
        let afterSecond = Target(field: "editor", cursor: 21)
        var rebases = ConfirmedInsertionRebases<Target>()

        // B captured the old cursor before A's asynchronous confirmation.
        rebases.inserted(at: original, confirmed: afterFirst)
        rebases.endBatchIfIdle(isCapturing: true, hasPendingDictations: false)
        XCTAssertEqual(rebases.destination(for: original) { $0 == afterFirst }, afterFirst,
                       "A draining the pending queue must not discard B's captured cursor mapping")

        // B releases and uploads after A has left the pending queue.
        rebases.endBatchIfIdle(isCapturing: false, hasPendingDictations: true)
        let secondDestination = rebases.destination(for: original) { $0 == afterFirst }
        XCTAssertEqual(secondDestination, afterFirst)
        rebases.inserted(at: secondDestination, confirmed: afterSecond)
        rebases.endBatchIfIdle(isCapturing: false, hasPendingDictations: false)
        XCTAssertEqual(rebases.destination(for: original) { _ in true }, original,
                       "The settled batch must not affect future recordings")
    }

    func testCancellingLastOverlappingCaptureClearsRetainedRebase() {
        let original = Target(field: "editor", cursor: 10)
        let confirmed = Target(field: "editor", cursor: 15)
        var rebases = ConfirmedInsertionRebases<Target>()
        rebases.inserted(at: original, confirmed: confirmed)
        rebases.endBatchIfIdle(isCapturing: true, hasPendingDictations: false)
        rebases.endBatchIfIdle(isCapturing: false, hasPendingDictations: false)
        XCTAssertEqual(rebases.destination(for: original) { _ in true }, original)
    }

    func testChangedCursorAndDifferentFieldsNeverAuthorizeRebasing() {
        let original = Target(field: "editor", cursor: 10)
        let afterFirst = Target(field: "editor", cursor: 15)
        let differentField = Target(field: "message", cursor: 10)
        var rebases = ConfirmedInsertionRebases<Target>()
        rebases.inserted(at: original, confirmed: afterFirst)
        XCTAssertEqual(rebases.destination(for: original) { _ in false }, original)
        XCTAssertEqual(rebases.destination(for: differentField) { _ in true }, differentField)
        rebases.removeAll()
        XCTAssertEqual(rebases.destination(for: original) { _ in true }, original,
                       "A finished batch must not move a future take to its old insertion cursor")
    }
}
