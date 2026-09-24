import XCTest
@testable import V07Domain

final class SpokenListFormatterTests: XCTestCase {
    func testAnnouncedListPreservesOutOfOrderCopularMarkersWithoutASRPunctuation() {
        let source = "Okay, I have a list of things to do today. One is I need to book the room Three is I need to pick up the keys. Two is I need to send the invitation. Four is I need to check the meeting room."
        let result = SpokenListFormatter.format(source)
        XCTAssertEqual(result.text, "Okay, I have a list of things to do today.\n\n1. I need to book the room\n3. I need to pick up the keys\n2. I need to send the invitation\n4. I need to check the meeting room")
        XCTAssertTrue(result.containsList)
        XCTAssertEqual(result.context?.nextNumber, 5)
        XCTAssertNil(result.formattingRejectionReason)
    }

    func testCopularListMarkersPreserveSkippedRepeatedAndDecreasingNumbers() {
        for introduction in ["I have a list.", "Here's my numbered list.", "We have a list.", "Start a list."] {
            let result = SpokenListFormatter.format("\(introduction) Five is book the room. Three is check that this one is available. Three is call the host.")
            XCTAssertTrue(result.text.hasSuffix("5. book the room\n3. check that this one is available\n3. call the host"), result.text)
            XCTAssertEqual(result.context?.nextNumber, 4)
            XCTAssertNil(result.formattingRejectionReason)
        }
    }

    func testCopularNumbersNeedRepeatedMarkersAndListIntent() {
        for source in ["One is enough. Three is excessive.", "This one is ready. That one is missing.",
                       "I have a list. This one is ready. That one is missing.",
                       "I have a list. One is missing.", "First is not necessarily best."] {
            let result = SpokenListFormatter.format(source)
            XCTAssertEqual(result.text, source)
            XCTAssertFalse(result.containsList)
            XCTAssertNil(result.formattingRejectionReason)
        }
    }

    func testCopularMarkersAcceptDigitsAndExplicitNumberPrefixes() {
        let result = SpokenListFormatter.format("Start a list. Number five is book the room. 3 is pick up the keys. Item two is send the invitation.")
        XCTAssertEqual(result.text, "5. book the room\n3. pick up the keys\n2. send the invitation")
        XCTAssertNil(result.formattingRejectionReason)
    }

    func testDecodedContextClampsNegativeNextNumber() throws {
        let data = Data(#"{"style":"numbered","nextNumber":-5}"#.utf8)
        let context = try JSONDecoder().decode(SpokenListContext.self, from: data)
        XCTAssertEqual(context, SpokenListContext(style: .numbered, nextNumber: 0))
        XCTAssertEqual(SpokenListFormatter.format("Apples.", context: context).text, "0. Apples")
    }

    func testContextCodableRoundTrip() throws {
        for context in [SpokenListContext(style: .numbered, nextNumber: 5),
                        SpokenListContext(style: .bulleted),
                        SpokenListContext(style: .numbered, nextNumber: Int.max)] {
            XCTAssertEqual(try JSONDecoder().decode(SpokenListContext.self,
                                                   from: JSONEncoder().encode(context)), context)
        }
    }

    func testActualScreenshotDictationDropsOnlyResumeChatterAndPreservesNumbers() {
        let input = "Sorry, I wanted that screenshot. Go ahead. My voice to text was just ruined. Let me go back to where I was with that list. Three, oranges. Four, a trip to the beach. Seven, more syrup. That's the end of the list."
        let result = SpokenListFormatter.format(input)
        XCTAssertEqual(result.text, "3. oranges\n4. a trip to the beach\n7. more syrup")
        XCTAssertNil(result.context)
        XCTAssertTrue(result.containsList)
        XCTAssertTrue(result.endedList)
        XCTAssertFalse(result.continuesPreviousList)
    }

    func testNumberedListContinuesAcrossHoldsAndExplicitNumbersWin() {
        let first = SpokenListFormatter.format("Make a list. One, apples. Two, bananas.")
        XCTAssertEqual(first.text, "1. apples\n2. bananas")
        XCTAssertEqual(first.context, SpokenListContext(style: .numbered, nextNumber: 3))

        let next = SpokenListFormatter.format("Next item, oranges.", context: first.context)
        XCTAssertEqual(next.text, "3. oranges")
        XCTAssertTrue(next.continuesPreviousList)

        let resumed = SpokenListFormatter.format("Continue the list. Number four, a trip to the beach. Item seven, more syrup.", context: next.context)
        XCTAssertEqual(resumed.text, "4. a trip to the beach\n7. more syrup")
        XCTAssertEqual(resumed.context?.nextNumber, 8)
        XCTAssertTrue(resumed.continuesPreviousList)

        let implicit = SpokenListFormatter.format("Maple syrup.", context: resumed.context)
        XCTAssertEqual(implicit.text, "8. Maple syrup")
    }

    func testResumeWithExistingContextDoesNotConsumeAnItemForChatter() {
        let context = SpokenListContext(style: .numbered, nextNumber: 3)
        let result = SpokenListFormatter.format("Sorry, I wanted that screenshot. Go ahead. My voice to text was just ruined. Let me go back to where I was with that list. Next item, oranges.", context: context)
        XCTAssertEqual(result.text, "3. oranges")
        XCTAssertEqual(result.context?.nextNumber, 4)
        XCTAssertTrue(result.continuesPreviousList)
    }

    func testEndThenOrdinaryProseAndLaterHold() {
        let result = SpokenListFormatter.format("Three, oranges. End of list. Please send the receipt tomorrow.", context: SpokenListContext(style: .numbered, nextNumber: 3))
        XCTAssertEqual(result.text, "3. oranges\n\nPlease send the receipt tomorrow.")
        XCTAssertNil(result.context)
        XCTAssertTrue(result.endedList)
        let next = SpokenListFormatter.format("I bought three oranges.", context: result.context)
        XCTAssertEqual(next.text, "I bought three oranges.")
        XCTAssertFalse(next.containsList)
    }

    func testBulletsAndBulletContinuation() {
        let first = SpokenListFormatter.format("Start a bulleted list. Bullet point, apples. Next bullet, bananas.")
        XCTAssertEqual(first.text, "- apples\n- bananas")
        XCTAssertEqual(first.context?.style, .bulleted)
        let next = SpokenListFormatter.format("Continue the list. Next item, oranges.", context: first.context)
        XCTAssertEqual(next.text, "- oranges")
        XCTAssertTrue(next.continuesPreviousList)
        let end = SpokenListFormatter.format("That's the end of the list.", context: next.context)
        XCTAssertEqual(end.text, "")
        XCTAssertTrue(end.isControlOnly)
        XCTAssertTrue(end.endedList)
        XCTAssertNil(end.context)
    }

    func testControlOnlyStartsAndExplicitNewLists() {
        let start = SpokenListFormatter.format("Start a numbered list.")
        XCTAssertEqual(start.text, "")
        XCTAssertTrue(start.isControlOnly)
        XCTAssertFalse(start.containsList)
        XCTAssertEqual(start.context?.nextNumber, 1)
        let next = SpokenListFormatter.format("Next item.", context: start.context)
        XCTAssertTrue(next.isControlOnly)
        XCTAssertEqual(next.context?.nextNumber, 1)
        let new = SpokenListFormatter.format("Start a new list. One, pears.", context: SpokenListContext(style: .numbered, nextNumber: 8))
        XCTAssertEqual(new.text, "1. pears")
        XCTAssertFalse(new.continuesPreviousList)
    }

    func testControlOnlyResumeAndNextKeepExistingContinuation() {
        let context = SpokenListContext(style: .numbered, nextNumber: 3)
        for command in ["Resume the list.", "Continue this list", "Next item.", "Let me go back to the list."] {
            let result = SpokenListFormatter.format(command, context: context)
            XCTAssertTrue(result.isControlOnly, command)
            XCTAssertTrue(result.continuesPreviousList, command)
            XCTAssertEqual(result.context, context, command)
            XCTAssertFalse(result.endsWithList, command)
        }
        let restart = SpokenListFormatter.format("End list. Start a new list.", context: context)
        XCTAssertTrue(restart.isControlOnly)
        XCTAssertFalse(restart.continuesPreviousList)
        XCTAssertEqual(restart.context?.nextNumber, 1)
    }

    func testSilenceDoesNotEndOrAdvanceContext() {
        let context = SpokenListContext(style: .numbered, nextNumber: 4)
        for input in ["", "  ", "\n\n"] {
            let result = SpokenListFormatter.format(input, context: context)
            XCTAssertEqual(result.text, "")
            XCTAssertEqual(result.context, context)
            XCTAssertFalse(result.isControlOnly)
            XCTAssertFalse(result.endedList)
        }
    }

    func testOrdinaryLanguageAndQuantitiesRemainUntouchedWithoutListIntent() {
        let examples = [
            "I bought three oranges.", "Call at four.", "One thing matters.",
            "First we test. Second we ship.", "First we test.\n\nSecond we ship.",
            "We need 3.5 litres and $12.50 for lunch.", "Meet at 4:30 on 2026-09-03.",
            "Use 1/2 cup of sugar and 3/4 cup of flour.", "One, two, three.",
            "2026. Revenue increased. 2027. We expect growth.",
            "The end of the list is missing.", "Make a list of my expenses for tomorrow.",
            "Sorry, I wanted that screenshot. My voice to text was just ruined.",
            "Item 123 is missing.", "Number one is our priority.", "New item added to the cart.",
            "Bullet point formatting is broken.", "Next item arrives tomorrow.", "Next bullet hits the target.",
        ]
        for input in examples {
            let result = SpokenListFormatter.format(input)
            XCTAssertEqual(result.text, input, input)
            XCTAssertFalse(result.containsList, input)
            XCTAssertNil(result.context, input)
        }
    }

    func testImplicitMarkerSeriesAndOrdinals() {
        XCTAssertEqual(SpokenListFormatter.format("One, apples. Two, bananas.").text, "1. apples\n2. bananas")
        XCTAssertEqual(SpokenListFormatter.format("First, apples. Second, bananas.").text, "1. apples\n2. bananas")
        XCTAssertEqual(SpokenListFormatter.format("3. oranges\n4. beach\n7. syrup").text, "3. oranges\n4. beach\n7. syrup")
        XCTAssertEqual(SpokenListFormatter.format("(3) oranges\n(7) syrup").text, "3. oranges\n7. syrup")
        XCTAssertEqual(SpokenListFormatter.format("- apples\n- bananas").text, "- apples\n- bananas")
        XCTAssertEqual(SpokenListFormatter.format("One, apples. 2. bananas.").text, "1. apples\n2. bananas")
        XCTAssertEqual(SpokenListFormatter.format("One, apples, 2. bananas, three, oranges.").text, "1. apples\n2. bananas\n3. oranges")
        XCTAssertEqual(SpokenListFormatter.format("One, 2, three.").text, "One, 2, three.")
    }

    func testCommaSeparatedASRListsAndCountingContent() {
        XCTAssertEqual(SpokenListFormatter.format("One, apples, two, bananas, three, oranges.").text,
                       "1. apples\n2. bananas\n3. oranges")
        XCTAssertEqual(SpokenListFormatter.format("1. Apples, 2. Bananas").text, "1. Apples\n2. Bananas")
        let counting = SpokenListFormatter.format("Next item, one, two, three.", context: SpokenListContext(style: .numbered, nextNumber: 4))
        XCTAssertEqual(counting.text, "4. one, two, three")
        XCTAssertEqual(SpokenListFormatter.format("I counted one, two, three, four.").text, "I counted one, two, three, four.")
        XCTAssertEqual(SpokenListFormatter.format("Bullet point, apples, next bullet, bananas.").text, "- apples\n- bananas")
        XCTAssertEqual(SpokenListFormatter.format("Start a list. One — apples. Two - bananas.").text, "1. apples\n2. bananas")
    }

    func testStandaloneNumericAnswersAreContentWithAndWithoutContinuation() {
        let context = SpokenListContext(style: .numbered, nextNumber: 5)
        for (source, continued) in [("24.", "5. 24"), ("24)", "5. 24)"), ("24:", "5. 24:"), ("(24)", "5. (24)")] {
            let plain = SpokenListFormatter.format(source)
            XCTAssertEqual(plain.text, source)
            XCTAssertFalse(plain.isControlOnly)
            XCTAssertNil(plain.context)
            XCTAssertNil(plain.formattingRejectionReason)

            let item = SpokenListFormatter.format(source, context: context)
            XCTAssertEqual(item.text, continued)
            XCTAssertEqual(item.context?.nextNumber, 6)
            XCTAssertTrue(item.continuesPreviousList)
            XCTAssertFalse(item.isControlOnly)
            XCTAssertNil(item.formattingRejectionReason)
        }
    }

    func testNumericCorrectionKeepsBothValuesForProofreading() {
        for source in ["Make it 42, err, 24.", "Make it 42, err, 24. That is final."] {
            XCTAssertEqual(SpokenListFormatter.format(source).text, source)
            let result = SpokenListFormatter.format(source, context: SpokenListContext(style: .numbered, nextNumber: 5))
            XCTAssertTrue(result.text.hasPrefix("5. Make it 42, err, 24"))
            XCTAssertEqual(result.context?.nextNumber, 6)
            XCTAssertNil(result.formattingRejectionReason)
        }
    }

    func testASRListsWithoutInterItemPunctuationPreserveStartsAndSkips() {
        let examples = [
            ("5, Apples 6, Bananas 7, Oranges 8, Pears", "5. Apples\n6. Bananas\n7. Oranges\n8. Pears", 9),
            ("5, apples 7, oranges", "5. apples\n7. oranges", 8),
            ("Continue the list. 5, apples 7, oranges", "5. apples\n7. oranges", 8),
        ]
        for (source, expected, nextNumber) in examples {
            for context: SpokenListContext? in [nil, SpokenListContext(style: .numbered, nextNumber: 20)] {
                let result = SpokenListFormatter.format(source, context: context)
                XCTAssertEqual(result.text, expected, source)
                XCTAssertEqual(result.context?.nextNumber, nextNumber, source)
                XCTAssertNil(result.formattingRejectionReason, source)
            }
        }
    }

    func testNumericProseDoesNotAcquireMarkersFromCommasOrContinuation() {
        let examples = [
            "We have 5, maybe 6, apples.",
            "I said 24, 25, and 26.",
            "5, maybe 6, perhaps 7, people.",
            "The range is 5, approximately 6, perhaps 7, units.",
            "The answer is: 24. That is final.",
            "5, 6, 7, 8.",
            "We need 3.5 litres and $12.50 for lunch.",
            "Meet at 4:30 on 2026-09-03.",
            "2026. Revenue increased. 2027. We expect growth.",
        ]
        for source in examples {
            let plain = SpokenListFormatter.format(source)
            XCTAssertEqual(plain.text, source, source)
            XCTAssertFalse(plain.containsList, source)
            let item = SpokenListFormatter.format(source, context: SpokenListContext(style: .numbered, nextNumber: 3))
            XCTAssertTrue(item.text.hasPrefix("3. "), source)
            XCTAssertEqual(item.context?.nextNumber, 4, source)
            XCTAssertFalse(item.text.contains("\n"), source)
            XCTAssertNil(item.formattingRejectionReason, source)
        }
    }

    func testRecordedControlSpansExcludeNumbersAndItemContent() {
        let source = "Please keep café. Continue the list. Number twenty-four, oranges. End list."
        let result = SpokenListFormatter.format(source)
        XCTAssertEqual(result.text, "Please keep café.\n\n24. oranges")
        XCTAssertNil(result.formattingRejectionReason)
        let controls = result.consumedControls.compactMap { span -> String? in
            guard let range = Range(NSRange(location: span.location, length: span.length), in: source) else { return nil }
            return String(source[range])
        }
        XCTAssertEqual(controls, ["Continue the list.", "End list."])
        XCTAssertEqual(result.replacingText("Updated").consumedControls, result.consumedControls)
    }

    func testBodylessNumericContentSurvivesBeforeExplicitControls() {
        XCTAssertEqual(SpokenListFormatter.format("Start a list. 24. End list.").text, "1. 24")
        XCTAssertEqual(SpokenListFormatter.format("Start a list. 24. Next item, agreed.").text, "1. 24\n2. agreed")
        let result = SpokenListFormatter.format("Start a list. Next item. End list.")
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.isControlOnly)
        XCTAssertNil(result.formattingRejectionReason)
    }

    func testTailMetadataDistinguishesMultilineItemsFromProse() {
        let item = SpokenListFormatter.format("Start a list. One, first paragraph\n\nsecond paragraph.")
        XCTAssertTrue(item.endsWithList)
        let prose = SpokenListFormatter.format("Start a list. One, oranges. End list. Please call tomorrow.")
        XCTAssertTrue(prose.containsList)
        XCTAssertFalse(prose.endsWithList)
        XCTAssertFalse(SpokenListFormatter.format("Plain text.").endsWithList)
    }

    func testCompoundNumbersAndExplicitMarkerVariants() {
        let result = SpokenListFormatter.format("Make a list. Twenty-one, apples. Number thirty two, bananas. Item one hundred and three, oranges.")
        XCTAssertEqual(result.text, "21. apples\n32. bananas\n103. oranges")
        XCTAssertEqual(result.context?.nextNumber, 104)
        XCTAssertEqual(SpokenListFormatter.format("Start a list. 1st, apples. 3rd, oranges.").text, "1. apples\n3. oranges")
    }

    func testItemContentKeepsDecimalsAbbreviationsSentencesAndParagraphs() {
        let result = SpokenListFormatter.format("Make a list. One, buy 3.5 litres for $12.50. Two, call Dr. Green in the U.S. Three, explain the problem. Include screenshots! Four, first paragraph\n\nsecond paragraph.")
        XCTAssertEqual(result.text, "1. buy 3.5 litres for $12.50\n2. call Dr. Green in the U.S.\n3. explain the problem. Include screenshots!\n4. first paragraph\n\nsecond paragraph")
    }

    func testSubstantivePreludeAndMarkedItemAreNotMistakenForMetaChatter() {
        let result = SpokenListFormatter.format("Please send the report tomorrow. Continue the list. Three, oranges.")
        XCTAssertEqual(result.text, "Please send the report tomorrow.\n\n3. oranges")
        let item = SpokenListFormatter.format("Make a list. One, my dictation was broken. Two, the screenshot was wrong.")
        XCTAssertEqual(item.text, "1. my dictation was broken\n2. the screenshot was wrong")
    }

    func testUnseparatedMarkerPhrasesNeedExistingListIntent() {
        let context = SpokenListContext(style: .numbered, nextNumber: 2)
        XCTAssertEqual(SpokenListFormatter.format("Number three oranges.", context: context).text, "3. oranges")
        XCTAssertEqual(SpokenListFormatter.format("Next item bananas.", context: context).text, "2. bananas")
        XCTAssertEqual(SpokenListFormatter.format("Start a bulleted list. Bullet point apples.").text, "- apples")
        XCTAssertTrue(SpokenListFormatter.format("Next item").isControlOnly)
    }

    func testResumeDoesNotDeleteRecordingInstructionsQuestionsOrGenericProse() {
        for prelude in [
            "Please investigate why the recording failed.",
            "Why did my transcription fail?",
            "My recording failed.",
            "My recording of dictation failed.",
            "My dictation exercise failed.",
            "My microphone is broken.",
            "My dictation failed, can you investigate?",
            "Please redo my transcription again.",
        ] {
            let result = SpokenListFormatter.format("\(prelude) Continue the list. Three, oranges.")
            XCTAssertEqual(result.text, "\(prelude)\n\n3. oranges", prelude)
        }
        XCTAssertEqual(SpokenListFormatter.format("My voice to text was just ruined. Continue the list. Three, oranges.").text, "3. oranges")
    }
}
