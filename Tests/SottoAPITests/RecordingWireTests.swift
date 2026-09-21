import Foundation
import SottoAPI
import XCTest

final class RecordingWireTests: XCTestCase {
    func testSameSessionPauseRemainsDistinctFromFinalStop() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let run = RecordingRunEndpoint(runID: UUID(), inferenceFrames: 960_000, originalFrames: 2_880_000)
        let timing = RecordingRunTiming(runID: run.runID, startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60), gapBeforeMilliseconds: 1500)
        let pause = RecordingClientMessage.pause(.init(epoch: 4, runs: [run], runTimings: [timing],
            interruption: "Microphone disconnected."))
        XCTAssertEqual(try RecordingWire.decoder().decode(RecordingClientMessage.self,
            from: RecordingWire.encoder().encode(pause)), pause)
        let json = try XCTUnwrap(String(data: RecordingWire.encoder().encode(pause), encoding: .utf8))
        XCTAssertTrue(json.contains("2023-11-14T22:13:20.125Z"))
        let snapshot = RecordingSnapshot(id: UUID(), requestID: UUID(), device: .init(id: "test", name: "Test Mac"),
            settings: .init(), createdAt: startedAt, captureState: .interrupted,
            epoch: 4, closedRuns: [run], runTimings: [timing])
        let recovered = try RecordingWire.decoder().decode(RecordingSnapshot.self,
            from: RecordingWire.encoder().encode(snapshot))
        XCTAssertEqual(recovered.closedRuns, [run])
        XCTAssertEqual(recovered.runTimings, [timing])
        XCTAssertNil(recovered.stopRuns)
        let stop = RecordingClientMessage.stop(.init(epoch: 4, runs: [run], runTimings: [timing]))
        XCTAssertEqual(try RecordingWire.decoder().decode(RecordingClientMessage.self,
            from: RecordingWire.encoder().encode(stop)), stop)
    }

    func testBinaryAudioFramingPreservesLargeCountersAndByteOrder() throws {
        let pcm = Data([0, 0, 0, 0, 0, 0, 128, 63])
        let header = RecordingAudioHeader(epoch: 3, runID: UUID(), kind: .inference, sequence: 8192,
            firstFrame: 4_294_967_296, format: .init(sampleRate: 16000, channels: 1), frameCount: 2,
            sha256: "22b6f43bd8d27738d3213f29e96b62d01d9d6c0ab4f9732aaae803186f51eab7")
        let encoded = try RecordingWire.encodeAudio(header: header, pcm: pcm)
        let prefix = Array(encoded.prefix(4))
        let length = Int(UInt32(prefix[0]) << 24 | UInt32(prefix[1]) << 16 | UInt32(prefix[2]) << 8 | UInt32(prefix[3]))
        XCTAssertEqual(encoded.count, 4 + length + pcm.count)
        XCTAssertEqual(try RecordingWire.decodeAudio(encoded), RecordingAudioMessage(header: header, pcm: pcm))
        XCTAssertEqual(encoded.suffix(pcm.count), pcm)
    }

    func testBinaryCodecRejectsTruncationUnsafeCountersAndWrongFrameCounts() throws {
        let header = RecordingAudioHeader(epoch: 1, runID: UUID(), kind: .inference, sequence: 0,
            firstFrame: 0, format: .init(sampleRate: 16000, channels: 1), frameCount: 1,
            sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try RecordingWire.encodeAudio(header: header, pcm: Data()))
        XCTAssertThrowsError(try RecordingWire.decodeAudio(Data([0, 0, 0, 2, 123])))
        XCTAssertThrowsError(try RecordingWire.decodeAudio(Data([0, 0, 0, 0])))
        var invalid = header
        invalid.firstFrame = 9_007_199_254_740_991
        XCTAssertThrowsError(try RecordingWire.encodeAudio(header: invalid, pcm: Data(repeating: 0, count: 4)))
        invalid = header
        invalid.frameCount = Int64.max
        XCTAssertThrowsError(try RecordingWire.encodeAudio(header: invalid, pcm: Data(repeating: 0, count: 4)))
    }

    func testStandaloneSnapshotsDecodeServerFractionalTimestampsAndStopIntent() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let run = RecordingRunEndpoint(runID: UUID(), inferenceFrames: 4_294_967_296)
        let snapshot = RecordingSnapshot(id: UUID(), requestID: UUID(), device: .init(id: "test", name: "Test Mac"),
            settings: .init(), createdAt: date, captureState: .stopped, processingState: .processing,
            uploadedFrames: run.inferenceFrames, epoch: 2, stopRuns: [run])
        let encoded = try RecordingWire.encoder().encode(RecordingServerMessage.snapshot(snapshot))
        XCTAssertEqual(try RecordingWire.decoder().decode(RecordingServerMessage.self, from: encoded), .snapshot(snapshot))
        let fractional = Data("\"2023-11-14T22:13:20.125Z\"".utf8)
        XCTAssertEqual(try RecordingWire.decoder().decode(Date.self, from: fractional), date.addingTimeInterval(0.125))
        let control = RecordingClientMessage.stop(.init(epoch: 2, runs: [run]))
        XCTAssertEqual(try RecordingWire.decoder().decode(RecordingClientMessage.self,
            from: RecordingWire.encoder().encode(control)), control)
        let context = RecordingClientMessage.context(.init(epoch: 2, continuationID: UUID()))
        XCTAssertEqual(try RecordingWire.decoder().decode(RecordingClientMessage.self,
            from: RecordingWire.encoder().encode(context)), context)
    }

    func testServerEnvelopeAndCapabilitiesHaveTheirExactWireShapes() throws {
        let receipt = RecordingAck(runID: UUID(), kind: .original, nextSequence: 9000, frameCount: 4_294_967_296, revision: 45)
        let messages: [RecordingServerMessage] = [
            .ack(receipt), .error(.init(code: "stale_epoch", message: "Resume first.", retryable: true))
        ]
        for message in messages {
            let json = try RecordingWire.encoder().encode(message)
            XCTAssertEqual(try RecordingWire.decoder().decode(RecordingServerMessage.self, from: json), message)
        }
        let capabilities = try RecordingWire.decoder().decode(RecordingCapabilities.self,
            from: Data("{\"protocol\":\"sotto.recording.v1\",\"maximumPCMBytes\":1048576}".utf8))
        XCTAssertEqual(capabilities.protocolName, RecordingWire.webSocketProtocol)
        XCTAssertEqual(capabilities.maximumPCMBytes, RecordingWire.maximumPCMBytes)
        XCTAssertThrowsError(try RecordingWire.decoder().decode(RecordingServerMessage.self,
            from: Data("{\"type\":\"finalized\"}".utf8)))
    }
}
