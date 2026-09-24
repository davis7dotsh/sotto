import Foundation
import XCTest
@testable import V07Domain

final class PersonalDictionaryOutputLimitTests: XCTestCase {
    func testOutputBudgetKeepsTheEntireSourceInsteadOfPartialReplacements() {
        let dictionary = PersonalDictionary(lists: [DictionaryList(name: "Terms", entries: [
            DictionaryEntry(term: "Café", aliases: ["cafe"]),
        ])])
        XCTAssertEqual(dictionary.apply(to: "cafe cafe", maximumOutputUTF8Bytes: 11), "Café Café")
        XCTAssertEqual(dictionary.apply(to: "cafe cafe", maximumOutputUTF8Bytes: 10), "cafe cafe")
        XCTAssertEqual(dictionary.apply(to: "cafe suffix", maximumOutputUTF8Bytes: 5), "cafe suffix")
        XCTAssertEqual(dictionary.apply(to: "cafe cafe"), "Café Café")
    }

    func testOutputBudgetBoundsExpansionFromLargeSingleGraphemeTerms() {
        let term = "a" + String(repeating: "\u{0301}", count: 2_048)
        let dictionary = PersonalDictionary(lists: [DictionaryList(name: "Terms", entries: [
            DictionaryEntry(term: term, aliases: ["alias"]),
        ])])
        XCTAssertNil(dictionary.validationError)
        let source = String(repeating: "alias ", count: 300)
        XCTAssertGreaterThan(dictionary.apply(to: source).utf8.count, 1_048_576)
        XCTAssertEqual(dictionary.apply(to: source, maximumOutputUTF8Bytes: 24 * 1_024), source)
    }
}
