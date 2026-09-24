import V07API
import XCTest

final class ServerPreferencesTests: XCTestCase {
    func testPreferredTermUTF8LimitMatchesSpeechRecognition() {
        let atLimit = "é" + String(repeating: "\u{0301}", count: 8_191)
        XCTAssertEqual(atLimit.count, 1)
        XCTAssertEqual(atLimit.utf8.count, ServerPreferences.maximumVocabularyTermBytes)
        var preferences = ServerPreferences(dictionary: PersonalDictionary(lists: [
            DictionaryList(name: "Terms", entries: [DictionaryEntry(term: atLimit)]),
        ]))
        XCTAssertNil(preferences.validationError)

        preferences.dictionary.lists[0].entries[0].term += "\u{0301}"
        XCTAssertEqual(preferences.dictionary.lists[0].entries[0].term.count, 1)
        XCTAssertNotNil(preferences.validationError)
    }
}
