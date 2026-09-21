import Foundation
import SottoAPI

/// Only committed spool batches are loaded, and only one binary batch is ever in
/// flight. A socket is replaceable; the durable server position owns recovery.
protocol RecordingSocket: Sendable {
    func send(binary: Data) async throws
    func send(control: Data) async throws
    func receive() async throws -> Data
    func close()
}

typealias RecordingSocketFactory = @Sendable (URLRequest) throws -> any RecordingSocket

private final class RecordingNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class URLSessionRecordingSocket: RecordingSocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        // URLSession's ordinary HTTP resource deadline must not terminate a
        // healthy recording after five minutes.
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RecordingNoRedirects(), delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = max(RecordingWire.maximumMessageBytes, RecordingWire.maximumServerControlMessageBytes)
        task.resume()
    }

    func send(binary: Data) async throws {
        do { try await task.send(.data(binary)) }
        catch { throw translated(error) }
    }
    func send(control: Data) async throws {
        guard let text = String(data: control, encoding: .utf8) else { throw ServerClientError.invalidResponse }
        do { try await task.send(.string(text)) }
        catch { throw translated(error) }
    }
    func receive() async throws -> Data {
        do {
            switch try await task.receive() {
            case .data(let data): return data
            case .string(let text): return Data(text.utf8)
            @unknown default: throw ServerClientError.invalidResponse
            }
        } catch { throw translated(error) }
    }
    private func translated(_ error: Error) -> Error {
        guard let response = task.response as? HTTPURLResponse,
              response.statusCode != 101, !(200..<300).contains(response.statusCode) else { return error }
        let message: String
        switch response.statusCode {
        case 401, 403: message = "The server credential was rejected. The recording remains saved locally."
        case 404, 410: message = "This recording is unavailable on the server. The recording remains saved locally."
        case 300..<400: message = "The recording server redirected the connection. Check its configured address."
        default: message = "The recording connection was rejected (HTTP \(response.statusCode))."
        }
        return ServerClientError.rejected(response.statusCode, message)
    }
    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

actor RecordingClient {
    private let client: ServerClient
    private let spool: RecordingSpool
    private let socketFactory: RecordingSocketFactory
    private var activeSocket: (any RecordingSocket)?
    private var cancelled = false
    private var running = false

    init(client: ServerClient, spool: RecordingSpool,
         socketFactory: @escaping RecordingSocketFactory = { URLSessionRecordingSocket(request: $0) }) {
        self.client = client
        self.spool = spool
        self.socketFactory = socketFactory
    }

    /// Admission happens through HTTP before capture. Once admitted, retrying a
    /// transfer never ends capture or removes locally committed audio.
    func run(onUpdate: @escaping @Sendable (RecordingSnapshot) async -> Void = { _ in },
             onConnectionChange: @escaping @Sendable (Bool) async -> Void = { _ in }) async throws -> GenerationRecord {
        guard !running, spool.endpoint == client.endpoint else { throw ServerClientError.invalidEndpoint }
        running = true
        defer { running = false; activeSocket?.close(); activeSocket = nil }
        var failures = 0
        while true {
            try checkCancellation()
            do {
                let socket = try socketFactory(client.recordingWebSocketRequest(spool.snapshot.id))
                activeSocket = socket
                let result = try await withTaskCancellationHandler {
                    try await transfer(socket: socket, onUpdate: onUpdate, onConnectionChange: onConnectionChange)
                } onCancel: {
                    socket.close()
                }
                socket.close()
                activeSocket = nil
                await onConnectionChange(false)
                return result
            } catch {
                activeSocket?.close()
                activeSocket = nil
                await onConnectionChange(false)
                try checkCancellation()
                if error is RecordingSpool.SpoolError { throw error }
                if case RecordingTransferError.processingFailed = error { throw error }
                if case RecordingTransferError.server(let failure) = error, !failure.retryable { throw error }
                if case ServerClientError.rejected(let status, _) = error,
                   (300..<500).contains(status), status != 408, status != 429 { throw error }
                failures = min(failures + 1, 6)
                // Bound retries without bounding the duration of offline capture.
                // A changed Preferences endpoint never redirects this uploader.
                let delay = min(15.0, pow(2.0, Double(failures - 1)) * 0.5)
                try await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
            }
        }
    }

    /// Cancel transfer only. Explicit discard is a different persisted action.
    func cancel() {
        cancelled = true
        activeSocket?.close()
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func transfer(socket: any RecordingSocket,
                          onUpdate: @escaping @Sendable (RecordingSnapshot) async -> Void,
                          onConnectionChange: @escaping @Sendable (Bool) async -> Void) async throws -> GenerationRecord {
        try await socket.send(control: RecordingWire.encoder().encode(RecordingClientMessage.resume))
        let heartbeat = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(10))
                    try Task.checkCancellation()
                    try await socket.send(control: RecordingWire.encoder().encode(RecordingClientMessage.ping))
                }
            } catch {
                if !Task.isCancelled { socket.close() }
            }
        }
        defer { heartbeat.cancel() }
        var snapshot: RecordingSnapshot
        switch try await receive(socket) {
        case .snapshot(let value), .progress(let value): snapshot = value
        case .error(let error): throw RecordingTransferError.server(error)
        case .ack: throw ServerClientError.invalidResponse
        }
        try validateIdentity(snapshot)
        try spool.markSnapshot(snapshot)
        await onConnectionChange(true)
        await onUpdate(snapshot)
        var sentStop = false
        var sentContext = false
        while true {
            try checkCancellation()
            if snapshot.captureState == .discarded { return ServerClient.generationSummary(snapshot) }
            if snapshot.captureState == .stopped, snapshot.processingState == .failed {
                throw RecordingTransferError.processingFailed(snapshot.error ?? "Speech processing failed. The saved recording is available to retry.")
            }
            if snapshot.processingState == .completed {
                guard spool.isSealed else { throw ServerClientError.invalidResponse }
                let result = try await client.materializedRecording(snapshot.id)
                guard result.status == .completed else { throw ServerClientError.invalidResponse }
                return result
            }
            if !sentContext {
                // Destination capture can finish after the microphone starts.
                // Keep saving locally until its persisted continuation decision
                // is ready, before allowing any ASR/text work to freeze context.
                guard spool.contextReady else {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                if let continuationID = spool.continuationID {
                    let context = RecordingContextRequest(epoch: snapshot.epoch, continuationID: continuationID)
                    try await socket.send(control: RecordingWire.encoder().encode(RecordingClientMessage.context(context)))
                    var confirmed = false
                    while !confirmed {
                        switch try await receive(socket) {
                        case .snapshot(let value), .progress(let value):
                            try validateIdentity(value)
                            guard value.epoch == snapshot.epoch else { throw ServerClientError.disconnected }
                            if value.revision >= snapshot.revision { snapshot = value }
                            confirmed = snapshot.continuationID == continuationID
                        case .error(let error): throw RecordingTransferError.server(error)
                        case .ack: throw ServerClientError.invalidResponse
                        }
                    }
                    try spool.markSnapshot(snapshot)
                    await onUpdate(snapshot)
                }
                sentContext = true
            }
            let timings = spool.runTimings
            let endpoints = spool.finalManifest
            let closed = snapshot.closedRuns ?? []
            let currentRun = timings.first { timing in
                !endpoints.filter { $0.runID == timing.runID }.allSatisfy { closed.contains($0) }
            }
            let allowedRuns = currentRun.map { Set([$0.runID]) } ?? []
            if let batch = try spool.nextBatch(after: snapshot.streams, runIDs: allowedRuns) {
                var header = batch.header
                header.epoch = snapshot.epoch
                try RecordingUploadCursor.validate(header, after: snapshot.streams)
                try await socket.send(binary: RecordingWire.encodeAudio(header: header, pcm: batch.data))
                var acknowledged = false
                while !acknowledged {
                    switch try await receive(socket) {
                    case .ack(let ack):
                        try RecordingUploadCursor.apply(ack, expected: header, to: &snapshot)
                        acknowledged = true
                    case .snapshot(let value), .progress(let value):
                        try validateIdentity(value)
                        guard value.epoch == snapshot.epoch else { throw ServerClientError.disconnected }
                        if value.revision >= snapshot.revision { snapshot = value }
                    case .error(let error): throw RecordingTransferError.server(error)
                    }
                }
                try spool.markSnapshot(snapshot)
                await onUpdate(snapshot)
                continue
            }
            if let currentRun, currentRun.endedAt != nil,
               !spool.isSealed || currentRun.runID != timings.last?.runID {
                // Close every prior run before a resumed run can upload. This
                // preserves its exact endpoints and format/timeline boundaries.
                let runs = endpoints.filter { $0.runID == currentRun.runID }
                let pause = RecordingPauseRequest(epoch: snapshot.epoch, runs: runs,
                                                  runTimings: [currentRun], interruption: spool.interruption)
                try await socket.send(control: RecordingWire.encoder().encode(RecordingClientMessage.pause(pause)))
                var confirmed = false
                while !confirmed {
                    switch try await receive(socket) {
                    case .snapshot(let value), .progress(let value):
                        try validateIdentity(value)
                        guard value.epoch == snapshot.epoch else { throw ServerClientError.disconnected }
                        if value.revision >= snapshot.revision { snapshot = value }
                        confirmed = runs.allSatisfy { snapshot.closedRuns?.contains($0) == true }
                    case .ack: throw ServerClientError.invalidResponse
                    case .error(let error): throw RecordingTransferError.server(error)
                    }
                }
                try spool.markSnapshot(snapshot)
                await onUpdate(snapshot)
                continue
            }
            if spool.isSealed {
                if !sentStop {
                    let stop = RecordingStopRequest(epoch: snapshot.epoch, runs: spool.finalManifest, runTimings: spool.runTimings)
                    try await socket.send(control: RecordingWire.encoder().encode(RecordingClientMessage.stop(stop)))
                    sentStop = true
                }
                switch try await receive(socket) {
                case .snapshot(let value), .progress(let value):
                    try validateIdentity(value)
                    guard value.epoch == snapshot.epoch else { throw ServerClientError.disconnected }
                    if value.revision >= snapshot.revision { snapshot = value }
                    try spool.markSnapshot(snapshot)
                    await onUpdate(snapshot)
                case .ack: throw ServerClientError.invalidResponse
                case .error(let error): throw RecordingTransferError.server(error)
                }
            } else if spool.isPaused {
                switch try await receive(socket) {
                case .snapshot(let value), .progress(let value):
                    try validateIdentity(value)
                    guard value.epoch == snapshot.epoch else { throw ServerClientError.disconnected }
                    if value.revision >= snapshot.revision { snapshot = value }
                    try spool.markSnapshot(snapshot)
                    await onUpdate(snapshot)
                case .ack: throw ServerClientError.invalidResponse
                case .error(let error): throw RecordingTransferError.server(error)
                }
            } else {
                // No audio is copied from capture into a network queue. Poll the
                // committed spool while the writer owns its bounded callback pool.
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func validateIdentity(_ snapshot: RecordingSnapshot) throws {
        let admitted = spool.snapshot
        guard snapshot.id == admitted.id, snapshot.requestID == admitted.requestID,
              snapshot.device == admitted.device, snapshot.settings == admitted.settings,
              snapshot.epoch > 0 else { throw ServerClientError.invalidResponse }
    }

    private func receive(_ socket: any RecordingSocket) async throws -> RecordingServerMessage {
        try await withThrowingTaskGroup(of: RecordingServerMessage.self) { group in
            group.addTask {
                let data = try await socket.receive()
                guard data.count <= RecordingWire.maximumServerControlMessageBytes else { throw ServerClientError.invalidResponse }
                return try RecordingWire.decoder().decode(RecordingServerMessage.self, from: data)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                // Closing makes a suspended URLSession receive return too, so
                // cancellation of the child cannot leave the group hung.
                socket.close()
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw ServerClientError.disconnected }
            return value
        }
    }
}

private enum RecordingTransferError: LocalizedError {
    case server(RecordingProtocolError)
    case processingFailed(String)
    var errorDescription: String? {
        switch self {
        case .server(let error): error.message
        case .processingFailed(let message): message
        }
    }
}

/// ACK counters are verified against exactly the batch in flight. Reconnect
/// snapshots may include that batch already, which safely resolves a lost ACK.
enum RecordingUploadCursor {
    static func validate(_ header: RecordingAudioHeader, after streams: [RecordingStreamCheckpoint]) throws {
        let position = streams.first { $0.runID == header.runID && $0.kind == header.kind }
        guard header.sequence == (position?.nextSequence ?? 0), header.firstFrame == (position?.frameCount ?? 0),
              position.map({ $0.format == header.format }) ?? true else { throw ServerClientError.invalidResponse }
    }

    static func isAcknowledged(_ header: RecordingAudioHeader, by streams: [RecordingStreamCheckpoint]) -> Bool {
        streams.contains { stream in
            stream.runID == header.runID && stream.kind == header.kind && stream.format == header.format
                && stream.nextSequence == header.sequence + 1 && stream.frameCount == header.firstFrame + header.frameCount
        }
    }

    static func apply(_ ack: RecordingAck, expected header: RecordingAudioHeader, to snapshot: inout RecordingSnapshot) throws {
        guard ack.runID == header.runID, ack.kind == header.kind,
              ack.nextSequence == header.sequence + 1, ack.frameCount == header.firstFrame + header.frameCount,
              ack.revision >= 0 else { throw ServerClientError.invalidResponse }
        let checkpoint = RecordingStreamCheckpoint(runID: header.runID, kind: header.kind, format: header.format,
                                                   nextSequence: ack.nextSequence, frameCount: ack.frameCount)
        if let index = snapshot.streams.firstIndex(where: { $0.runID == header.runID && $0.kind == header.kind }) {
            snapshot.streams[index] = checkpoint
        } else { snapshot.streams.append(checkpoint) }
        snapshot.revision = max(snapshot.revision, ack.revision)
        snapshot.uploadedFrames = snapshot.streams.filter { $0.kind == .inference }.reduce(0) { $0 + $1.frameCount }
    }
}
