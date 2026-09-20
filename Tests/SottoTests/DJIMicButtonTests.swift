import XCTest
@testable import Sotto

final class DJIMicButtonTests: XCTestCase {
    func testOnlyKnownDJIVolumeEventsMatch() {
        for usage: UInt32 in [0xE9, 0xEA] {
            XCTAssertTrue(DJIMicButton.matches(vendorID: 0x2CA3, productID: 0x4011, usagePage: 0x0C, usage: usage))
            XCTAssertFalse(DJIMicButton.matches(vendorID: 0x05AC, productID: 0x4011, usagePage: 0x0C, usage: usage))
            XCTAssertFalse(DJIMicButton.matches(vendorID: 0x2CA3, productID: 0x9999, usagePage: 0x0C, usage: usage))
            XCTAssertFalse(DJIMicButton.matches(vendorID: 0x2CA3, productID: 0x4011, usagePage: 0x07, usage: usage))
        }
        XCTAssertFalse(DJIMicButton.matches(vendorID: 0x2CA3, productID: 0x4011, usagePage: 0x0C, usage: 0xE2))
    }

    func testPressReleaseRepeatAndCompanionUsageProduceOneToggle() {
        var state = DJIMicButtonPressState()
        XCTAssertFalse(state.receive(usage: 0xE9, value: 0, at: 0))
        XCTAssertTrue(state.receive(usage: 0xE9, value: 1, at: 1))
        XCTAssertFalse(state.receive(usage: 0xE9, value: 1, at: 2))
        XCTAssertFalse(state.receive(usage: 0xEA, value: 1, at: 2))
        XCTAssertFalse(state.receive(usage: 0xE9, value: 0, at: 3))
        XCTAssertFalse(state.receive(usage: 0xEA, value: 0, at: 3))
        XCTAssertTrue(state.receive(usage: 0xEA, value: 1, at: 4))
    }

    func testBounceDoesNotToggleAgainButNextDeliberatePressDoes() {
        var state = DJIMicButtonPressState()
        XCTAssertTrue(state.receive(usage: 0xE9, value: 1, at: 1))
        XCTAssertFalse(state.receive(usage: 0xE9, value: 0, at: 1.05))
        XCTAssertFalse(state.receive(usage: 0xEA, value: 1, at: 1.1))
        XCTAssertFalse(state.receive(usage: 0xEA, value: 0, at: 1.15))
        XCTAssertTrue(state.receive(usage: 0xE9, value: 1, at: 2))
    }

    func testAlreadyHeldButtonNeedsReleaseAndReceiversHaveIndependentState() {
        var held = DJIMicButtonPressState()
        held.seed(usage: 0xE9, isDown: true)
        XCTAssertFalse(held.receive(usage: 0xE9, value: 1, at: 1))
        var other = DJIMicButtonPressState()
        XCTAssertTrue(other.receive(usage: 0xE9, value: 1, at: 1))
        XCTAssertFalse(held.receive(usage: 0xE9, value: 0, at: 2))
        XCTAssertTrue(held.receive(usage: 0xEA, value: 1, at: 3))
    }

    func testUnknownUsageDoesNotHoldOrTriggerButton() {
        var state = DJIMicButtonPressState()
        XCTAssertFalse(state.receive(usage: 0xE2, value: 1, at: 1))
        XCTAssertTrue(state.receive(usage: 0xE9, value: 1, at: 1))
    }

    func testButtonOnlyFinishesItsOwnCaptureAndNeverInterruptsProcessing() {
        for activity in [DictationActivity.idle, .success, .failed] {
            XCTAssertEqual(DictationTrigger.djiButtonAction(deviceID: 1, activity: activity, current: nil), .start)
        }
        for activity in [DictationActivity.starting, .recording] {
            XCTAssertEqual(DictationTrigger.djiButtonAction(deviceID: 1, activity: activity, current: .dji(1)), .finish)
            for trigger in [DictationTrigger.keyboard, .test, .dji(2)] {
                XCTAssertEqual(DictationTrigger.djiButtonAction(deviceID: 1, activity: activity, current: trigger), .ignore)
            }
        }
        for activity in [DictationActivity.transcribing, .delivering] {
            XCTAssertEqual(DictationTrigger.djiButtonAction(deviceID: 1, activity: activity, current: .dji(1)), .ignore)
        }
    }
}
