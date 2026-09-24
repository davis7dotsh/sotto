import CryptoKit
import Foundation
import XCTest
@testable import V07Core

final class V07CoreTests: XCTestCase {
    func testCleanupKeepsHesitationAndRepairCuesForProofreading() {
        XCTAssertEqual(TranscriptCleaner.clean("  Um, we should, uh, ship it tomorrow.  "), "Um, we should, uh, ship it tomorrow.")
        XCTAssertEqual(TranscriptCleaner.clean("I like this, you know, a lot. Very, very much."), "I like this, you know, a lot. Very, very much.")
        XCTAssertEqual(TranscriptCleaner.clean("The umbrella is in Durham."), "The umbrella is in Durham.")
        XCTAssertEqual(TranscriptCleaner.clean("Um, keep every word."), "Um, keep every word.")
        XCTAssertEqual(TranscriptCleaner.clean("Orange, erm, yellow."), "Orange, erm, yellow.")
    }

    func testEmptySpeechAndTokensDoNotProduceText() {
        for text in ["", "  \n ", "[BLANK_AUDIO]", "[no_speech]", "(silence)", "[MUSIC]"] {
            XCTAssertEqual(TranscriptCleaner.clean(text), "")
        }
        XCTAssertEqual(TranscriptCleaner.clean("<|startoftranscript|> Hello.<|endoftext|>"), "Hello.")
        XCTAssertEqual(TranscriptCleaner.clean("Mention [draft] in the title."), "Mention [draft] in the title.")
    }

    func testTokenWrappedSilencePreservesSpokenMarkersAndParagraphs() {
        for marker in ["[BLANK_AUDIO]", "[no_speech]", "[SILENCE]", "(silence)", "[Music]"] {
            XCTAssertEqual(TranscriptCleaner.clean("<|startoftranscript|> \t\(marker)\n<|endoftext|>"), "")
        }
        XCTAssertEqual(TranscriptCleaner.clean("<|startoftranscript|>We heard [Music] outside.<|endoftext|>"), "We heard [Music] outside.")
        XCTAssertEqual(TranscriptCleaner.clean("<|startoftranscript|>Café  tomorrow.\n\nありがとう。<|endoftext|>"), "Café tomorrow.\n\nありがとう。")
    }

    func testCleanupPreservesParagraphsAndUnicode() {
        XCTAssertEqual(TranscriptCleaner.clean("Café  tomorrow.\n\nありがとう。"), "Café tomorrow.\n\nありがとう。")
    }

    func testVocabularyHintsAreTrimmedAndBounded() {
        XCTAssertEqual(TranscriptCleaner.vocabularyPrompt("  Davis,\nV07\n,  SwiftUI  "), "Davis, V07, SwiftUI")
        XCTAssertLessThanOrEqual(TranscriptCleaner.vocabularyPrompt(String(repeating: "A long proper noun,", count: 500)).count, 1_024)
        XCTAssertEqual(TranscriptCleaner.vocabularyPrompt(" , \n"), "")
    }

    func testModelIntegrityRejectsMissingTruncatedAndCorruptedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("model.bin")
        let digest = SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        let model = SpeechModel(id: "fixture", name: "Fixture", filename: "model.bin", byteCount: 3,
                                sha256: digest, downloadURL: URL(string: "https://example.invalid/model.bin")!)
        XCTAssertThrowsError(try ModelIntegrity.verify(url, model: model).get()) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .missing)
        }
        try Data("ab".utf8).write(to: url)
        XCTAssertThrowsError(try ModelIntegrity.verify(url, model: model).get()) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .wrongSize(expected: 3, actual: 2))
        }
        try Data("abd".utf8).write(to: url)
        XCTAssertThrowsError(try ModelIntegrity.verify(url, model: model).get()) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .wrongDigest)
        }
        try Data("abc".utf8).write(to: url)
        XCTAssertNoThrow(try ModelIntegrity.verify(url, model: model).get())
    }

}
