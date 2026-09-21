import AVFoundation
import CoreAudio
import Foundation
import SottoAPI
import XCTest
@testable import Sotto

final class RecordingSpoolTests: XCTestCase {
    private func makeSpool(root: URL) throws -> RecordingSpool {
        try RecordingSpool(directory: root.appendingPathComponent(UUID().uuidString),
                           snapshot: RecordingSnapshot(id: UUID(), requestID: UUID(),
                                                       device: DeviceIdentity(id: "device", name: "Test"), settings: .init()),
                           endpoint: URL(string: "http://localhost:8391")!, deviceIdentity: "device")
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-spool-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func chunk(frames: Int, channels: Int = 1, kind: CapturedAudioChunk.Kind = .normalized, sampleRate: Double = 16_000) -> CapturedAudioChunk {
        let samples = [Float](repeating: 0.125, count: frames * channels)
        return CapturedAudioChunk(kind: kind, data: samples.withUnsafeBytes { Data($0) }, sampleRate: sampleRate, channels: channels)
    }

    func testCommittedPCMRecoversAndLostAcknowledgmentReplayIsIdentical() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try makeSpool(root: root)
        try spool.beginCapture(originalSampleRate: 48_000, originalChannels: 2)
        try spool.append(chunk(frames: 1_600))
        try spool.append(chunk(frames: 4_800, channels: 2, kind: .original, sampleRate: 48_000))
        try spool.checkpoint()
        let first = try XCTUnwrap(spool.nextBatch(after: []))
        let continuationID = UUID()
        try spool.setContinuationID(continuationID)
        try spool.markDeliveryAttempted()
        let recovered = try XCTUnwrap(RecordingSpool.recover(in: root).first)
        XCTAssertFalse(recovered.isSealed)
        XCTAssertTrue(recovered.isPaused)
        XCTAssertTrue(recovered.deliveryAttempted)
        XCTAssertTrue(recovered.contextReady)
        XCTAssertEqual(recovered.continuationID, continuationID)
        XCTAssertEqual(recovered.finalManifest[0].inferenceFrames, 1_600)
        XCTAssertEqual(recovered.finalManifest[0].originalFrames, 4_800)
        let replay = try XCTUnwrap(recovered.nextBatch(after: []))
        XCTAssertEqual(first.header, replay.header)
        XCTAssertEqual(first.data, replay.data)
        var positions = recovered.checkpoints.filter { $0.kind == .inference }
        let original = try XCTUnwrap(recovered.nextBatch(after: positions))
        XCTAssertEqual(original.header.kind, .original)
        positions.append(contentsOf: recovered.checkpoints.filter { $0.kind == .original })
        XCTAssertNil(try recovered.nextBatch(after: positions))
        XCTAssertNotNil(recovered.interruption)
    }

    func testUncheckpointedSuffixIsIgnoredAndExplicitDiscardIsRequired() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try makeSpool(root: root)
        try spool.beginCapture(originalSampleRate: nil, originalChannels: nil)
        try spool.append(chunk(frames: 160))
        try spool.checkpoint()
        let run = try XCTUnwrap(spool.checkpoints.first?.runID)
        let streamDirectory = spool.directory.appendingPathComponent(run.uuidString).appendingPathComponent("inference")
        let suffix = streamDirectory.appendingPathComponent("1.batch")
        try Data([0, 1, 2]).write(to: suffix)
        let recovered = try XCTUnwrap(RecordingSpool.recover(in: root).first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: suffix.path))
        XCTAssertEqual(recovered.finalManifest.first?.inferenceFrames, 160)
        try recovered.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovered.directory.path))
        XCTAssertTrue(RecordingSpool.recover(in: root).isEmpty)
    }

    func testHardwareCallbacksCoalesceAndSealingFlushesExactTail() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try makeSpool(root: root)
        try spool.beginCapture(originalSampleRate: nil, originalChannels: nil)
        for _ in 0..<24 { try spool.append(chunk(frames: 160)) }
        XCTAssertNil(try spool.nextBatch(after: []))
        XCTAssertEqual(spool.checkpoints.first?.frameCount, 0)
        try spool.append(chunk(frames: 160))
        let first = try XCTUnwrap(spool.nextBatch(after: []))
        XCTAssertEqual(first.header.frameCount, 4_000)
        XCTAssertEqual(spool.checkpoints.first?.nextSequence, 1)
        try spool.append(chunk(frames: 160))
        try spool.seal()
        XCTAssertEqual(spool.finalManifest.first?.inferenceFrames, 4_160)
        try spool.seal(interrupted: "Microphone was disconnected.")
        let recovered = try XCTUnwrap(RecordingSpool.recover(in: root).first)
        XCTAssertEqual(recovered.interruption, "Microphone was disconnected.")
        XCTAssertEqual(recovered.finalManifest.first?.inferenceFrames, 4_160)
    }

    func testLargeOriginalWirePacketsKeepPairedSampleClockBoundaries() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try makeSpool(root: root)
        try spool.beginCapture(originalSampleRate: 192_000, originalChannels: 8)
        try spool.append(chunk(frames: 48_000, channels: 8, kind: .original, sampleRate: 192_000))
        XCTAssertNil(try spool.nextBatch(after: []), "Source bytes alone are not a publishable paired interval")
        try spool.append(chunk(frames: 4_000))
        XCTAssertEqual(spool.finalManifest.first?.originalFrames, 48_000)
        XCTAssertEqual(spool.finalManifest.first?.inferenceFrames, 4_000)
        var positions = spool.checkpoints.filter { $0.kind == .inference }
        let first = try XCTUnwrap(spool.nextBatch(after: positions))
        XCTAssertEqual(first.data.count, RecordingWire.maximumPCMBytes)
        positions.append(.init(runID: first.header.runID, kind: .original, format: first.header.format,
                               nextSequence: 1, frameCount: first.header.frameCount))
        let second = try XCTUnwrap(spool.nextBatch(after: positions))
        XCTAssertLessThanOrEqual(second.data.count, RecordingWire.maximumPCMBytes)
        XCTAssertEqual(first.header.frameCount + second.header.frameCount, 48_000)

        let odd = try makeSpool(root: root)
        try odd.beginCapture(originalSampleRate: 11_025, originalChannels: 1)
        for _ in 0..<4 {
            try odd.append(chunk(frames: 11_025, kind: .original, sampleRate: 11_025))
            try odd.append(chunk(frames: 16_000))
        }
        XCTAssertEqual(odd.finalManifest.first?.originalFrames, 44_100)
        XCTAssertEqual(odd.finalManifest.first?.inferenceFrames, 64_000)
    }

    func testUnmatchedSourceSuffixCannotStrandTheAcknowledgedPairedPrefix() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try makeSpool(root: root)
        try spool.beginCapture(originalSampleRate: 48_000, originalChannels: 1)
        try spool.append(chunk(frames: 1_600))
        try spool.append(chunk(frames: 4_800, kind: .original, sampleRate: 48_000))
        try spool.checkpoint()
        let acknowledgedPrefix = spool.finalManifest
        XCTAssertEqual(acknowledgedPrefix.first?.inferenceFrames, 1_600)
        XCTAssertEqual(acknowledgedPrefix.first?.originalFrames, 4_800)
        // Model a valid large driver buffer followed by a conversion failure.
        try spool.append(chunk(frames: 48_000, kind: .original, sampleRate: 48_000))
        try spool.append(chunk(frames: 8_000))
        try spool.pauseCapture(interrupted: "Audio conversion was interrupted.")
        XCTAssertEqual(spool.finalManifest, acknowledgedPrefix)
        let recovered = try XCTUnwrap(RecordingSpool.recover(in: root).first)
        XCTAssertEqual(recovered.finalManifest, acknowledgedPrefix)
        let prefix = try XCTUnwrap(recovered.nextBatch(after: []))
        XCTAssertEqual(prefix.header.frameCount, 1_600)
        try recovered.seal()
        XCTAssertTrue(recovered.isSealed)
        XCTAssertEqual(recovered.finalManifest, acknowledgedPrefix)
    }

    func testPauseRecoveryAndResumeKeepRunFormatsAndHonestGap() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try makeSpool(root: root)
        try spool.setContinuationID(nil)
        try spool.beginCapture(originalSampleRate: 48_000, originalChannels: 2)
        try spool.append(chunk(frames: 160))
        try spool.append(chunk(frames: 480, channels: 2, kind: .original, sampleRate: 48_000))
        try spool.pauseCapture(interrupted: "The microphone was disconnected.")
        let closedTimingJSON = try RecordingWire.encoder().encode(spool.runTimings)
        XCTAssertTrue(spool.isPaused)
        XCTAssertFalse(spool.isSealed)
        let recovered = try XCTUnwrap(RecordingSpool.recover(in: root).first)
        XCTAssertEqual(recovered.interruption, "The microphone was disconnected.")
        XCTAssertEqual(try RecordingWire.encoder().encode(recovered.runTimings), closedTimingJSON)
        try recovered.prepareToResume()
        try recovered.beginCapture(originalSampleRate: 44_100, originalChannels: 1)
        try recovered.append(chunk(frames: 320))
        try recovered.append(chunk(frames: 882, kind: .original, sampleRate: 44_100))
        try recovered.seal()
        XCTAssertFalse(recovered.isPaused)
        XCTAssertTrue(recovered.isSealed)
        XCTAssertEqual(recovered.finalManifest.map(\.inferenceFrames), [160, 320])
        XCTAssertEqual(recovered.finalManifest.map(\.originalFrames), [480, 882])
        XCTAssertEqual(recovered.runTimings.count, 2)
        XCTAssertNotNil(recovered.runTimings[0].endedAt)
        XCTAssertNotNil(recovered.runTimings[1].gapBeforeMilliseconds)
        let firstID = recovered.runTimings[0].runID
        let first = try XCTUnwrap(recovered.nextBatch(after: [], runIDs: [firstID]))
        XCTAssertEqual(first.header.runID, firstID)
        let secondID = recovered.runTimings[1].runID
        let second = try XCTUnwrap(recovered.nextBatch(after: [], runIDs: [secondID]))
        XCTAssertEqual(second.header.runID, secondID)
        XCTAssertThrowsError(try recovered.prepareToResume())
    }

    func testPayloadsStayBoundedAndCorruptCommittedBytesAreRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try makeSpool(root: root)
        try spool.beginCapture(originalSampleRate: nil, originalChannels: nil)
        try spool.append(chunk(frames: RecordingWire.maximumPCMBytes / 4 + 160))
        let first = try XCTUnwrap(spool.nextBatch(after: []))
        XCTAssertLessThanOrEqual(first.data.count, RecordingWire.maximumPCMBytes)
        let position = RecordingStreamCheckpoint(runID: first.header.runID, kind: .inference,
                                                  format: first.header.format, nextSequence: 1, frameCount: first.header.frameCount)
        let tail = try XCTUnwrap(spool.nextBatch(after: [position]))
        XCTAssertLessThanOrEqual(tail.data.count, RecordingWire.maximumPCMBytes)
        let url = spool.directory.appendingPathComponent(first.header.runID.uuidString).appendingPathComponent("inference/0.batch")
        var stored = try Data(contentsOf: url)
        stored[stored.count - 1] ^= 1
        try stored.write(to: url)
        XCTAssertThrowsError(try spool.nextBatch(after: []))
    }

    func testLongCaptureDoesNotClipAndCleanupPreservesPersistentPCM() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try makeSpool(root: root)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let writer = try RecordingWriter(inputFormat: format, preserveOriginalAudio: true,
                                         onLevel: { _ in }, onError: { _ in }, spool: spool)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0.125, count: Int(buffer.frameLength))
        for second in 1...7_200 {
            writer.append(buffer)
            await writer.checkpoint()
            if [1_800, 3_600, 7_200].contains(second) {
                XCTAssertEqual(spool.finalManifest.first?.inferenceFrames, Int64(second) * 16_000)
                XCTAssertEqual(spool.finalManifest.first?.originalFrames, Int64(second) * 16_000)
            }
        }
        let audio = try await writer.finish()
        XCTAssertEqual(audio.duration, 7_200, accuracy: 0.001)
        XCTAssertEqual(spool.finalManifest.first?.inferenceFrames, 7_200 * 16_000)
        XCTAssertEqual(spool.finalManifest.first?.originalFrames, 7_200 * 16_000)
        XCTAssertLessThanOrEqual(writer.peakQueuedPCMBytes, RecordingWriter.maximumQueuedPCMBytes)
        XCTAssertTrue(spool.isSealed)
        audio.cleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.directory.path))
    }

    func testWriterBacklogStopsAndPreservesCommittedPrefix() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try makeSpool(root: root)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let writer = try RecordingWriter(inputFormat: format, onLevel: { _ in }, onError: { _ in }, spool: spool)
        let small = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        small.frameLength = 160
        try XCTUnwrap(small.floatChannelData)[0].initialize(repeating: 0.125, count: 160)
        writer.append(small)
        await writer.checkpoint()
        let enormous = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(RecordingWriter.maximumQueuedPCMBytes / 4 + 1)))
        enormous.frameLength = enormous.frameCapacity
        writer.append(enormous)
        let audio = try await writer.finish()
        XCTAssertGreaterThan(audio.duration, 0)
        XCTAssertNotNil(spool.interruption)
        XCTAssertEqual(spool.finalManifest.first?.inferenceFrames, 160)
        XCTAssertLessThanOrEqual(writer.peakQueuedPCMBytes, RecordingWriter.maximumQueuedPCMBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.directory.path))
    }

    func testWriterBackpressureIsReportedBeforeAStalledWriterDrains() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try makeSpool(root: root)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let blocked = expectation(description: "Writer queue stalled")
        let failure = expectation(description: "Backpressure reported promptly")
        let firstLevel = CompletionFlag()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let writer = try RecordingWriter(inputFormat: format, onLevel: { _ in
            if !firstLevel.value {
                firstLevel.set()
                blocked.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }, onError: { _ in failure.fulfill() }, spool: spool)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        input.frameLength = 1_600
        try XCTUnwrap(input.floatChannelData)[0].initialize(repeating: 0.125, count: 1_600)
        writer.append(input)
        await fulfillment(of: [blocked], timeout: 2)
        let enormous = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 3))
        enormous.frameLength = enormous.frameCapacity
        writer.append(enormous)
        await fulfillment(of: [failure], timeout: 2)
        release.signal()
        _ = try await writer.finish()
        XCTAssertTrue(spool.isSealed)
        XCTAssertEqual(spool.finalManifest.first?.inferenceFrames, 1_600)
        XCTAssertNotNil(spool.interruption)
    }

    @MainActor
    func testQuitPausesAnActiveSessionWithoutFixingFinalStopTotals() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try makeSpool(root: root)
        let blocked = expectation(description: "Writer received audio")
        let release = DispatchSemaphore(value: 0)
        release.signal()
        let hardware = BlockingCaptureHardware(blocked: blocked, release: release)
        let recorder = AudioRecorder(worker: AudioCaptureWorker(makeHardware: { _ in hardware }),
                                     microphoneAuthorized: { true }, sleepNotifications: NotificationCenter())
        try await recorder.start(spool: spool)
        await recorder.preserve()
        await fulfillment(of: [blocked], timeout: 2)
        XCTAssertTrue(spool.isPaused)
        XCTAssertFalse(spool.isSealed)
        XCTAssertEqual(spool.finalManifest.first?.inferenceFrames, 1_600)
        XCTAssertNotNil(spool.runTimings.first?.endedAt)
        let recovered = try XCTUnwrap(RecordingSpool.recover(in: root).first)
        XCTAssertTrue(recovered.isPaused)
        let pausedEnd = recovered.runTimings.first?.endedAt
        try recovered.seal()
        XCTAssertEqual(recovered.runTimings.first?.endedAt, pausedEnd, "Finishing a paused prefix must not extend its capture interval")
    }

    @MainActor
    func testOrderlyPreservationWaitsForAnAlreadyFinishingWriter() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try makeSpool(root: root)
        let blocked = expectation(description: "Writer is still draining admitted PCM")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let hardware = BlockingCaptureHardware(blocked: blocked, release: release)
        let worker = AudioCaptureWorker(makeHardware: { _ in hardware })
        let recorder = AudioRecorder(worker: worker, microphoneAuthorized: { true }, sleepNotifications: NotificationCenter())
        try await recorder.start(spool: spool)
        await fulfillment(of: [blocked], timeout: 2)
        let stopping = Task { try await recorder.stop() }
        for _ in 0..<20 { await Task.yield() }
        let completed = CompletionFlag()
        let preserving = Task {
            await recorder.preserve()
            completed.set()
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(completed.value, "Quit must wait for the in-flight writer even after capture request ownership clears")
        release.signal()
        let audio = try await stopping.value
        await preserving.value
        XCTAssertTrue(completed.value)
        XCTAssertEqual(audio.duration, 0.1, accuracy: 0.001)
        XCTAssertTrue(spool.isSealed)
        XCTAssertEqual(spool.finalManifest.first?.inferenceFrames, 1_600)
    }

    func testInvalidSamplesPreservePriorCheckpoint() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try makeSpool(root: root)
        try spool.beginCapture(originalSampleRate: nil, originalChannels: nil)
        try spool.append(chunk(frames: 160))
        try spool.checkpoint()
        var sample = Float.infinity
        let invalid = CapturedAudioChunk(kind: .normalized, data: withUnsafeBytes(of: &sample) { Data($0) }, sampleRate: 16_000, channels: 1)
        try spool.append(invalid)
        XCTAssertThrowsError(try spool.checkpoint())
        XCTAssertEqual(spool.checkpoints.first?.frameCount, 160)
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    var value: Bool { lock.withLock { completed } }
    func set() { lock.withLock { completed = true } }
}

private final class BlockingCaptureHardware: AudioCaptureHardware, @unchecked Sendable {
    private let blocked: XCTestExpectation
    private let release: DispatchSemaphore
    private var writer: RecordingWriter?
    init(blocked: XCTestExpectation, release: DispatchSemaphore) {
        self.blocked = blocked; self.release = release
    }
    func start(request: AudioCaptureRequest, deviceID: AudioDeviceID?, preserveOriginalAudio: Bool,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable (String) -> Void) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let firstLevel = CompletionFlag()
        let writer = try RecordingWriter(inputFormat: format, onLevel: { [blocked, release] _ in
            if !firstLevel.value {
                firstLevel.set()
                blocked.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }, onError: { _ in }, spool: request.spool)
        self.writer = writer
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0.125, count: 1_600)
        writer.append(buffer)
    }
    func stop() -> RecordingWriter? {
        defer { writer = nil }
        return writer
    }
    func cancel() { writer?.cancel(); writer = nil }
}
