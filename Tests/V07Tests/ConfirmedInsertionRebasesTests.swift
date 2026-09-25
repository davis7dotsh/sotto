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
