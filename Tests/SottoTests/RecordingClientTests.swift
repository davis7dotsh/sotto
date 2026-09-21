import Foundation
import SottoAPI
import XCTest
@testable import Sotto

final class RecordingClientTests: XCTestCase {
    func testReconnectReadsAuthoritativeCheckpointAfterLostAckWithoutDuplicatingAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-transport-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ServerClient(endpoint: "http://localhost:8391", token: "")
        var admitted = recordingSnapshot()
        admitted.epoch = 0
        let spool = try RecordingSpool(directory: root, snapshot: admitted, endpoint: server.endpoint, deviceIdentity: "test")
        try spool.beginCapture(originalSampleRate: nil, originalChannels: nil)
        try spool.append(.init(kind: .normalized, data: Data(repeating: 0, count: 32_000), sampleRate: 16_000, channels: 1))
        try spool.seal()
        try spool.setContinuationID(nil)
        var first = admitted
        first.epoch = 1
        let lostAckBatch = try XCTUnwrap(spool.nextBatch(after: []))
        let lostAckHeader = lostAckBatch.header
        var uploaded = [RecordingStreamCheckpoint(runID: lostAckHeader.runID, kind: lostAckHeader.kind, format: lostAckHeader.format,
                                                  nextSequence: lostAckHeader.sequence + 1,
                                                  frameCount: lostAckHeader.firstFrame + lostAckHeader.frameCount)]
        var resumed = admitted
        resumed.epoch = 2
        resumed.revision = 1
        resumed.streams = uploaded // Only the sent batch committed before its ACK was lost.
        resumed.uploadedFrames = uploaded[0].frameCount
        var remainingAcknowledgements: [Result<RecordingServerMessage, Error>] = []
        while let batch = try spool.nextBatch(after: uploaded) {
            let header = batch.header
            let checkpoint = RecordingStreamCheckpoint(runID: header.runID, kind: header.kind, format: header.format,
                                                       nextSequence: header.sequence + 1,
                                                       frameCount: header.firstFrame + header.frameCount)
            uploaded.removeAll { $0.runID == header.runID && $0.kind == header.kind }
            uploaded.append(checkpoint)
            let ack = RecordingAck(runID: checkpoint.runID, kind: checkpoint.kind, nextSequence: checkpoint.nextSequence,
                                   frameCount: checkpoint.frameCount, revision: remainingAcknowledgements.count + 2)
            remainingAcknowledgements.append(.success(.ack(ack)))
        }
        var discarded = resumed
        discarded.captureState = .discarded
        discarded.revision = remainingAcknowledgements.count + 2
        discarded.streams = uploaded
        discarded.uploadedFrames = uploaded.filter { $0.kind == .inference }.reduce(0) { $0 + $1.frameCount }
        let firstSocket = ScriptedRecordingSocket(messages: [.success(.snapshot(first)), .failure(URLError(.networkConnectionLost))])
        let resumedSocket = ScriptedRecordingSocket(messages: [.success(.snapshot(resumed))] + remainingAcknowledgements
                                                               + [.success(.progress(discarded))])
        let pool = RecordingSocketPool(sockets: [firstSocket, resumedSocket])
        let uploader = RecordingClient(client: server, spool: spool, socketFactory: { _ in try pool.next() })
        let task = Task { try await uploader.run() }
        let record = try await withThrowingTaskGroup(of: GenerationRecord.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                task.cancel()
                await uploader.cancel()
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(firstSocket.binaries.count, 1)
        XCTAssertEqual(resumedSocket.binaries.count, remainingAcknowledgements.count)
        let transmitted = try (firstSocket.binaries + resumedSocket.binaries).map { try RecordingWire.decodeAudio($0).header }
        XCTAssertEqual(transmitted.map(\.sequence), Array(0..<transmitted.count))
        XCTAssertEqual(transmitted.reduce(Int64(0)) { $0 + $1.frameCount }, 8_000)
        let stops = try resumedSocket.controls.compactMap { data -> RecordingStopRequest? in
            if case .stop(let request) = try RecordingWire.decoder().decode(RecordingClientMessage.self, from: data) { return request }
            return nil
        }
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.epoch, 2)
        XCTAssertEqual(stops.first?.runs, spool.finalManifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testPermanentProtocolErrorSurfacesWithoutRetryingOrDeletingSpool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-rejected-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ServerClient(endpoint: "http://localhost:8391", token: "")
        var snapshot = recordingSnapshot()
        snapshot.epoch = 0
        let spool = try RecordingSpool(directory: root, snapshot: snapshot, endpoint: server.endpoint, deviceIdentity: "test")
        let socket = ScriptedRecordingSocket(messages: [.success(.error(.init(code: "recording_missing", message: "Recording unavailable.", retryable: false)))])
        let uploader = RecordingClient(client: server, spool: spool, socketFactory: { _ in socket })
        do {
            _ = try await uploader.run()
            XCTFail("A permanent rejection must surface.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Recording unavailable.")
        }
        XCTAssertEqual(socket.controls.count, 1)
        XCTAssertEqual(socket.binaries.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(spool.isSealed)
    }

    func testContinuationContextIsConfirmedBeforeFirstAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-context-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ServerClient(endpoint: "http://localhost:8391", token: "")
        let initial = recordingSnapshot()
        let spool = try RecordingSpool(directory: root, snapshot: initial, endpoint: server.endpoint, deviceIdentity: "test")
        try spool.beginCapture(originalSampleRate: nil, originalChannels: nil)
        try spool.append(.init(kind: .normalized, data: Data(repeating: 0, count: 32_000), sampleRate: 16_000, channels: 1))
        try spool.seal()
        let continuationID = UUID()
        try spool.setContinuationID(continuationID)
        var confirmed = initial
        confirmed.continuationID = continuationID
        confirmed.revision = 1
        var uploaded: [RecordingStreamCheckpoint] = []
        var acknowledgements: [Result<RecordingServerMessage, Error>] = []
        while let batch = try spool.nextBatch(after: uploaded) {
            let header = batch.header
            let checkpoint = RecordingStreamCheckpoint(runID: header.runID, kind: header.kind, format: header.format,
                                                       nextSequence: header.sequence + 1,
                                                       frameCount: header.firstFrame + header.frameCount)
            uploaded.removeAll { $0.runID == header.runID && $0.kind == header.kind }
            uploaded.append(checkpoint)
            let ack = RecordingAck(runID: checkpoint.runID, kind: checkpoint.kind, nextSequence: checkpoint.nextSequence,
                                   frameCount: checkpoint.frameCount, revision: acknowledgements.count + 2)
            acknowledgements.append(.success(.ack(ack)))
        }
        var discarded = confirmed
        discarded.revision = acknowledgements.count + 2
        discarded.captureState = .discarded
        discarded.streams = uploaded
        discarded.uploadedFrames = uploaded.filter { $0.kind == .inference }.reduce(0) { $0 + $1.frameCount }
        let socket = ScriptedRecordingSocket(messages: [.success(.snapshot(initial)), .success(.snapshot(confirmed))]
                                                        + acknowledgements + [.success(.progress(discarded))])
        let uploader = RecordingClient(client: server, spool: spool, socketFactory: { _ in socket })
        _ = try await uploader.run()
        XCTAssertEqual(socket.outboundKinds, ["resume", "context"] + Array(repeating: "audio", count: acknowledgements.count) + ["stop"])
        let context = try RecordingWire.decoder().decode(RecordingContextRequest.self, from: socket.controls[1])
        XCTAssertEqual(context.continuationID, continuationID)
        XCTAssertEqual(context.epoch, initial.epoch)
    }

    func testResumedRunWaitsForPriorRunAudioAndPauseConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-resumed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ServerClient(endpoint: "http://localhost:8391", token: "")
        let initial = recordingSnapshot()
        let spool = try RecordingSpool(directory: root, snapshot: initial, endpoint: server.endpoint, deviceIdentity: "test")
        try spool.setContinuationID(nil)
        try spool.beginCapture(originalSampleRate: 48_000, originalChannels: 2)
        try spool.append(.init(kind: .normalized, data: Data(repeating: 0, count: 16_000), sampleRate: 16_000, channels: 1))
        try spool.append(.init(kind: .original, data: Data(repeating: 0, count: 96_000), sampleRate: 48_000, channels: 2))
        try spool.pauseCapture(interrupted: "Microphone disconnected.")
        try spool.prepareToResume()
        try spool.beginCapture(originalSampleRate: 44_100, originalChannels: 1)
        try spool.append(.init(kind: .normalized, data: Data(repeating: 0, count: 16_000), sampleRate: 16_000, channels: 1))
        try spool.append(.init(kind: .original, data: Data(repeating: 0, count: 44_100), sampleRate: 44_100, channels: 1))
        try spool.seal()
        let timings = spool.runTimings
        XCTAssertEqual(timings.count, 2)
        var snapshot = initial
        var messages: [Result<RecordingServerMessage, Error>] = [.success(.snapshot(snapshot))]
        var expectedKinds = ["resume"]
        for (index, timing) in timings.enumerated() {
            while let batch = try spool.nextBatch(after: snapshot.streams, runIDs: [timing.runID]) {
                let header = batch.header
                let checkpoint = RecordingStreamCheckpoint(runID: header.runID, kind: header.kind, format: header.format,
                                                           nextSequence: header.sequence + 1,
                                                           frameCount: header.firstFrame + header.frameCount)
                snapshot.streams.removeAll { $0.runID == header.runID && $0.kind == header.kind }
                snapshot.streams.append(checkpoint)
                snapshot.revision += 1
                messages.append(.success(.ack(.init(runID: header.runID, kind: header.kind,
                                                   nextSequence: checkpoint.nextSequence,
                                                   frameCount: checkpoint.frameCount, revision: snapshot.revision))))
                expectedKinds.append("audio")
            }
            if index < timings.count - 1 {
                snapshot.closedRuns = spool.finalManifest.filter { $0.runID == timing.runID }
                snapshot.runTimings = [timing]
                snapshot.revision += 1
                messages.append(.success(.snapshot(snapshot)))
                expectedKinds.append("pause")
            }
        }
        snapshot.captureState = .discarded
        snapshot.revision += 1
        messages.append(.success(.progress(snapshot)))
        expectedKinds.append("stop")
        let socket = ScriptedRecordingSocket(messages: messages)
        let uploader = RecordingClient(client: server, spool: spool, socketFactory: { _ in socket })
        _ = try await uploader.run()
        XCTAssertEqual(socket.outboundKinds, expectedKinds)
        let headers = try socket.binaries.map { try RecordingWire.decodeAudio($0).header }
        XCTAssertEqual(headers.map(\.runID), [timings[0].runID, timings[0].runID, timings[1].runID, timings[1].runID])
        let pauses = try socket.controls.compactMap { data -> RecordingPauseRequest? in
            if case .pause(let pause) = try RecordingWire.decoder().decode(RecordingClientMessage.self, from: data) { return pause }
            return nil
        }
        XCTAssertEqual(pauses.count, 1)
        XCTAssertEqual(pauses.first?.runs, spool.finalManifest.filter { $0.runID == timings[0].runID })
        let wireTimings = try RecordingWire.decoder().decode([RecordingRunTiming].self, from: RecordingWire.encoder().encode(timings))
        XCTAssertEqual(pauses.first?.runTimings, [wireTimings[0]])
        let stop = try RecordingWire.decoder().decode(RecordingStopRequest.self, from: XCTUnwrap(socket.controls.last))
        XCTAssertEqual(stop.runs, spool.finalManifest)
        XCTAssertEqual(stop.runTimings, wireTimings)
    }

    func testAdmittedLargeDictionarySnapshotFitsServerControlBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-large-snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ServerClient(endpoint: "http://localhost:8391", token: "")
        var snapshot = recordingSnapshot()
        let suffix = String(repeating: "界", count: 100)
        let entries = (0..<500).map { index in
            DictionaryEntry(id: "entry\(index)", term: "term\(index)" + suffix,
                            aliases: (0..<8).map { "alias\(index)-\($0)" + suffix })
        }
        snapshot.settings.preferences.dictionary = .init(lists: [.init(id: "personal", name: "Personal", entries: entries)])
        XCTAssertNil(snapshot.settings.preferences.validationError)
        snapshot.captureState = .discarded
        let message = RecordingServerMessage.snapshot(snapshot)
        let bytes = try RecordingWire.encoder().encode(message)
        XCTAssertGreaterThan(bytes.count, 1_048_576)
        XCTAssertLessThanOrEqual(bytes.count, RecordingWire.maximumServerControlMessageBytes)
        let spool = try RecordingSpool(directory: root, snapshot: snapshot, endpoint: server.endpoint, deviceIdentity: "test")
        let socket = ScriptedRecordingSocket(messages: [.success(message)])
        let uploader = RecordingClient(client: server, spool: spool, socketFactory: { _ in socket })
        let result = try await uploader.run()
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(socket.controls.count, 1)
        XCTAssertEqual(result.settings, snapshot.settings)
    }

    func testSettledPausedTransferCanRestartAndSendFinalStopPromptly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-finish-paused-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ServerClient(endpoint: "http://localhost:8391", token: "")
        var admitted = recordingSnapshot()
        let spool = try RecordingSpool(directory: root, snapshot: admitted, endpoint: server.endpoint, deviceIdentity: "test")
        try spool.setContinuationID(nil)
        try spool.beginCapture(originalSampleRate: nil, originalChannels: nil)
        try spool.append(.init(kind: .normalized, data: Data(repeating: 0, count: 16_000), sampleRate: 16_000, channels: 1))
        try spool.pauseCapture(interrupted: "Microphone disconnected.")
        admitted.streams = spool.checkpoints
        var paused = admitted
        paused.closedRuns = spool.finalManifest
        paused.runTimings = spool.runTimings
        paused.captureState = .interrupted
        paused.revision = 1
        let firstSocket = SuspendingRecordingSocket(messages: [.success(.snapshot(admitted)), .success(.snapshot(paused))])
        let firstUploader = RecordingClient(client: server, spool: spool, socketFactory: { _ in firstSocket })
        let firstTask = Task { try await firstUploader.run() }
        for _ in 0..<100 {
            if firstSocket.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(firstSocket.isWaiting)
        XCTAssertEqual(firstSocket.base.outboundKinds, ["resume", "pause"])
        XCTAssertTrue(spool.isPaused)
        // The controller's Finish action checkpoints before replacing its
        // interrupted uploader, so a suspended socket cannot delay final stop.
        try spool.seal()
        firstTask.cancel()
        await firstUploader.cancel()
        do { _ = try await firstTask.value; XCTFail("The paused transfer should cancel.") }
        catch is CancellationError {}
        var resumed = paused
        resumed.epoch = 2
        var discarded = resumed
        discarded.captureState = .discarded
        discarded.revision = 2
        let finalSocket = ScriptedRecordingSocket(messages: [.success(.snapshot(resumed)), .success(.snapshot(discarded))])
        let finalUploader = RecordingClient(client: server, spool: spool, socketFactory: { _ in finalSocket })
        let startedAt = ContinuousClock.now
        _ = try await finalUploader.run()
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
        XCTAssertEqual(finalSocket.outboundKinds, ["resume", "stop"])
        XCTAssertTrue(finalSocket.binaries.isEmpty)
        let stop = try RecordingWire.decoder().decode(RecordingStopRequest.self, from: XCTUnwrap(finalSocket.controls.last))
        XCTAssertEqual(stop.runs, spool.finalManifest)
        XCTAssertEqual(stop.epoch, 2)
    }

    func testCredentialAndRedirectRejectionsStopTransferAndKeepLocalAudio() async throws {
        for status in [301, 401, 403, 404] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-http-rejected-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let server = try ServerClient(endpoint: "http://localhost:8391", token: "")
            let spool = try RecordingSpool(directory: root, snapshot: recordingSnapshot(), endpoint: server.endpoint, deviceIdentity: "test")
            let socket = ScriptedRecordingSocket(messages: [.failure(ServerClientError.rejected(status, "Connection rejected."))])
            let uploader = RecordingClient(client: server, spool: spool, socketFactory: { _ in socket })
            do {
                _ = try await uploader.run()
                XCTFail("A credential or redirect rejection must not retry.")
            } catch ServerClientError.rejected(let actual, _) {
                XCTAssertEqual(actual, status)
            }
            XCTAssertEqual(socket.controls.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testSocketPinsEndpointCredentialAndSubprotocol() throws {
        let id = UUID()
        let client = try ServerClient(endpoint: "https://example.com/sotto", token: "private-token")
        let request = try client.recordingWebSocketRequest(id)
        XCTAssertEqual(request.url?.absoluteString, "wss://example.com/sotto/v2/recordings/\(id)/stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), RecordingWire.webSocketProtocol)
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.url?.user)
        XCTAssertNil(request.url?.password)
        XCTAssertFalse(request.url?.absoluteString.contains("private-token") == true)
        let localhost = try ServerClient(endpoint: "http://localhost:8391", token: "")
        XCTAssertEqual(try localhost.recordingWebSocketRequest(id).url?.scheme, "ws")
        XCTAssertNil(try localhost.recordingWebSocketRequest(id).value(forHTTPHeaderField: "Authorization"))
        XCTAssertThrowsError(try ServerClient(endpoint: "http://example.com", token: "private-token"))
    }

    func testAckLostBeforeReconnectIsRepresentedByDurableServerCursor() throws {
        let header = audioHeader(sequence: 42, firstFrame: 336_000, frameCount: 8_000)
        let committed = RecordingStreamCheckpoint(runID: header.runID, kind: .inference, format: header.format,
                                                 nextSequence: 43, frameCount: 344_000)
        XCTAssertTrue(RecordingUploadCursor.isAcknowledged(header, by: [committed]))
        var wrongFrames = committed
        wrongFrames.frameCount -= 1
        XCTAssertFalse(RecordingUploadCursor.isAcknowledged(header, by: [wrongFrames]))
        var wrongRun = committed
        wrongRun.runID = UUID()
        XCTAssertFalse(RecordingUploadCursor.isAcknowledged(header, by: [wrongRun]))
    }

    func testAckVerifiesExactCountsAndDoesNotRegressConcurrentProgressRevision() throws {
        let header = audioHeader(sequence: 5, firstFrame: 40_000, frameCount: 8_000)
        var snapshot = recordingSnapshot()
        snapshot.revision = 80 // A progress update can precede a queued ACK.
        let receipt = RecordingAck(runID: header.runID, kind: .inference, nextSequence: 6,
                                   frameCount: 48_000, revision: 79)
        try RecordingUploadCursor.apply(receipt, expected: header, to: &snapshot)
        XCTAssertEqual(snapshot.revision, 80)
        XCTAssertEqual(snapshot.uploadedFrames, 48_000)
        XCTAssertEqual(snapshot.streams.count, 1)
        XCTAssertTrue(RecordingUploadCursor.isAcknowledged(header, by: snapshot.streams))
        var conflicting = receipt
        conflicting.frameCount += 1
        XCTAssertThrowsError(try RecordingUploadCursor.apply(conflicting, expected: header, to: &snapshot))
        conflicting = receipt
        conflicting.nextSequence += 1
        XCTAssertThrowsError(try RecordingUploadCursor.apply(conflicting, expected: header, to: &snapshot))
        conflicting = receipt
        conflicting.kind = .original
        XCTAssertThrowsError(try RecordingUploadCursor.apply(conflicting, expected: header, to: &snapshot))
    }

    func testBatchCannotSkipOrContradictAuthoritativeServerFrames() throws {
        let header = audioHeader(sequence: 7, firstFrame: 56_000, frameCount: 8_000)
        var checkpoint = RecordingStreamCheckpoint(runID: header.runID, kind: header.kind, format: header.format,
                                                  nextSequence: 7, frameCount: 56_000)
        try RecordingUploadCursor.validate(header, after: [checkpoint])
        checkpoint.frameCount -= 1
        XCTAssertThrowsError(try RecordingUploadCursor.validate(header, after: [checkpoint]))
        checkpoint.frameCount = 56_000
        checkpoint.nextSequence += 1
        XCTAssertThrowsError(try RecordingUploadCursor.validate(header, after: [checkpoint]))
    }

    func testOriginalAudioUsesIndependentCounters() throws {
        var snapshot = recordingSnapshot()
        let inference = audioHeader(sequence: 0, firstFrame: 0, frameCount: 8_000)
        try RecordingUploadCursor.apply(.init(runID: inference.runID, kind: .inference, nextSequence: 1,
                                              frameCount: 8_000, revision: 1), expected: inference, to: &snapshot)
        var original = inference
        original.kind = .original
        original.format = .init(sampleRate: 48_000, channels: 2)
        original.frameCount = 24_000
        try RecordingUploadCursor.apply(.init(runID: original.runID, kind: .original, nextSequence: 1,
                                              frameCount: 24_000, revision: 2), expected: original, to: &snapshot)
        XCTAssertEqual(snapshot.streams.count, 2)
        XCTAssertEqual(snapshot.uploadedFrames, 8_000)
    }

    func testSummaryDoesNotMaterializePartialPreviewAsInsertionText() {
        var snapshot = recordingSnapshot()
        snapshot.previewText = "unfinished recognized words"
        snapshot.uploadedFrames = 100
        snapshot.transcribedFrames = 40
        let record = ServerClient.generationSummary(snapshot)
        XCTAssertEqual(record.status, .receiving)
        XCTAssertEqual(record.previewText, snapshot.previewText)
        XCTAssertEqual(record.finalText, "")
        XCTAssertEqual(record.insertionText, "")
        XCTAssertEqual(record.progress, 0.4)
    }
}

private func audioHeader(sequence: Int, firstFrame: Int64, frameCount: Int64) -> RecordingAudioHeader {
    .init(epoch: 1, runID: UUID(), kind: .inference, sequence: sequence, firstFrame: firstFrame,
          format: .init(sampleRate: 16_000, channels: 1), frameCount: frameCount,
          sha256: String(repeating: "0", count: 64))
}

private func recordingSnapshot() -> RecordingSnapshot {
    .init(id: UUID(), requestID: UUID(), device: .init(id: "test", name: "Test"),
          settings: .init(), epoch: 1)
}

private final class ScriptedRecordingSocket: RecordingSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [Result<RecordingServerMessage, Error>]
    private var binaryMessages: [Data] = []
    private var controlMessages: [Data] = []
    private var kinds: [String] = []
    var binaries: [Data] { lock.withLock { binaryMessages } }
    var controls: [Data] { lock.withLock { controlMessages } }
    var outboundKinds: [String] { lock.withLock { kinds } }
    init(messages: [Result<RecordingServerMessage, Error>]) { self.messages = messages }
    func send(binary: Data) async throws { lock.withLock { binaryMessages.append(binary); kinds.append("audio") } }
    func send(control: Data) async throws {
        let message = try RecordingWire.decoder().decode(RecordingClientMessage.self, from: control)
        let kind: String
        switch message {
        case .resume: kind = "resume"
        case .context: kind = "context"
        case .stop: kind = "stop"
        case .pause: kind = "pause"
        case .ping: kind = "ping"
        }
        lock.withLock { controlMessages.append(control); kinds.append(kind) }
    }
    func receive() async throws -> Data {
        let message = try lock.withLock {
            guard !messages.isEmpty else { throw URLError(.networkConnectionLost) }
            return try messages.removeFirst().get()
        }
        return try RecordingWire.encoder().encode(message)
    }
    func close() {}
}

private final class RecordingSocketPool: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [ScriptedRecordingSocket]
    init(sockets: [ScriptedRecordingSocket]) { self.sockets = sockets }
    func next() throws -> any RecordingSocket {
        try lock.withLock {
            guard !sockets.isEmpty else { throw URLError(.cannotConnectToHost) }
            return sockets.removeFirst()
        }
    }
}

private final class SuspendingRecordingSocket: RecordingSocket, @unchecked Sendable {
    let base: ScriptedRecordingSocket
    private let lock = NSLock()
    private var remaining: Int
    private var closed = false
    private var waiter: CheckedContinuation<Data, Error>?
    var isWaiting: Bool { lock.withLock { waiter != nil } }
    init(messages: [Result<RecordingServerMessage, Error>]) {
        base = ScriptedRecordingSocket(messages: messages)
        remaining = messages.count
    }
    func send(binary: Data) async throws { try await base.send(binary: binary) }
    func send(control: Data) async throws { try await base.send(control: control) }
    func receive() async throws -> Data {
        let immediate = lock.withLock {
            if remaining > 0 { remaining -= 1; return true }
            return false
        }
        if immediate { return try await base.receive() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if closed { continuation.resume(throwing: URLError(.cancelled)) }
                else { waiter = continuation }
            }
        }
    }
    func close() {
        let pending = lock.withLock {
            closed = true
            let pending = waiter
            waiter = nil
            return pending
        }
        pending?.resume(throwing: URLError(.cancelled))
    }
}
