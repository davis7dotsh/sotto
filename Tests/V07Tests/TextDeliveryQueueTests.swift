import AppKit
import XCTest
@testable import V07

final class TextDeliveryQueueTests: XCTestCase {
    @MainActor
    func testCaptureResumingDuringPreflightWaitsAndRevalidatesBeforeNativeInsertion() async {
        let fixture = QueuedDeliveryFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.captureOnValidation = 1
        let result = await fixture.deliver(strategy: .nativeSelection)
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(fixture.waitsDuringCapture, 1)
        XCTAssertEqual(fixture.validationReads, 2)
        XCTAssertEqual(fixture.nativeWrites, 1)
        XCTAssertEqual(fixture.pasteWrites, 0)
    }

    @MainActor
    func testCaptureResumingAfterClipboardStagingRestoresClipboardBeforeWaiting() async {
        let fixture = QueuedDeliveryFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.captureOnValidation = 2
        let result = await fixture.deliver(strategy: .keyboardPaste)
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(fixture.waitsDuringCapture, 1)
        XCTAssertEqual(fixture.clipboardWhileWaiting, "Original clipboard")
        XCTAssertEqual(fixture.validationReads, 4)
        XCTAssertEqual(fixture.pasteWrites, 1)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testCaptureResumingAfterNativeWriteDoesNotRetryInsertion() async {
        let fixture = QueuedDeliveryFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.captureOnConfirmation = true
        let result = await fixture.deliver(strategy: .nativeSelection)
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(fixture.waitsDuringCapture, 0)
        XCTAssertEqual(fixture.nativeWrites, 1)
    }

    @MainActor
    func testCaptureResumingAfterPasteDispatchDoesNotRetryInsertion() async {
        let fixture = QueuedDeliveryFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.captureOnConfirmation = true
        let result = await fixture.deliver(strategy: .keyboardPaste)
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(fixture.waitsDuringCapture, 0)
        XCTAssertEqual(fixture.pasteWrites, 1)
    }
}

/// Uses an isolated pasteboard and injected events; no hardware or AX access.
@MainActor
private final class QueuedDeliveryFixture {
    let pasteboard = NSPasteboard.withUniqueName()
    var captureActive = false
    var captureOnValidation: Int?
    var captureOnConfirmation = false
    var validationReads = 0
    var waitsDuringCapture = 0
    var clipboardWhileWaiting: String?
    var nativeWrites = 0
    var pasteWrites = 0

    init() { pasteboard.setString("Original clipboard", forType: .string) }

    func deliver(strategy: TextDeliveryStrategy) async -> InsertionOutcome {
        let environment = TextDeliveryEnvironment(
            validate: { [self] in
                validationReads += 1
                if validationReads == captureOnValidation { captureActive = true }
                return .valid
            },
            modifiersAreHeld: { [self] in captureActive },
            replaceSelection: { [self] _ in
                XCTAssertFalse(captureActive)
                nativeWrites += 1
                return .acknowledged
            },
            postPaste: { [self] canDispatch in
                XCTAssertFalse(captureActive)
                guard canDispatch() else { return .blocked(reason: "Not ready") }
                pasteWrites += 1
                return .sent
            },
            confirmation: { [self] _ in
                if captureOnConfirmation { captureActive = true }
                return .confirmed
            },
            pause: { _ in XCTFail("Capture must defer delivery without a modifier timeout") },
            waitUntilReady: { [self] in
                if captureActive {
                    waitsDuringCapture += 1
                    clipboardWhileWaiting = pasteboard.string(forType: .string)
                    captureActive = false
                }
            },
            isCaptureActive: { [self] in captureActive }
        )
        return await TextDeliveryTransaction(pasteboard: pasteboard, environment: environment)
            .deliver("Words", copying: "Words", strategy: strategy,
                     clipboardUnchangedSince: pasteboard.changeCount)
    }
}
