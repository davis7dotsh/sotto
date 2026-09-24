import Foundation
import ApplicationServices
import XCTest
@testable import V07

final class InsertionPreparationTests: XCTestCase {
    func testReadyFieldAvoidsActivationAndWaiting() async {
        let fixture = PreparationFixture()
        fixture.readResult = .ready(42, capturedAt: 0)

        let result = await InsertionPreparation.capture(using: fixture.environment)

        XCTAssertEqual(result, .ready(42, capturedAt: 0))
        XCTAssertEqual(fixture.activationRequests, 0)
        XCTAssertEqual(fixture.pauses, 0)
    }

    func testDelayedRendererBecomesReadyAfterElectronDebounceWithOneActivation() async {
        let fixture = PreparationFixture()
        fixture.onRead = { fixture in
            fixture.now >= 2.1 ? .ready(42, capturedAt: fixture.now) : .unavailable
        }

        let result = await InsertionPreparation.capture(using: fixture.environment)

        guard case .ready(42, let capturedAt) = result else { return XCTFail("Renderer did not become ready") }
        XCTAssertGreaterThanOrEqual(capturedAt, 2.1)
        XCTAssertLessThanOrEqual(capturedAt, InsertionPreparation.readinessSeconds)
        XCTAssertEqual(fixture.activationRequests, 1, "Repeated requests would reset Electron's debounce")
        XCTAssertGreaterThan(fixture.reads, 2, "Supported mode must still wait for an actual field")
    }

    func testUnsupportedModeWriteRefreshesSafetyWithoutWaiting() async {
        let fixture = PreparationFixture()
        fixture.activation = InsertionAccessibilityPolicy.afterRead(.attributeUnsupported, enabled: nil)
            ?? InsertionAccessibilityPolicy.afterWrite(.attributeUnsupported)

        let result = await InsertionPreparation.capture(using: fixture.environment)

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(fixture.reads, 2)
        XCTAssertEqual(fixture.pauses, 0)
        XCTAssertEqual(fixture.now, 0)
    }

    func testUnreadableModeWithSuccessfulWriteEntersReadinessOnce() async {
        for read in [AXError.attributeUnsupported, .notImplemented] {
            let fixture = PreparationFixture()
            XCTAssertNil(InsertionAccessibilityPolicy.afterRead(read, enabled: nil))
            fixture.activation = InsertionAccessibilityPolicy.afterRead(read, enabled: nil)
                ?? InsertionAccessibilityPolicy.afterWrite(.success)
            fixture.onRead = { fixture in
                fixture.reads == 1 ? .unavailable : .ready(42, capturedAt: fixture.now)
            }

            let result = await InsertionPreparation.capture(using: fixture.environment)

            XCTAssertEqual(result, .ready(42, capturedAt: 0))
            XCTAssertEqual(fixture.activationRequests, 1)
            XCTAssertEqual(fixture.reads, 2)
        }
    }

    func testSupportedModeWithoutAnEditableFieldTimesOut() async {
        let fixture = PreparationFixture()

        let result = await InsertionPreparation.capture(using: fixture.environment)

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(fixture.activationRequests, 1)
        XCTAssertEqual(fixture.now, InsertionPreparation.readinessSeconds, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(fixture.pauses, 31)
    }

    func testProtectedAndUnknownInitialFieldsNeverActivate() async {
        for reason in ["Protected field", "Unverified field"] {
            let fixture = PreparationFixture()
            fixture.readResult = .blocked(reason: reason)

            let result = await InsertionPreparation.capture(using: fixture.environment)

            XCTAssertEqual(result, .blocked(reason: reason))
            XCTAssertEqual(fixture.activationRequests, 0)
            XCTAssertEqual(fixture.pauses, 0)
        }
    }

    func testChangedOwnerWindowPermissionOrProtectedFieldStopsPolling() async {
        for reason in ["Changed application", "Changed window", "Permission lost", "Protected field", "Unverified field"] {
            let fixture = PreparationFixture()
            fixture.onRead = { fixture in
                fixture.reads == 1 ? .unavailable : .blocked(reason: reason)
            }

            let result = await InsertionPreparation.capture(using: fixture.environment)

            XCTAssertEqual(result, .blocked(reason: reason))
            XCTAssertEqual(fixture.reads, 2)
            XCTAssertEqual(fixture.activationRequests, 1)
            XCTAssertEqual(fixture.pauses, 0)
        }
    }

    func testActivationFailureStopsWithoutPolling() async {
        let fixture = PreparationFixture()
        fixture.activation = .blocked(reason: "AX IPC failed")

        let result = await InsertionPreparation.capture(using: fixture.environment)

        XCTAssertEqual(result, .blocked(reason: "AX IPC failed"))
        XCTAssertEqual(fixture.reads, 1)
        XCTAssertEqual(fixture.pauses, 0)
    }

    func testOptionalModeReadFailureRechecksAndPreservesSafeClipboardFallback() async throws {
        let fixture = PreparationFixture()
        fixture.activation = try XCTUnwrap(InsertionAccessibilityPolicy.afterRead(.cannotComplete, enabled: nil))

        let result = await InsertionPreparation.capture(using: fixture.environment)

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(fixture.activation, .unavailable, "A mode IPC error is distinct from an unsupported capability")
        XCTAssertEqual(fixture.reads, 2, "Recheck field safety after slow optional mode IPC")
        XCTAssertEqual(fixture.activationRequests, 1)
        XCTAssertEqual(fixture.pauses, 0)
    }

    func testOptionalModeWriteFailureRechecksBeforeFallback() async {
        let fixture = PreparationFixture()
        fixture.activation = InsertionAccessibilityPolicy.afterWrite(.cannotComplete)

        let result = await InsertionPreparation.capture(using: fixture.environment)

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(fixture.reads, 2)
        XCTAssertEqual(fixture.pauses, 0)
    }

    func testUnavailableOrUnsupportedModeCannotMaskChangedOwnershipOrUnsafeFieldMetadata() async throws {
        for activation in [try XCTUnwrap(InsertionAccessibilityPolicy.afterRead(.cannotComplete, enabled: nil)),
                           InsertionAccessibilityPolicy.afterWrite(.attributeUnsupported)] {
            for reason in ["Changed application", "Changed window", "Permission lost", "Protected field", "Unverified field"] {
                let fixture = PreparationFixture()
                fixture.activation = activation
                fixture.onRead = { fixture in
                    fixture.reads == 1 ? .unavailable : .blocked(reason: reason)
                }

                let result = await InsertionPreparation.capture(using: fixture.environment)

                XCTAssertEqual(result, .blocked(reason: reason))
                XCTAssertEqual(fixture.reads, 2)
                XCTAssertEqual(fixture.pauses, 0)
            }
        }
    }

    func testModeQueryReportingDisabledAccessibilityIsBlocked() async throws {
        for activation in [try XCTUnwrap(InsertionAccessibilityPolicy.afterRead(.apiDisabled, enabled: nil)),
                           InsertionAccessibilityPolicy.afterWrite(.apiDisabled)] {
            let fixture = PreparationFixture()
            fixture.activation = activation

            let result = await InsertionPreparation.capture(using: fixture.environment)

            XCTAssertEqual(result, .blocked(reason: InsertionAccessibilityPolicy.accessUnavailable))
            XCTAssertEqual(fixture.reads, 1)
            XCTAssertEqual(fixture.pauses, 0)
        }
    }

    func testCancellationDuringModeFailureRefreshNeverReturnsATarget() async throws {
        let fixture = PreparationFixture()
        fixture.activation = try XCTUnwrap(InsertionAccessibilityPolicy.afterRead(.cannotComplete, enabled: nil))
        fixture.onRead = { fixture in
            guard fixture.reads > 1 else { return .unavailable }
            withUnsafeCurrentTask { $0?.cancel() }
            return .ready(42, capturedAt: fixture.now)
        }
        let task = Task { await InsertionPreparation.capture(using: fixture.environment) }

        let result = await task.value

        XCTAssertEqual(result, .blocked(reason: InsertionPreparation.cancelled))
        XCTAssertEqual(fixture.reads, 2)
    }

    func testRefreshedModeFailureSnapshotKeepsActualCursorTime() async throws {
        for capturedAt in [0.0, 4.0] {
            let fixture = PreparationFixture()
            fixture.activation = try XCTUnwrap(InsertionAccessibilityPolicy.afterRead(.cannotComplete, enabled: nil))
            fixture.onRead = { fixture in
                guard fixture.reads > 1 else { return .unavailable }
                fixture.cutoff.finish()
                fixture.advance(seconds: 4)
                return .ready(42, capturedAt: capturedAt)
            }

            let result = await InsertionPreparation.capture(using: fixture.environment)

            XCTAssertEqual(result, capturedAt == 0 ? .ready(42, capturedAt: 0) : .unavailable)
            XCTAssertEqual(InsertionCapturePolicy.permitsInsertion(capturedAt: capturedAt, releasedAt: 0.5), capturedAt == 0)
        }
    }

    func testReleaseBeforePreparationPreventsActivation() async {
        let fixture = PreparationFixture()
        fixture.cutoff.finish()

        let result = await InsertionPreparation.capture(using: fixture.environment)

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(fixture.activationRequests, 0)
        XCTAssertEqual(fixture.pauses, 0)
    }

    func testReleaseDuringWarmupStopsWithoutCapturingALaterField() async {
        let fixture = PreparationFixture()
        fixture.onPause = { fixture in fixture.cutoff.finish() }
        fixture.onRead = { fixture in
            fixture.now > 0 ? .ready(42, capturedAt: fixture.now) : .unavailable
        }

        let result = await InsertionPreparation.capture(using: fixture.environment)

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(fixture.reads, 2, "Release must stop the next field read")
        XCTAssertEqual(fixture.pauses, 1)
    }

    func testPreReleaseCursorSurvivesSlowerMetadataCompletion() async {
        let fixture = PreparationFixture()
        fixture.onRead = { fixture in
            guard fixture.reads > 1 else { return .unavailable }
            let capturedAt = fixture.now
            fixture.cutoff.finish()
            fixture.advance(seconds: 4)
            return .ready(42, capturedAt: capturedAt)
        }

        let result = await InsertionPreparation.capture(using: fixture.environment)

        XCTAssertEqual(result, .ready(42, capturedAt: 0))
        XCTAssertTrue(InsertionCapturePolicy.permitsInsertion(capturedAt: 0, releasedAt: 0))
    }

    func testActualLateCursorCannotBeBackdatedToTheReadAttempt() async {
        let fixture = PreparationFixture()
        fixture.onRead = { fixture in
            guard fixture.reads > 1 else { return .unavailable }
            fixture.advance(seconds: 4)
            return .ready(42, capturedAt: fixture.now)
        }

        let result = await InsertionPreparation.capture(using: fixture.environment)

        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(InsertionCapturePolicy.permitsInsertion(capturedAt: fixture.now, releasedAt: 0.5))
    }

    func testCancellationDuringReadNeverReturnsAReadyTarget() async {
        let fixture = PreparationFixture()
        fixture.onRead = { fixture in
            guard fixture.reads > 1 else { return .unavailable }
            withUnsafeCurrentTask { $0?.cancel() }
            return .ready(42, capturedAt: fixture.now)
        }
        let task = Task { await InsertionPreparation.capture(using: fixture.environment) }

        let result = await task.value

        XCTAssertEqual(result, .blocked(reason: InsertionPreparation.cancelled))
        XCTAssertEqual(fixture.reads, 2)
    }

    func testAlreadyCancelledPreparationDoesNotReadOrActivate() async {
        let fixture = PreparationFixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await InsertionPreparation.capture(using: fixture.environment)
        }

        let result = await task.value

        XCTAssertEqual(result, .blocked(reason: InsertionPreparation.cancelled))
        XCTAssertEqual(fixture.reads, 0)
        XCTAssertEqual(fixture.activationRequests, 0)
    }

    func testCancellationDuringPauseStopsPolling() async {
        let fixture = PreparationFixture()
        fixture.pauseError = CancellationError()

        let result = await InsertionPreparation.capture(using: fixture.environment)

        XCTAssertEqual(result, .blocked(reason: InsertionPreparation.cancelled))
        XCTAssertEqual(fixture.reads, 2)
        XCTAssertEqual(fixture.pauses, 1)
    }
}

/// One task owns this fixture. Sendable closures cross the detached preparation
/// boundary, but neither AX calls, real sleeps nor clipboard access are needed.
private final class PreparationFixture: @unchecked Sendable {
    let cutoff = InsertionCaptureCutoff()
    var readResult: InsertionPreparationRead<Int> = .unavailable
    var activation: InsertionAccessibilityActivation = .supported
    var onRead: (@Sendable (PreparationFixture) -> InsertionPreparationRead<Int>)?
    var onPause: (@Sendable (PreparationFixture) -> Void)?
    var pauseError: Error?
    private var nanoseconds: UInt64 = 0
    private(set) var reads = 0
    private(set) var activationRequests = 0
    private(set) var pauses = 0

    var now: TimeInterval { Double(nanoseconds) / 1_000_000_000 }

    func advance(seconds: TimeInterval) { nanoseconds += UInt64(seconds * 1_000_000_000) }

    var environment: InsertionPreparationEnvironment<Int> {
        InsertionPreparationEnvironment(
            read: { [self] in
                reads += 1
                return onRead?(self) ?? readResult
            },
            activate: { [self] in
                activationRequests += 1
                return activation
            },
            canWait: { [self] in cutoff.canWait },
            now: { [self] in now },
            pause: { [self] delay in
                pauses += 1
                if let pauseError { throw pauseError }
                nanoseconds += delay
                onPause?(self)
            }
        )
    }
}
