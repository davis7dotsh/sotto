import CoreGraphics
import XCTest
@testable import Sotto

final class HotkeyMonitorTests: XCTestCase {
    func testSelectedHIDFlagsSkipKeyStateFallback() {
        let keysAndFlags: [(HoldKey, CGEventFlags)] = [
            (.rightOption, CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)),
            (.rightControl, CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)),
            (.fn, .maskSecondaryFn),
        ]
        for (key, flags) in keysAndFlags {
            var reads = 0
            func keyState() -> Bool { reads += 1; return false }

            XCTAssertTrue(key.isPhysicallyDown(in: flags, keyState: keyState()), "\(key)")
            XCTAssertEqual(reads, 0, "A selected HID flag must not require keyState")
        }
    }

    func testModifierKeyStateFallbackPreservesSideSpecificDetection() {
        let keysAndFlags: [(HoldKey, CGEventFlags, CGEventFlags)] = [
            (.rightOption, .maskAlternate, CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)),
            (.rightControl, .maskControl, CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x01)),
        ]
        for (key, generic, left) in keysAndFlags {
            for flags in [CGEventFlags(), generic, left] {
                XCTAssertFalse(key.isPhysicallyDown(in: flags, keyState: false), "\(key): \(flags)")
                var reads = 0
                func keyState() -> Bool { reads += 1; return true }

                XCTAssertTrue(key.isPhysicallyDown(in: flags, keyState: keyState()), "\(key): \(flags)")
                XCTAssertEqual(reads, 1, "Without the selected HID flag, query the selected key")
            }
        }
    }

    func testFnPhysicalStateNeverFallsBackToKeyState() {
        var reads = 0
        func keyState() -> Bool { reads += 1; return true }

        XCTAssertFalse(HoldKey.fn.isPhysicallyDown(in: [], keyState: keyState()))
        XCTAssertFalse(HoldKey.fn.isPhysicallyDown(in: .maskAlternate, keyState: keyState()))
        XCTAssertEqual(reads, 0)
    }

    @MainActor
    func testModifierHIDFlagsSurviveWatchdogAndRecoverMissedReleaseWhenKeyStateReportsUp() async throws {
        for key in [HoldKey.rightOption, .rightControl] {
            var hardwareFlags: CGEventFlags = []
            let fixture = HotkeyFixture(key: key, isKeyDown: {
                $0.isPhysicallyDown(in: hardwareFlags, keyState: false)
            })
            XCTAssertTrue(fixture.monitor.start())
            defer { fixture.monitor.stop() }

            fixture.setPhysicalHold(true)
            hardwareFlags = fixture.flags
            try fixture.flagsChanged()
            let delay = try XCTUnwrap(fixture.delays.last)
            let watchdog = try XCTUnwrap(fixture.timers.last { $0.interval == 0.12 }?.call)
            // The real watchdog fires at 120 ms, before the 180 ms debounce.
            watchdog.fire()
            XCTAssertFalse(delay.cancelled, "HID flags still show \(key) held despite keyState=false")
            XCTAssertEqual(fixture.presses, 0)
            delay.fire()
            delay.fire(evenIfCancelled: true)
            watchdog.fire()
            XCTAssertEqual(fixture.presses, 1)
            XCTAssertEqual(fixture.releases, 0)
            XCTAssertEqual(fixture.cancels, 0)

            // Hardware release without any delivered event must still stop capture.
            hardwareFlags = []
            watchdog.fire()
            XCTAssertEqual(fixture.releases, 1)
            watchdog.fire(evenIfCancelled: true)
            try fixture.release()
            XCTAssertEqual(fixture.releases, 1, "A late release event must not submit twice")

            // A missed quick release before debounce must not accept a stale press.
            fixture.setPhysicalHold(true)
            hardwareFlags = fixture.flags
            try fixture.flagsChanged()
            let quickDelay = try XCTUnwrap(fixture.delays.last)
            hardwareFlags = []
            try XCTUnwrap(fixture.timers.last { $0.interval == 0.12 }?.call).fire()
            quickDelay.fire(evenIfCancelled: true)
            XCTAssertEqual(fixture.presses, 1)
            XCTAssertEqual(fixture.releases, 1)
            XCTAssertEqual(fixture.cancels, 0)
        }
    }

    @MainActor
    func testAlreadyHeldModifierHIDFlagsRequireFreshReleaseAfterStartAndTapRecovery() async throws {
        let keysAndFlags: [(HoldKey, CGEventFlags)] = [
            (.rightOption, CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)),
            (.rightControl, CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)),
        ]
        for (key, heldFlags) in keysAndFlags {
            var hardwareFlags = heldFlags
            let fixture = HotkeyFixture(key: key, isKeyDown: {
                $0.isPhysicallyDown(in: hardwareFlags, keyState: false)
            })
            XCTAssertTrue(fixture.monitor.start())
            defer { fixture.monitor.stop() }
            try fixture.press()
            fixture.timers.last { $0.interval == 0.12 }?.call.fire()
            XCTAssertTrue(fixture.delays.isEmpty, "Starting mid-hold must require a new press")
            XCTAssertEqual(fixture.presses, 0)

            hardwareFlags = []
            try fixture.release()
            hardwareFlags = heldFlags
            try fixture.press()
            let acceptedDelay = try XCTUnwrap(fixture.delays.last)
            acceptedDelay.fire()
            XCTAssertEqual(fixture.presses, 1)

            // Recovery cancels the accepted hold while HID flags still report it down.
            try XCTUnwrap(fixture.taps.first).enabled = false
            fixture.healthCheck()
            try fixture.flagsChanged()
            fixture.timers.last { $0.interval == 0.12 }?.call.fire()
            acceptedDelay.fire(evenIfCancelled: true)
            XCTAssertEqual(fixture.delays.count, 1)
            XCTAssertEqual(fixture.presses, 1)
            XCTAssertEqual(fixture.cancels, 1)
            XCTAssertEqual(fixture.releases, 0)

            hardwareFlags = []
            try fixture.release()
            hardwareFlags = heldFlags
            try fixture.press()
            try XCTUnwrap(fixture.delays.last).fire()
            hardwareFlags = []
            try fixture.release()
            XCTAssertEqual(fixture.presses, 2)
            XCTAssertEqual(fixture.releases, 1)
        }
    }

    @MainActor
    func testFnStartsOnTheFirstEventWithoutDebounceOrHardwarePolling() async throws {
        for type in [CGEventType.flagsChanged, .keyDown] {
            let fixture = HotkeyFixture(key: .fn)
            XCTAssertTrue(fixture.monitor.start())
            defer { fixture.monitor.stop() }
            let physicalReads = fixture.physicalReads

            // The delivered Fn edge can precede the hardware-state snapshot.
            fixture.flags = .maskSecondaryFn
            try fixture.send(type, code: HoldKey.fn.keyCode)
            XCTAssertEqual(fixture.presses, 1)
            XCTAssertTrue(fixture.delays.isEmpty)
            XCTAssertEqual(fixture.physicalReads, physicalReads)

            try fixture.release()
            XCTAssertEqual(fixture.releases, 1)
        }
    }

    @MainActor
    func testFnRapidReleaseAndCompanionEventsAreIdempotent() async throws {
        let fixture = HotkeyFixture(key: .fn)
        XCTAssertTrue(fixture.monitor.start())
        defer { fixture.monitor.stop() }

        fixture.setPhysicalHold(true)
        try fixture.send(.keyDown, code: HoldKey.fn.keyCode)
        try fixture.flagsChanged()
        try fixture.send(.keyDown, code: HoldKey.fn.keyCode)
        XCTAssertEqual(fixture.presses, 1)

        fixture.setPhysicalHold(false)
        try fixture.send(.keyUp, code: HoldKey.fn.keyCode)
        XCTAssertEqual(fixture.releases, 1, "A quick Fn keyUp must not wait for flagsChanged or a timer")
        try fixture.flagsChanged()
        try fixture.send(.keyDown, code: HoldKey.fn.keyCode)
        fixture.setPhysicalHold(true)
        try fixture.send(.keyDown, code: HoldKey.fn.keyCode, isRepeat: true)
        XCTAssertEqual(fixture.presses, 1, "Late flag-less companions and repeats must not restart a released hold")
        try fixture.release()
        XCTAssertEqual(fixture.releases, 1)

        try fixture.press()
        try fixture.release()
        XCTAssertEqual(fixture.presses, 2)
        XCTAssertEqual(fixture.releases, 2)
        XCTAssertEqual(fixture.cancels, 0)
        XCTAssertTrue(fixture.delays.isEmpty)
    }

    @MainActor
    func testFnHoldSurvivesNavigationUntilItsOwnRelease() async throws {
        let navigation: [(CGEventType, CGKeyCode, CGEventFlags)] = [
            (.leftMouseDown, 0, []),
            (.rightMouseDown, 0, []),
            (.otherMouseDown, 0, []),
            (.scrollWheel, 0, []),
            (.mouseMoved, 0, []),
            (.leftMouseDragged, 0, []),
            (.keyDown, 0, .maskSecondaryFn), // Type while talking.
            (.keyUp, 0, []),
            (.flagsChanged, 56, [.maskSecondaryFn, .maskShift]),
            (.flagsChanged, 56, []), // Other modifiers may omit Fn from their flags.
            (.flagsChanged, 55, .maskCommand),
            (.keyDown, 48, .maskCommand), // Switch apps without ending the take.
            (.flagsChanged, 55, []),
            (.keyDown, 53, []), // Escape belongs to the focused app during a hold.
        ]
        for releaseType in [CGEventType.flagsChanged, .keyUp] {
            let fixture = HotkeyFixture(key: .fn)
            XCTAssertTrue(fixture.monitor.start())
            defer { fixture.monitor.stop() }

            try fixture.press()
            XCTAssertEqual(fixture.presses, 1)
            for (type, code, flags) in navigation {
                fixture.flags = flags
                try fixture.send(type, code: code)
                fixture.timers.last { $0.interval == 0.12 }?.call.fire()
                XCTAssertTrue(fixture.monitor.isHoldingFn, "Unrelated input must not dismiss the recording")
                XCTAssertEqual(fixture.cancels, 0)
                XCTAssertEqual(fixture.releases, 0)
            }
            fixture.flags = .maskSecondaryFn
            try fixture.flagsChanged()
            try fixture.send(.keyDown, code: HoldKey.fn.keyCode)
            XCTAssertEqual(fixture.presses, 1)

            fixture.setPhysicalHold(false)
            try fixture.send(releaseType, code: HoldKey.fn.keyCode)
            try fixture.flagsChanged() // A companion release must not submit twice.
            XCTAssertFalse(fixture.monitor.isHoldingFn)
            XCTAssertEqual(fixture.cancels, 0)
            XCTAssertEqual(fixture.releases, 1)

            try fixture.press()
            try fixture.release()
            XCTAssertEqual(fixture.presses, 2)
            XCTAssertEqual(fixture.releases, 2)
        }
    }

    @MainActor
    func testFnWatchdogRecoversAMissedReleaseAfterNavigation() async throws {
        let fixture = HotkeyFixture(key: .fn)
        XCTAssertTrue(fixture.monitor.start())
        defer { fixture.monitor.stop() }

        try fixture.press()
        fixture.flags = []
        try fixture.send(.leftMouseDown, code: 0)
        try fixture.send(.scrollWheel, code: 0)
        let watchdog = try XCTUnwrap(fixture.timers.last { $0.interval == 0.12 }?.call)
        watchdog.fire()
        XCTAssertTrue(fixture.monitor.isHoldingFn)

        fixture.setPhysicalHold(false)
        watchdog.fire()
        XCTAssertFalse(fixture.monitor.isHoldingFn)
        XCTAssertEqual(fixture.releases, 1, "Lost key-up events must not leave the microphone recording")
        XCTAssertEqual(fixture.cancels, 0)
        try fixture.release()
        XCTAssertEqual(fixture.releases, 1)

        try fixture.send(.keyDown, code: 53)
        XCTAssertEqual(fixture.cancels, 1, "Escape remains available to cancel processing after release")
    }

    @MainActor
    func testFnDoesNotStartWithAnotherModifierAlreadyHeld() async throws {
        for type in [CGEventType.flagsChanged, .keyDown] {
            let fixture = HotkeyFixture(key: .fn)
            XCTAssertTrue(fixture.monitor.start())
            defer { fixture.monitor.stop() }

            fixture.setPhysicalHold(true)
            fixture.flags.insert(.maskCommand)
            try fixture.send(type, code: HoldKey.fn.keyCode)
            fixture.flags.remove(.maskCommand)
            try fixture.flagsChanged()
            try fixture.release()
            XCTAssertEqual(fixture.presses, 0)
            XCTAssertEqual(fixture.releases, 0)

            try fixture.press()
            XCTAssertEqual(fixture.presses, 1)
        }
    }

    @MainActor
    func testEndingFnShortcutCheckKeepsItsReleaseLatchThroughTapRecovery() async throws {
        let fixture = HotkeyFixture(key: .fn)
        XCTAssertTrue(fixture.monitor.start())
        defer { fixture.monitor.stop() }

        try fixture.press()
        let previousWatchdog = try XCTUnwrap(fixture.timers.first { $0.interval == 0.12 }?.call)
        fixture.down = false
        fixture.monitor.requireFreshHold()
        previousWatchdog.fire(evenIfCancelled: true)
        try XCTUnwrap(fixture.taps.first).valid = false
        fixture.healthCheck()
        try fixture.flagsChanged()
        try fixture.send(.keyDown, code: HoldKey.fn.keyCode)
        XCTAssertEqual(fixture.taps.count, 2)
        XCTAssertEqual(fixture.presses, 1, "Ending an audio-free check while Fn is held must not start recording")
        XCTAssertEqual(fixture.cancels, 1)
        XCTAssertEqual(fixture.releases, 0)

        try fixture.release()
        try fixture.press()
        try fixture.release()
        XCTAssertEqual(fixture.presses, 2)
        XCTAssertEqual(fixture.releases, 1)
        XCTAssertTrue(fixture.delays.isEmpty)
    }

    @MainActor
    func testAlreadyHeldFnAndTapRecoveryBothRequireAFreshRelease() async throws {
        let fixture = HotkeyFixture(key: .fn)
        fixture.setPhysicalHold(true)
        XCTAssertTrue(fixture.monitor.start())
        defer { fixture.monitor.stop() }
        try fixture.flagsChanged()
        try fixture.send(.keyDown, code: HoldKey.fn.keyCode)
        XCTAssertEqual(fixture.presses, 0)

        try fixture.release()
        try fixture.press()
        fixture.down = false // Recovery must retain the observed Fn hold even if HID polling lags.
        try XCTUnwrap(fixture.taps.first).enabled = false
        XCTAssertTrue(fixture.monitor.start())
        try fixture.flagsChanged()
        try fixture.send(.keyDown, code: HoldKey.fn.keyCode)
        try fixture.release()
        XCTAssertEqual(fixture.presses, 1)
        XCTAssertEqual(fixture.cancels, 1)
        XCTAssertEqual(fixture.releases, 0)

        try fixture.press()
        try fixture.release()
        XCTAssertEqual(fixture.presses, 2)
        XCTAssertEqual(fixture.releases, 1)
    }

    @MainActor
    func testChangingFromADebouncedKeyToFnCannotReviveTheOldCallback() async throws {
        let fixture = HotkeyFixture()
        XCTAssertTrue(fixture.monitor.start())
        defer { fixture.monitor.stop() }
        try fixture.press()
        let stale = try XCTUnwrap(fixture.delays.last)
        fixture.setPhysicalHold(false)
        fixture.monitor.key = .fn
        stale.fire(evenIfCancelled: true)
        XCTAssertEqual(fixture.presses, 0)

        try fixture.press()
        stale.fire(evenIfCancelled: true)
        XCTAssertEqual(fixture.presses, 1)
        try fixture.release()
        stale.fire(evenIfCancelled: true)
        XCTAssertEqual(fixture.presses, 1)
        XCTAssertEqual(fixture.releases, 1)
        XCTAssertEqual(fixture.delays.count, 1, "Fn must not schedule another delayed callback")
    }

    @MainActor
    func testRightOptionAndControlStillRequireTheirDebounce() async throws {
        for key in [HoldKey.rightOption, .rightControl] {
            let fixture = HotkeyFixture(key: key)
            XCTAssertTrue(fixture.monitor.start())
            defer { fixture.monitor.stop() }
            try fixture.press()
            XCTAssertEqual(fixture.presses, 0)
            try XCTUnwrap(fixture.delays.last).fire()
            XCTAssertEqual(fixture.presses, 1)
            try fixture.release()
            XCTAssertEqual(fixture.releases, 1)
        }
    }

    @MainActor
    func testEndingShortcutCheckRequiresReleaseAndNewHoldBeforeRecordingCanResume() async throws {
        for alreadyAccepted in [false, true] {
            let fixture = HotkeyFixture()
            XCTAssertTrue(fixture.monitor.start())
            defer { fixture.monitor.stop() }

            try fixture.press()
            let previousDelay = try XCTUnwrap(fixture.delays.last)
            let previousWatchdog = try XCTUnwrap(fixture.timers.first { $0.interval == 0.12 }?.call)
            if alreadyAccepted { previousDelay.fire() }
            // The check times out while the event-reported modifier is held.
            // A transient false hardware read must not erase that observation.
            fixture.down = false
            fixture.monitor.requireFreshHold()
            previousWatchdog.fire(evenIfCancelled: true)
            try fixture.flagsChanged()
            XCTAssertEqual(fixture.releases, 0, "A false HID read must not release the latched hold")
            let originalTap = try XCTUnwrap(fixture.taps.first)
            originalTap.valid = false
            fixture.healthCheck()
            XCTAssertEqual(fixture.taps.count, 2, "The release latch must survive rebuilding an invalid tap")
            fixture.down = true
            previousDelay.fire(evenIfCancelled: true)
            try fixture.flagsChanged()
            try fixture.send(.keyDown, code: HoldKey.rightOption.keyCode)
            fixture.delays.last?.fire(evenIfCancelled: true)
            XCTAssertEqual(fixture.delays.count, 1, "A still-held modifier must not start a new debounce")
            XCTAssertEqual(fixture.presses, alreadyAccepted ? 1 : 0)
            XCTAssertEqual(fixture.cancels, alreadyAccepted ? 1 : 0)

            try fixture.release()
            XCTAssertEqual(fixture.releases, 0, "Ending a shortcut check must not submit the previous hold")
            try fixture.press()
            fixture.delays.last?.fire()
            try fixture.release()
            XCTAssertEqual(fixture.presses, alreadyAccepted ? 2 : 1)
            XCTAssertEqual(fixture.releases, 1)
        }
    }

    @MainActor
    func testCompanionModifierKeyDownDoesNotCancelItsOwnHold() async throws {
        let fixture = HotkeyFixture()
        XCTAssertTrue(fixture.monitor.start())
        defer { fixture.monitor.stop() }

        try fixture.press() // The modifier first reports flagsChanged.
        try fixture.send(.keyDown, code: HoldKey.rightOption.keyCode)
        let delay = try XCTUnwrap(fixture.delays.last)
        XCTAssertFalse(delay.cancelled, "A companion keyDown for Right Option is not an Option chord")
        XCTAssertEqual(fixture.presses, 0, "The companion must not bypass the hold debounce")
        delay.fire()
        XCTAssertEqual(fixture.presses, 1)

        fixture.setPhysicalHold(false)
        try fixture.send(.keyUp, code: HoldKey.rightOption.keyCode)
        try fixture.flagsChanged()
        XCTAssertEqual(fixture.releases, 1)
        XCTAssertEqual(fixture.cancels, 0)
    }

    @MainActor
    func testOrdinaryChordStillCancelsAfterCompanionModifierEvent() async throws {
        for alreadyAccepted in [false, true] {
            let fixture = HotkeyFixture()
            XCTAssertTrue(fixture.monitor.start())
            defer { fixture.monitor.stop() }

            try fixture.press()
            try fixture.send(.keyDown, code: HoldKey.rightOption.keyCode)
            let delay = try XCTUnwrap(fixture.delays.last)
            if alreadyAccepted { delay.fire() }
            try fixture.send(.keyDown, code: 0) // Option+A remains an ordinary shortcut.
            delay.fire(evenIfCancelled: true)
            fixture.setPhysicalHold(false)
            try fixture.send(.keyUp, code: HoldKey.rightOption.keyCode)
            try fixture.flagsChanged()

            XCTAssertEqual(fixture.presses, alreadyAccepted ? 1 : 0)
            XCTAssertEqual(fixture.cancels, alreadyAccepted ? 1 : 0)
            XCTAssertEqual(fixture.releases, 0, "A real chord cancels rather than submits the hold")
        }
    }

    @MainActor
    func testChangedListeningGrantRecreatesTapAndRequiresFreshRelease() async throws {
        let fixture = HotkeyFixture()
        fixture.permissions = PermissionSnapshot(microphone: true, accessibility: false, inputMonitoring: true)
        XCTAssertTrue(fixture.monitor.start())
        let original = try XCTUnwrap(fixture.taps.first)

        fixture.permissions = PermissionSnapshot(microphone: true, accessibility: true, inputMonitoring: true)
        fixture.setPhysicalHold(true)
        fixture.healthCheck()
        XCTAssertEqual(fixture.taps.count, 2)
        XCTAssertEqual(original.invalidations, 1)
        try fixture.flagsChanged()
        XCTAssertTrue(fixture.delays.isEmpty, "Recreating a tap mid-hold must not activate the microphone")

        try fixture.release()
        try fixture.press()
        fixture.delays.last?.fire()
        try fixture.release()
        XCTAssertEqual(fixture.presses, 1)
        XCTAssertEqual(fixture.releases, 1)
        fixture.monitor.stop()
    }

    @MainActor
    func testStartCancelsActiveHoldBeforeReenablingDisabledTap() async throws {
        let fixture = HotkeyFixture()
        XCTAssertTrue(fixture.monitor.start())
        try fixture.press()
        fixture.delays.last?.fire()
        XCTAssertEqual(fixture.presses, 1)

        let tap = try XCTUnwrap(fixture.taps.first)
        tap.enabled = false
        XCTAssertTrue(fixture.monitor.start())
        XCTAssertEqual(fixture.cancels, 1)
        XCTAssertEqual(fixture.taps.count, 1, "A valid disabled port can be safely re-enabled")
        try fixture.flagsChanged()
        fixture.delays.last?.fire(evenIfCancelled: true)
        try fixture.release()
        XCTAssertEqual(fixture.presses, 1)
        XCTAssertEqual(fixture.releases, 0, "Cancelled speech must not be submitted on release")

        try fixture.press()
        fixture.delays.last?.fire()
        try fixture.release()
        XCTAssertEqual(fixture.presses, 2)
        XCTAssertEqual(fixture.releases, 1)
        fixture.monitor.stop()
    }

    @MainActor
    func testTapAndPermissionRecoveryPreserveAudioWhileEscapeIsExplicitDiscard() async throws {
        let fixture = HotkeyFixture()
        var interruptions = 0
        fixture.monitor.onInterruption = { interruptions += 1 }
        XCTAssertTrue(fixture.monitor.start())
        defer { fixture.monitor.stop() }
        try fixture.press()
        fixture.delays.last?.fire()
        try XCTUnwrap(fixture.taps.first).enabled = false
        XCTAssertTrue(fixture.monitor.start())
        XCTAssertEqual(interruptions, 1)
        XCTAssertEqual(fixture.cancels, 0, "Tap recovery cannot discard a recording")
        try fixture.release()

        try fixture.press()
        fixture.delays.last?.fire()
        try fixture.send(.keyDown, code: 53)
        XCTAssertEqual(fixture.cancels, 1, "Escape explicitly discards an accepted Option hold")
        XCTAssertEqual(interruptions, 1)
        try fixture.release()

        try fixture.press()
        fixture.delays.last?.fire()
        fixture.permissions = PermissionSnapshot(microphone: true, accessibility: false, inputMonitoring: false)
        fixture.healthCheck()
        XCTAssertEqual(interruptions, 2)
        XCTAssertEqual(fixture.cancels, 1, "Permission loss preserves the captured prefix")
    }

    @MainActor
    func testIdleHealthRepairsInvalidTapWithoutPollingForKeyPresses() async throws {
        let fixture = HotkeyFixture()
        XCTAssertTrue(fixture.monitor.start())
        let original = try XCTUnwrap(fixture.taps.first)
        let initialPhysicalReads = fixture.physicalReads
        fixture.healthCheck()
        fixture.healthCheck()
        XCTAssertEqual(fixture.physicalReads, initialPhysicalReads)

        original.valid = false
        fixture.healthCheck()
        XCTAssertEqual(fixture.taps.count, 2, "An invalid idle port must recover without an app activation")
        XCTAssertEqual(fixture.presses, 0)
        try fixture.press()
        fixture.delays.last?.fire()
        try fixture.release()
        XCTAssertEqual(fixture.presses, 1)
        fixture.monitor.stop()
    }

    @MainActor
    func testRevokedPermissionCancelsCaptureAndPublishesHealthChanges() async throws {
        let fixture = HotkeyFixture()
        XCTAssertTrue(fixture.monitor.start())
        try fixture.press()
        fixture.delays.last?.fire()

        fixture.permissions = PermissionSnapshot(microphone: true, accessibility: false, inputMonitoring: false)
        fixture.healthCheck()
        XCTAssertEqual(fixture.cancels, 1)
        XCTAssertEqual(fixture.statuses, [true, false])
        XCTAssertFalse(try XCTUnwrap(fixture.taps.first).valid)

        fixture.setPhysicalHold(false)
        fixture.permissions = PermissionSnapshot(microphone: true, accessibility: true, inputMonitoring: false)
        fixture.healthCheck()
        XCTAssertEqual(fixture.statuses, [true, false, true])
        XCTAssertEqual(fixture.taps.count, 2)
        XCTAssertEqual(fixture.presses, 1, "Regranting permission must not synthesize a hold")
        fixture.monitor.stop()
    }

    @MainActor
    func testOptionChordAndCancelledDebounceCannotActivateASubsequentHold() async throws {
        let fixture = HotkeyFixture()
        XCTAssertTrue(fixture.monitor.start())
        try fixture.press()
        let cancelled = try XCTUnwrap(fixture.delays.last)
        try fixture.send(.keyDown, code: 0) // Option+A remains an ordinary shortcut.
        try fixture.release()
        cancelled.fire(evenIfCancelled: true)
        XCTAssertEqual(fixture.presses, 0)

        try fixture.press()
        let current = try XCTUnwrap(fixture.delays.last)
        cancelled.fire(evenIfCancelled: true)
        XCTAssertEqual(fixture.presses, 0, "A stale delayed callback must not bypass the new hold's debounce")
        current.fire()
        XCTAssertEqual(fixture.presses, 1)
        try fixture.release()
        XCTAssertEqual(fixture.releases, 1)
        fixture.monitor.stop()
    }

    @MainActor
    func testUnavailableTapRetriesInBackgroundButStopCancelsLateHealthCallbacks() async throws {
        let fixture = HotkeyFixture()
        fixture.canCreateTap = false
        XCTAssertFalse(fixture.monitor.start())
        XCTAssertTrue(fixture.taps.isEmpty)

        fixture.canCreateTap = true
        fixture.healthCheck()
        XCTAssertEqual(fixture.taps.count, 1)
        XCTAssertEqual(fixture.statuses, [false, true])
        fixture.permissions = PermissionSnapshot(microphone: false, accessibility: true, inputMonitoring: false)
        fixture.healthCheck()
        XCTAssertEqual(fixture.taps.count, 1, "Microphone access is not part of an event tap's permission fingerprint")

        fixture.monitor.stop()
        fixture.timers.first { $0.interval == 2 }?.call.fire(evenIfCancelled: true)
        try fixture.press()
        fixture.delays.last?.fire(evenIfCancelled: true)
        XCTAssertEqual(fixture.taps.count, 1)
        XCTAssertEqual(fixture.presses, 0)
        XCTAssertEqual(fixture.statuses, [false, true, false])
    }

    @MainActor
    func testDisabledTapDuringDebounceRequiresAnotherPhysicalHold() async throws {
        let fixture = HotkeyFixture()
        XCTAssertTrue(fixture.monitor.start())
        try fixture.press()
        try XCTUnwrap(fixture.taps.first).enabled = false
        fixture.delays.last?.fire()
        XCTAssertEqual(fixture.presses, 0)
        try fixture.flagsChanged()
        fixture.delays.last?.fire(evenIfCancelled: true)
        XCTAssertEqual(fixture.presses, 0)

        try fixture.release()
        try fixture.press()
        fixture.delays.last?.fire()
        XCTAssertEqual(fixture.presses, 1)
        fixture.monitor.stop()
    }
}

private final class FakeHotkeyTap {
    var valid = true
    var enabled = false
    var invalidations = 0

    var handle: HotkeyEventTap {
        HotkeyEventTap(
            isValid: { self.valid }, isEnabled: { self.enabled },
            setEnabled: { self.enabled = $0 && self.valid },
            lifetime: HotkeyCancellation {
                self.invalidations += 1
                self.valid = false
                self.enabled = false
            }
        )
    }
}

private final class ScheduledHotkeyCall {
    let action: @MainActor () -> Void
    var cancelled = false
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @MainActor func fire(evenIfCancelled: Bool = false) {
        if !cancelled || evenIfCancelled { action() }
    }
}

@MainActor
private final class HotkeyFixture {
    private let initialKey: HoldKey
    private let physicalStateQuery: ((HoldKey) -> Bool)?
    var permissions = PermissionSnapshot(microphone: true, accessibility: true, inputMonitoring: false)
    var down = false
    var flags: CGEventFlags = []
    var physicalReads = 0
    var canCreateTap = true
    var taps: [FakeHotkeyTap] = []
    var delays: [ScheduledHotkeyCall] = []
    var timers: [(interval: TimeInterval, call: ScheduledHotkeyCall)] = []
    var presses = 0
    var releases = 0
    var cancels = 0
    var statuses: [Bool] = []

    init(key: HoldKey = .rightOption, isKeyDown: ((HoldKey) -> Bool)? = nil) {
        initialKey = key
        physicalStateQuery = isKeyDown
    }

    lazy var monitor: HotkeyMonitor = {
        var environment = HotkeyMonitorEnvironment.live
        environment.permissions = { [unowned self] in permissions }
        environment.isKeyDown = { [unowned self] key in
            physicalReads += 1
            return physicalStateQuery?(key) ?? down
        }
        environment.flags = { [unowned self] in flags }
        environment.createTap = { [unowned self] _ in
            guard canCreateTap else { return nil }
            let tap = FakeHotkeyTap()
            taps.append(tap)
            return tap.handle
        }
        environment.delayPress = { [unowned self] action in
            let call = ScheduledHotkeyCall(action)
            delays.append(call)
            return HotkeyCancellation { call.cancelled = true }
        }
        environment.repeatingTimer = { [unowned self] interval, action in
            let call = ScheduledHotkeyCall(action)
            timers.append((interval, call))
            return HotkeyCancellation { call.cancelled = true }
        }
        let monitor = HotkeyMonitor(environment: environment)
        monitor.key = initialKey
        monitor.onPress = { [weak self] in self?.presses += 1 }
        monitor.onRelease = { [weak self] in self?.releases += 1 }
        monitor.onCancel = { [weak self] in self?.cancels += 1 }
        monitor.onStatusChange = { [weak self] in self?.statuses.append($0) }
        return monitor
    }()

    func healthCheck() { timers.first { $0.interval == 2 }?.call.fire() }
    func setPhysicalHold(_ isDown: Bool) {
        down = isDown
        guard isDown else { flags = []; return }
        switch monitor.key {
        case .rightOption: flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        case .rightControl: flags = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)
        case .fn: flags = .maskSecondaryFn
        }
    }
    func press() throws { setPhysicalHold(true); try flagsChanged() }
    func release() throws { setPhysicalHold(false); try flagsChanged() }
    func flagsChanged() throws { try send(.flagsChanged, code: monitor.key.keyCode) }
    func send(_ type: CGEventType, code: CGKeyCode, isRepeat: Bool = false) throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: type != .keyUp))
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
        monitor.receive(type: type, event: event) // Never posted to the OS.
    }
}
