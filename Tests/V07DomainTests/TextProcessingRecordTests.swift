import Foundation
import XCTest
@testable import V07Domain

final class TextProcessingRecordTests: XCTestCase {
    func testRejectedDictionaryExpansionKeepsArchivedDiagnosticsSmall() throws {
        let term = "a" + String(repeating: "\u{0301}", count: 2_048)
        let dictionary = PersonalDictionary(lists: [DictionaryList(id: "terms", name: "Terms", entries: [
            DictionaryEntry(id: "expanded", term: term, aliases: ["alias"]),
        ])])
        XCTAssertNil(dictionary.validationError)
        XCTAssertEqual(term.count, 1)
        let candidate = dictionary.apply(to: String(repeating: "alias ", count: 300))
        XCTAssertGreaterThan(candidate.utf8.count, 1_048_576)
        XCTAssertLessThan(candidate.count, TextCorrectionPolicy.maximumInputCharacters * 2)

        let record = TextProcessingRecord(dictionaryTerms: [term], dictionaryChangedText: false,
            inputText: "Keep this answer.", outputText: "Keep this answer.", enabled: true,
            status: .rejected, reason: TextCorrectionPolicy.rejectionReason(original: "Keep this answer.", candidate: candidate),
            proposedText: candidate)
        let proposedText = try XCTUnwrap(record.proposedText)
        XCTAssertLessThanOrEqual(proposedText.utf16.count, TextCorrectionPolicy.maximumInputCharacters * 8)
        XCTAssertEqual(Data(candidate.utf8.prefix(proposedText.utf8.count)), Data(proposedText.utf8))
        XCTAssertEqual(record.outputText, "Keep this answer.")
        XCTAssertNotNil(record.reason)
        let encoded = try JSONEncoder().encode(record)
        XCTAssertLessThan(encoded.count, 256 * 1_024)
        XCTAssertEqual(try JSONDecoder().decode(TextProcessingRecord.self, from: encoded), record)
    }

    func testDiagnosticCodeUnitBoundNeverSplitsASurrogatePair() throws {
        let prefix = "a" + String(repeating: "\u{0301}", count: TextCorrectionPolicy.maximumInputCharacters * 8 - 2)
        let candidate = prefix + "😀"
        XCTAssertEqual(candidate.count, 2)
        let record = TextProcessingRecord(dictionaryTerms: [], dictionaryChangedText: false,
            inputText: "Answer.", outputText: "Answer.", enabled: true, status: .rejected,
            proposedText: candidate)
        XCTAssertEqual(try XCTUnwrap(record.proposedText), prefix)
    }

    func testDiagnosticClippingPreservesShortUnicodeAndTheCharacterLimit() {
        for candidate in ["Café 👨‍👩‍👧‍👦", String(repeating: "x", count: 13_000)] {
            let record = TextProcessingRecord(dictionaryTerms: [], dictionaryChangedText: false,
                inputText: "Answer.", outputText: "Answer.", enabled: true, status: .rejected,
                proposedText: candidate)
            XCTAssertEqual(record.proposedText, String(candidate.prefix(TextCorrectionPolicy.maximumInputCharacters * 2)))
        }
    }
}
