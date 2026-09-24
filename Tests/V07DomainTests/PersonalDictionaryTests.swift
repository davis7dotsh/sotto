import Foundation
import XCTest
@testable import V07Domain

final class PersonalDictionaryTests: XCTestCase {
    func testDefaultsOnlyNormalizeTheRequestedPreferredSpellings() throws {
        let dictionary = PersonalDictionary.default
        XCTAssertEqual(dictionary.vocabularyTerms, ["MiniMax", "Codex"])
        XCTAssertEqual(dictionary.apply(to: "Ask minimax and CODEX, not mini max or codecs."),
                       "Ask MiniMax and Codex, not mini max or codecs.")
        XCTAssertEqual(try JSONDecoder().decode(PersonalDictionary.self, from: JSONEncoder().encode(dictionary)), dictionary)
    }

    func testExplicitAliasesAndLongestPhrasesAreReplacedWithoutChangingOtherText() {
        let dictionary = make([
            DictionaryEntry(id: "mini", term: "Mini"),
            DictionaryEntry(id: "minimax", term: "MiniMax", aliases: ["mini max", "mini-max"]),
            DictionaryEntry(id: "codex", term: "Codex", aliases: ["code x"]),
        ])
        XCTAssertNil(dictionary.validationError)
        XCTAssertEqual(dictionary.apply(to: "  mini max costs $20.50. MINI-MAX: 3\n1. code x\n2. mini\n"),
                       "  MiniMax costs $20.50. MiniMax: 3\n1. Codex\n2. Mini\n")
        XCTAssertEqual(dictionary.vocabularyTerms, ["Mini", "MiniMax", "Codex"])
    }

    func testWholeUnicodeWordBoundariesProtectWordsAndIdentifiers() {
        let dictionary = PersonalDictionary.default
        let input = "codex Codex's codex-like precodex codex2 codex_plugin écOdex codexé 文codex codex文 codex\u{301}"
        XCTAssertEqual(dictionary.apply(to: input),
                       "Codex Codex's Codex-like precodex codex2 codex_plugin écOdex codexé 文codex codex文 codex\u{301}")
    }

    func testCanonicalUnicodeSpellingDoesNotNormalizeUnrelatedText() {
        let dictionary = make([DictionaryEntry(id: "cafe", term: "Café", aliases: ["coffee shop"])])
        XCTAssertEqual(dictionary.apply(to: "café, CAFE\u{301}, COFFEE SHOP; thé\u{301}."),
                       "Café, Café, Café; thé\u{301}.")
        XCTAssertEqual(dictionary.apply(to: "cafe"), "cafe", "Accents are not guessed.")
    }

    func testWholeGraphemesAndUnicodeJoinControlsAreNotPartiallyReplaced() {
        let dictionary = make([
            DictionaryEntry(id: "person", term: "Engineer", aliases: ["👩"]),
            DictionaryEntry(id: "codex", term: "Codex"),
        ])
        XCTAssertEqual(dictionary.apply(to: "👩 👩🏽 👩‍💻 codex codex‿plugin codex\u{200C}plugin tool\u{200D}codex"),
                       "Engineer 👩🏽 👩‍💻 Codex codex‿plugin codex\u{200C}plugin tool\u{200D}codex")
    }

    func testRegexPunctuationAndReplacementMetacharactersRemainLiteral() {
        let dictionary = make([
            DictionaryEntry(id: "cpp", term: "C++", aliases: ["see plus plus"]),
            DictionaryEntry(id: "money", term: "$Tool\\Kit", aliases: ["tool kit"]),
            DictionaryEntry(id: "dot", term: "Node.js", aliases: ["node jay ess"]),
        ])
        XCTAssertEqual(dictionary.apply(to: "see plus plus, tool kit, node jay ess; c++, anode.js and c++17."),
                       "C++, $Tool\\Kit, Node.js; C++, anode.js and c++17.")
    }

    func testAllListsAreActiveAndUnambiguousDuplicatesShareHints() {
        let dictionary = PersonalDictionary(lists: [
            DictionaryList(id: "work", name: "Work", entries: [DictionaryEntry(id: "a", term: "Codex", aliases: ["code x"])]),
            DictionaryList(id: "home", name: "Home", entries: [DictionaryEntry(id: "b", term: "MiniMax"), DictionaryEntry(id: "c", term: "Codex")]),
        ])
        XCTAssertNil(dictionary.validationError)
        XCTAssertEqual(dictionary.vocabularyTerms, ["Codex", "MiniMax"])
        XCTAssertEqual(dictionary.apply(to: "code x and minimax"), "Codex and MiniMax")
    }

    func testPriorityHintsAreStableAcrossListsWithoutChangingReplacements() throws {
        let dictionary = PersonalDictionary(lists: [
            DictionaryList(id: "first", name: "First", entries: [
                DictionaryEntry(id: "ordinary", term: "ordinary", aliases: ["usual"]),
                DictionaryEntry(id: "auth", term: "auth", isPriority: true),
                DictionaryEntry(id: "cafe", term: "Café"),
            ]),
            DictionaryList(id: "second", name: "Second", entries: [
                DictionaryEntry(id: "qwen", term: "Qwen", isPriority: true),
                DictionaryEntry(id: "duplicate", term: "Café", isPriority: true),
            ]),
        ])
        XCTAssertNil(dictionary.validationError)
        XCTAssertEqual(dictionary.vocabularyTerms, ["auth", "Qwen", "Café", "ordinary"])
        XCTAssertEqual(dictionary.recognitionVocabularyTerms("AUTH, server\nCAFE\u{301}, queue, , server"),
                       ["auth", "Qwen", "Café", "ordinary", "server", "queue"])
        XCTAssertEqual(dictionary.recognitionVocabularyTerms("auth\tmiddleware, auth  middleware, \tserver\t"),
                       ["auth", "Qwen", "Café", "ordinary", "auth middleware", "server"])
        XCTAssertEqual(dictionary.apply(to: "usual AUTH queue"), "ordinary auth queue")
        XCTAssertEqual(try JSONDecoder().decode(PersonalDictionary.self, from: JSONEncoder().encode(dictionary)), dictionary)
    }

    func testLegacyEntriesDefaultToNormalPriorityAndRejectInvalidFlags() throws {
        let legacy = try JSONDecoder().decode(DictionaryEntry.self, from: Data(#"{"id":"auth","term":"auth"}"#.utf8))
        XCTAssertFalse(legacy.isPriority)
        for value in ["null", "1", #""true""#] {
            let json = "{\"id\":\"auth\",\"term\":\"auth\",\"isPriority\":\(value)}"
            XCTAssertThrowsError(try JSONDecoder().decode(DictionaryEntry.self, from: Data(json.utf8)))
        }
    }

    func testScopedAuthPhraseAliasesKeepLegitimateOffAndPreferLongestMatch() {
        let dictionary = make([
            DictionaryEntry(id: "auth", term: "auth", isPriority: true),
            DictionaryEntry(id: "middleware", term: "auth middleware", aliases: ["off middleware"]),
            DictionaryEntry(id: "specific", term: "auth middleware tests", aliases: ["off middleware checks"]),
        ])
        XCTAssertNil(dictionary.validationError)
        XCTAssertEqual(dictionary.apply(to: "Fix off middleware; then turn off auth and turn off the lights."),
                       "Fix auth middleware; then turn off auth and turn off the lights.")
        XCTAssertEqual(dictionary.apply(to: "Run OFF MIDDLEWARE CHECKS. Leave off_middleware and takeoff middleware alone."),
                       "Run auth middleware tests. Leave off_middleware and takeoff middleware alone.")
        XCTAssertEqual(dictionary.vocabularyTerms, ["auth", "auth middleware", "auth middleware tests"])
    }

    func testReplacementsNeverCascadeAcrossAdjacentWords() {
        let dictionary = make([
            DictionaryEntry(id: "alpha", term: "Alpha", aliases: ["first"]),
            DictionaryEntry(id: "joined", term: "Joined", aliases: ["Alpha Beta"]),
        ])
        XCTAssertNil(dictionary.validationError)
        XCTAssertEqual(dictionary.apply(to: "first Beta; alpha beta"), "Alpha Beta; Joined")
    }

    func testConflictsAcrossListsAndUnicodeCaseFoldingAreRejected() throws {
        let cases = [
            [DictionaryEntry(id: "a", term: "Codex", aliases: ["code x"]), DictionaryEntry(id: "b", term: "Code X")],
            [DictionaryEntry(id: "a", term: "One", aliases: ["same"]), DictionaryEntry(id: "b", term: "Two", aliases: ["SAME"])],
            [DictionaryEntry(id: "a", term: "Codex"), DictionaryEntry(id: "b", term: "CODEX")],
            [DictionaryEntry(id: "a", term: "One", aliases: ["café"]), DictionaryEntry(id: "b", term: "Two", aliases: ["CAFE\u{301}"])],
        ]
        for entries in cases {
            let dictionary = PersonalDictionary(lists: entries.enumerated().map {
                DictionaryList(id: "list-\($0.offset)", name: "List", entries: [$0.element])
            })
            XCTAssertNotNil(dictionary.validationError)
            XCTAssertThrowsError(try JSONDecoder().decode(PersonalDictionary.self, from: JSONEncoder().encode(dictionary)))
            XCTAssertEqual(dictionary.apply(to: "same code x"), "same code x")
            XCTAssertTrue(dictionary.vocabularyTerms.isEmpty)
        }
    }

    func testStrictDecoderRejectsInvalidTypesMissingIDsAndExplicitNulls() throws {
        for json in [
            #"{}"#, #"{"lists":null}"#, #"{"lists":{}}"#,
            #"{"lists":[{"name":"Personal"}]}"#,
            #"{"lists":[{"id":"a","name":"Personal","entries":null}]}"#,
            #"{"lists":[{"id":"a","name":"Personal","entries":[{"term":"Codex"}]}]}"#,
            #"{"lists":[{"id":"a","name":"Personal","entries":[{"id":"b","term":"Codex","aliases":null}]}]}"#,
            #"{"lists":[{"id":"a","name":"Personal","entries":[{"id":"b","term":"Codex","aliases":[5]}]}]}"#,
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(PersonalDictionary.self, from: Data(json.utf8)), json)
        }
        XCTAssertEqual(try JSONDecoder().decode(PersonalDictionary.self, from: Data(#"{"lists":[]}"#.utf8)), PersonalDictionary())
        let minimal = #"{"lists":[{"id":"personal","name":"Personal","entries":[{"id":"codex","term":"Codex"}]}]}"#
        XCTAssertEqual(try JSONDecoder().decode(PersonalDictionary.self, from: Data(minimal.utf8)).vocabularyTerms, ["Codex"])
    }

    func testStrictDecoderRejectsUnstableIDsEmptyTextAndExcessiveValues() throws {
        let invalid = [
            PersonalDictionary(lists: [DictionaryList(id: "", name: "Personal")]),
            PersonalDictionary(lists: [DictionaryList(id: "a", name: " ")]),
            PersonalDictionary(lists: [DictionaryList(id: "a", name: "A"), DictionaryList(id: "a", name: "B")]),
            make([DictionaryEntry(id: "a", term: "Codex"), DictionaryEntry(id: "a", term: "MiniMax")]),
            make([DictionaryEntry(id: "a", term: " Codex")]),
            make([DictionaryEntry(id: "a", term: "A\nB")]),
            make([DictionaryEntry(id: "a", term: "A\u{0}B")]),
            make([DictionaryEntry(id: "a", term: String(repeating: "a", count: 129))]),
            make([DictionaryEntry(id: "a", term: "Codex", aliases: ["codex"])]),
            make([DictionaryEntry(id: "a", term: "Codex", aliases: ["code x", "CODE X"])]),
            make([DictionaryEntry(id: "a", term: "Codex", aliases: (0..<9).map { "alias \($0)" })]),
            make((0...PersonalDictionary.maximumEntries).map { DictionaryEntry(id: "\($0)", term: "Term\($0)") }),
            PersonalDictionary(lists: (0..<33).map { DictionaryList(id: "\($0)", name: "List\($0)") }),
        ]
        for dictionary in invalid {
            XCTAssertNotNil(dictionary.validationError)
            XCTAssertThrowsError(try JSONDecoder().decode(PersonalDictionary.self, from: JSONEncoder().encode(dictionary)))
        }
    }

    private func make(_ entries: [DictionaryEntry]) -> PersonalDictionary {
        PersonalDictionary(lists: [DictionaryList(id: "personal", name: "Personal", entries: entries)])
    }
}
