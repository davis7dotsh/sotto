import XCTest
@testable import V07Domain

final class DictationCompositionTests: XCTestCase {
    private func compose(_ text: String, after previous: DictationContinuation? = nil) -> ComposedDictation {
        DictationComposer.compose(SpokenListFormatter.format(text, context: previous?.list), previous: previous)
    }

    func testLaterHoldInsertsOnlyNewItemsButKeepsCompletePreview() {
        let first = compose("Make a list. One, apples. Two, bananas.")
        XCTAssertEqual(first.insertion, "1. apples\n2. bananas")

        let next = compose("Next item, oranges.", after: first.continuation)
        XCTAssertEqual(next.insertion, "\n3. oranges")
        XCTAssertEqual(next.preview, "1. apples\n2. bananas\n3. oranges")
        XCTAssertEqual(next.continuation?.list?.nextNumber, 4)

        let implicit = compose("More syrup.", after: next.continuation)
        XCTAssertEqual(implicit.insertion, "\n4. More syrup")
        XCTAssertEqual(implicit.preview, "1. apples\n2. bananas\n3. oranges\n4. More syrup")
    }

    func testScreenshotResumesWithoutRenumberingAndEndsBeforeProse() {
        let first = compose("Make a list. One, milk. Two, flour.")
        let resumed = compose("Sorry, I wanted that screenshot. Go ahead. My voice to text was just ruined. Let me go back to where I was with that list. Three, oranges. Four, a trip to the beach. Seven, more syrup. That's the end of the list.", after: first.continuation)
        XCTAssertEqual(resumed.insertion, "\n3. oranges\n4. a trip to the beach\n7. more syrup")
        XCTAssertEqual(resumed.preview, "1. milk\n2. flour\n3. oranges\n4. a trip to the beach\n7. more syrup")
        XCTAssertNil(resumed.continuation?.list)

        let prose = compose("Thanks for your help.", after: resumed.continuation)
        XCTAssertEqual(prose.insertion, "\n\nThanks for your help. ")
        XCTAssertEqual(prose.preview, resumed.preview + "\n\nThanks for your help.")
    }

    func testControlOnlyResumeAndNextItemKeepListAndPreview() {
        let first = compose("Start a list. One, apples. Two, bananas.")
        let resume = compose("Continue the list.", after: first.continuation)
        XCTAssertEqual(resume.insertion, "")
        XCTAssertEqual(resume.preview, first.preview)

        let marker = compose("Next item.", after: resume.continuation)
        XCTAssertEqual(marker.insertion, "")
        XCTAssertEqual(marker.preview, first.preview)
        XCTAssertEqual(marker.continuation?.list?.nextNumber, 3)

        let item = compose("Oranges.", after: marker.continuation)
        XCTAssertEqual(item.insertion, "\n3. Oranges")
        XCTAssertEqual(item.preview, first.preview + "\n3. Oranges")
    }

    func testEndCommandNeverSendsWhitespaceOnlyPaste() {
        let first = compose("Start a list. One, apples.")
        let end = compose("End of the list.", after: first.continuation)
        XCTAssertEqual(end.insertion, "")
        XCTAssertEqual(end.preview, first.preview)
        XCTAssertNil(end.continuation?.list)

        let prose = compose("Please buy these tomorrow.", after: end.continuation)
        XCTAssertEqual(prose.insertion, "\n\nPlease buy these tomorrow. ")
        let combined = compose("End list. Please buy these tomorrow.", after: first.continuation)
        XCTAssertEqual(combined.insertion, prose.insertion)
        XCTAssertEqual(combined.preview, prose.preview)
        let more = compose("Thank you.", after: prose.continuation)
        XCTAssertEqual(more.insertion, "Thank you. ")
    }

    func testNewListResetsNumberingAndPreviewWithParagraphBoundary() {
        let first = compose("Start a list. Seven, syrup.")
        let new = compose("Start a new list. One, pears.", after: first.continuation)
        XCTAssertEqual(new.insertion, "\n\n1. pears")
        XCTAssertEqual(new.preview, "1. pears")
        XCTAssertEqual(new.continuation?.list?.nextNumber, 2)
    }

    func testRepeatedListCommandsDoNotLosePendingParagraph() {
        let first = compose("Start a list. One, apples.")
        let start = compose("Start a new list.", after: first.continuation)
        let restart = compose("Start a numbered list.", after: start.continuation)
        XCTAssertEqual(start.insertion, "")
        XCTAssertEqual(restart.insertion, "")
        XCTAssertEqual(compose("Pears.", after: restart.continuation).insertion, "\n\n1. Pears")

        let end = compose("End list.", after: restart.continuation)
        XCTAssertEqual(end.insertion, "")
        XCTAssertEqual(compose("Thank you.", after: end.continuation).insertion, "\n\nThank you. ")
    }

    func testEndThenStartInOneControlHoldKeepsNewContext() {
        let first = compose("Make a list. Seven, syrup.")
        let restart = compose("End list. Start a new list.", after: first.continuation)
        XCTAssertEqual(restart.insertion, "")
        XCTAssertEqual(restart.continuation?.list?.nextNumber, 1)
        XCTAssertEqual(compose("Oranges.", after: restart.continuation).insertion, "\n\n1. Oranges")
    }

    func testBulletsAndMultilineItemsKeepCorrectTailBoundaries() {
        let first = compose("Start a bulleted list. Bullet point, apples.")
        let second = compose("Next bullet, oranges.", after: first.continuation)
        XCTAssertEqual(second.insertion, "\n- oranges")
        XCTAssertEqual(second.preview, "- apples\n- oranges")

        let multiline = compose("Make a list. One, first paragraph\n\nsecond paragraph. End list.")
        XCTAssertEqual(multiline.insertion, "1. first paragraph\n\nsecond paragraph")
        XCTAssertEqual(compose("Finished.", after: multiline.continuation).insertion, "\n\nFinished. ")
    }

    func testPlainProseStillUsesSpacesAndDoesNotAccumulateOldPreviews() {
        let first = compose("I bought three oranges.")
        let next = compose("The total was $12.50.", after: first.continuation)
        XCTAssertEqual(first.insertion, "I bought three oranges. ")
        XCTAssertEqual(next.insertion, "The total was $12.50. ")
        XCTAssertEqual(next.preview, "The total was $12.50.")
        XCTAssertNil(next.continuation?.list)
        XCTAssertEqual(compose("", after: first.continuation).continuation, first.continuation)
    }

    func testContextDoesNotAdvanceUntilDeliveryIsCommitted() {
        var memory = DictationContinuationMemory<String>()
        let first = compose("Make a list. One, apples.")
        memory.remember(first.continuation, for: "field@9", now: 10)

        let pending = compose("Next item, oranges.", after: memory.continuation(for: "field@9", now: 11))
        XCTAssertEqual(pending.continuation?.list?.nextNumber, 3)
        // A cancelled/failed delivery never calls remember.
        XCTAssertEqual(memory.continuation(for: "field@9", now: 12)?.list?.nextNumber, 2)

        memory.forget("field@9")
        memory.remember(pending.continuation, for: "field@20", now: 13)
        XCTAssertNil(memory.continuation(for: "field@9", now: 14))
        XCTAssertEqual(memory.continuation(for: "field@20", now: 14)?.list?.nextNumber, 3)
        XCTAssertNil(memory.continuation(for: "different-field@20", now: 14))
        XCTAssertNil(memory.continuation(for: "in-app-test", now: 14))
    }

    func testContinuationMemoryIsBoundedExpiresAndCanBeCleared() {
        var memory = DictationContinuationMemory<String>(lifetime: 10, capacity: 2)
        let state = compose("Make a list. One, apples.").continuation
        memory.remember(state, for: "first", now: 0)
        memory.remember(state, for: "second", now: 1)
        memory.remember(state, for: "third", now: 2)
        XCTAssertNil(memory.continuation(for: "first", now: 3))
        XCTAssertNotNil(memory.continuation(for: "second", now: 10))
        XCTAssertNil(memory.continuation(for: "second", now: 11))
        XCTAssertNotNil(memory.continuation(for: "third", now: 11))
        memory.removeAll()
        XCTAssertNil(memory.continuation(for: "third", now: 11))

        memory.remember(state, for: "first", now: 20)
        memory.remember(nil, for: "first", now: 21)
        XCTAssertNil(memory.continuation(for: "first", now: 21))
        memory.remember(state, for: "first", now: 30)
        XCTAssertNil(memory.continuation(for: "first", now: 29))
    }
}
