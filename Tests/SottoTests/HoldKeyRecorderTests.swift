import CoreGraphics
import XCTest
@testable import Sotto

@MainActor
private final class ScheduledRecorderCall {
    let action: @MainActor () -> Void
    var cancelled = false
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @MainActor func fire() {
        if !cancelled { action() }
    }
}

@MainActor
private final class RecorderFixture {
    var listener: (@MainActor (HoldKeyRecorder.Input) -> Void)?
    var delays: [ScheduledRecorderCall] = []
    var captured: [HoldKey] = []
    var timedOut = 0
    var cancelled = 0
    lazy var recorder: HoldKeyRecorder = {
        let recorder = HoldKeyRecorder(environment: .init(
            listen: { [weak self] handler in
                self?.listener = handler
                return HotkeyCancellation { self?.listener = nil }
            },
            delay: { [weak self] action in
                let call = ScheduledRecorderCall(action)
                self?.delays.append(call)
                return HotkeyCancellation { call.cancelled = true }
            }
        ))
        recorder.onCapture = { [weak self] in self?.captured.append($0) }
        recorder.onTimeout = { [weak self] in self?.timedOut += 1 }
        recorder.onCancel = { [weak self] in self?.cancelled += 1 }
        return recorder
    }()

    func press(_ key: HoldKey) { listener?(.key(key, down: true)) }
    func release(_ key: HoldKey) { listener?(.key(key, down: false)) }
    func escape() { listener?(.escape) }
    func fireTimeout() { delays.first { !$0.cancelled }?.fire() }
}

@MainActor
final class HoldKeyRecorderTests: XCTestCase {
    func testStartInstallsListenerAndTimeout() {
        let fixture = RecorderFixture()
        XCTAssertNil(fixture.listener)
        fixture.recorder.start()
        XCTAssertTrue(fixture.recorder.isRecording)
        XCTAssertNotNil(fixture.listener)
        XCTAssertEqual(fixture.delays.count, 1)
    }

    func testCaptureReportsKeyAndStopsRecording() {
        let fixture = RecorderFixture()
        fixture.recorder.start()
        fixture.press(.rightControl)
        XCTAssertEqual(fixture.captured, [.rightControl])
        XCTAssertFalse(fixture.recorder.isRecording)
        fixture.press(.fn)
        XCTAssertEqual(fixture.captured, [.rightControl], "A stopped recorder must not capture again")
    }

    func testModifierReleaseDoesNotCapture() {
        let fixture = RecorderFixture()
        fixture.recorder.start()
        // A key held before recording started reports only its release edge.
        fixture.release(.rightOption)
        XCTAssertEqual(fixture.captured, [])
        XCTAssertTrue(fixture.recorder.isRecording)
        fixture.press(.rightOption)
        XCTAssertEqual(fixture.captured, [.rightOption], "A later real press still captures")
    }

    func testTimeoutStopsRecordingWithoutCapture() {
        let fixture = RecorderFixture()
        fixture.recorder.start()
        fixture.fireTimeout()
        XCTAssertEqual(fixture.captured, [])
        XCTAssertEqual(fixture.timedOut, 1)
        XCTAssertFalse(fixture.recorder.isRecording)
    }

    func testStopCancelsPendingTimeout() {
        let fixture = RecorderFixture()
        fixture.recorder.start()
        fixture.recorder.stop()
        fixture.fireTimeout()
        XCTAssertEqual(fixture.timedOut, 0)
        fixture.recorder.start()
        XCTAssertTrue(fixture.recorder.isRecording)
        fixture.press(.rightOption)
        XCTAssertEqual(fixture.captured, [.rightOption])
    }

    func testEscapeCancelsWithoutCaptureOrTimeout() {
        let fixture = RecorderFixture()
        fixture.recorder.start()
        fixture.escape()
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertEqual(fixture.cancelled, 1)
        XCTAssertNil(fixture.listener)
        fixture.fireTimeout()
        fixture.press(.rightOption)
        fixture.escape()
        XCTAssertEqual(fixture.timedOut, 0)
        XCTAssertEqual(fixture.captured, [])
        XCTAssertEqual(fixture.cancelled, 1)
    }

    func testStartWhileRecordingIsIdempotent() {
        let fixture = RecorderFixture()
        fixture.recorder.start()
        fixture.recorder.start()
        XCTAssertEqual(fixture.delays.count, 1)
        fixture.press(.fn)
        XCTAssertEqual(fixture.captured, [.fn])
    }

    func testKeyCodeMappingCoversSupportedKeys() {
        XCTAssertEqual(HoldKey(keyCode: HoldKey.rightOption.keyCode), .rightOption)
        XCTAssertEqual(HoldKey(keyCode: HoldKey.rightControl.keyCode), .rightControl)
        XCTAssertEqual(HoldKey(keyCode: HoldKey.fn.keyCode), .fn)
        XCTAssertNil(HoldKey(keyCode: 0), "Ordinary keys must not be recordable as holds")
    }
}
