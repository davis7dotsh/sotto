import AVFoundation
import CoreAudio
import Foundation
import V07API
import V07Core
import XCTest
@testable import V07

final class DictationQueueTests: XCTestCase {
    @MainActor
    func testReleasedTakesUploadIndependentlyAndDeliverInRecordingOrder() async throws {
        let fixture = try QueueControllerFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 1 }
        let first = try XCTUnwrap(fixture.server.created.first)

        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 2 }
        let second = try XCTUnwrap(fixture.server.created.last)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(fixture.controller.canTest, "A server queue must not disable the next recording")

        fixture.server.complete(second, text: "Second take")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fixture.server.deliveries.isEmpty, "A fast later result must wait for the earlier destination transaction")
        fixture.server.complete(first, text: "First take")
        try await waitUntil { fixture.server.deliveries.count == 2 && !fixture.controller.isBusy }
        XCTAssertEqual(fixture.server.deliveries, [first, second])
        XCTAssertEqual(fixture.controller.lastTranscript, "Second take")
        XCTAssertEqual(fixture.controller.activity, .success)
        XCTAssertNil(fixture.controller.errorMessage)
    }

    @MainActor
    func testOlderCompletionCannotReplaceNewRecordingState() async throws {
        let fixture = try QueueControllerFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 1 }
        let first = try XCTUnwrap(fixture.server.created.first)

        fixture.controller.toggleTestRecording()
        try await waitUntil { fixture.controller.isRecording }
        fixture.server.complete(first, text: "Earlier result")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fixture.controller.isRecording)
        XCTAssertEqual(fixture.controller.statusMessage, "Listening")
        XCTAssertTrue(fixture.server.deliveries.isEmpty, "Delivery waits for the active capture to release")
        XCTAssertNil(fixture.controller.errorMessage)
        fixture.controller.cancelDictation()
        try await waitUntil { fixture.server.deliveries == [first] && !fixture.controller.isBusy }
        XCTAssertEqual(fixture.controller.lastTranscript, "Earlier result")
    }

    @MainActor
    func testSameTurnRepressAndCancelCannotDiscardReleasedAudio() async throws {
        let fixture = try QueueControllerFixture()
        defer { fixture.close() }
        try await fixture.ready()
        fixture.controller.toggleTestRecording()
        try await waitUntil { fixture.controller.isRecording }
        try await Task.sleep(for: .milliseconds(275))
        let first = try XCTUnwrap(fixture.server.created.first)

        // No suspension between release, repress, and cancel: the old stop task
        // has not run yet, so a shared recorder request would be stolen here.
        fixture.controller.toggleTestRecording()
        fixture.controller.toggleTestRecording()
        XCTAssertEqual(fixture.controller.activity, .starting)
        fixture.controller.cancelDictation()
        try await waitUntil { fixture.server.finishing.contains(first) }
        XCTAssertFalse(fixture.server.cancelled.contains(first))
        fixture.server.complete(first, text: "Keep these words")
        try await waitUntil { fixture.server.deliveries == [first] && !fixture.controller.isBusy }
        XCTAssertEqual(fixture.controller.lastTranscript, "Keep these words")
        XCTAssertNil(fixture.controller.errorMessage)
    }

    @MainActor
    func testCancellingLatestQueuedTakePreservesEarlierWork() async throws {
        let fixture = try QueueControllerFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 1 }
        let first = try XCTUnwrap(fixture.server.created.first)
        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 2 }
        let second = try XCTUnwrap(fixture.server.created.last)

        fixture.controller.cancelDictation()
        try await waitUntil { fixture.server.cancelled.contains(second) }
        XCTAssertFalse(fixture.server.cancelled.contains(first))
        fixture.server.complete(first, text: "Earlier take survives")
        try await waitUntil { fixture.server.deliveries == [first] && !fixture.controller.isBusy }
        XCTAssertEqual(fixture.controller.lastTranscript, "Earlier take survives")
        XCTAssertEqual(fixture.controller.activity, .success)
        XCTAssertNil(fixture.controller.errorMessage)
    }

    @MainActor
    func testCancellingMiddleTakeDoesNotLetLaterDeliveryOvertakeEarlierWork() async throws {
        let fixture = try QueueControllerFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 1 }
        let first = try XCTUnwrap(fixture.server.created.first)
        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 2 }
        let cancelled = try XCTUnwrap(fixture.server.created.last)
        fixture.controller.cancelDictation()
        try await waitUntil { fixture.server.cancelled.contains(cancelled) }

        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 3 }
        let third = try XCTUnwrap(fixture.server.created.last)
        fixture.server.complete(third, text: "Third take")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fixture.server.deliveries.isEmpty, "Cancelling a middle take must retain its preceding delivery dependency")
        fixture.server.complete(first, text: "First take")
        try await waitUntil { fixture.server.deliveries.count == 2 && !fixture.controller.isBusy }
        XCTAssertEqual(fixture.server.deliveries, [first, third])
        XCTAssertEqual(fixture.controller.lastTranscript, "Third take")
    }

    @MainActor
    func testQueuedTakesDoNotReuseTheSameDeliveredListContinuation() async throws {
        let fixture = try QueueControllerFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 1 }
        let delivered = try XCTUnwrap(fixture.server.created.first)
        fixture.server.complete(delivered, text: "1. First item", listNextNumber: 2)
        try await waitUntil { fixture.server.deliveries == [delivered] && !fixture.controller.isBusy }

        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 2 }
        let second = try XCTUnwrap(fixture.server.created.last)
        XCTAssertEqual(fixture.server.finishValue(second)?.continuationID, delivered)
        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 3 }
        let third = try XCTUnwrap(fixture.server.created.last)
        XCTAssertNil(fixture.server.finishValue(third)?.continuationID,
                     "A queued take must not independently extend the same old numbered-list snapshot")
        XCTAssertEqual(fixture.server.deliveries, [delivered], "Uploading and sealing must not wait for the preceding result")
        fixture.server.complete(second, text: "2. Second item", listNextNumber: 3)
        fixture.server.complete(third, text: "Third take")
        try await waitUntil { fixture.server.deliveries.count == 3 && !fixture.controller.isBusy }
    }

    @MainActor
    func testOlderFailureIsVisibleWithoutReplacingTheActiveRecording() async throws {
        let fixture = try QueueControllerFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 1 }
        let first = try XCTUnwrap(fixture.server.created.first)
        fixture.controller.toggleTestRecording()
        try await waitUntil { fixture.controller.isRecording }
        fixture.server.fail(first, message: "Speech processing failed")
        try await waitUntil { fixture.controller.errorMessage?.contains("Speech processing failed") == true }
        XCTAssertEqual(fixture.controller.activity, .recording)
        XCTAssertEqual(fixture.controller.statusMessage, "Listening")
        XCTAssertEqual(fixture.controller.lastDeliveryStatus, .failed)
        XCTAssertTrue(fixture.controller.lastDelivery.contains("Earlier dictation failed"))
        XCTAssertTrue(fixture.server.deliveries.isEmpty)
        fixture.controller.cancelDictation()
    }

    @MainActor
    func testRepeatedCancellationDrainsPendingTakesAndAllowsAnotherHold() async throws {
        let fixture = try QueueControllerFixture()
        defer { fixture.close() }
        try await fixture.ready()
        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 1 }
        let first = try XCTUnwrap(fixture.server.created.first)
        try await fixture.recordAndRelease()
        try await waitUntil { fixture.server.finishing.count == 2 }
        let second = try XCTUnwrap(fixture.server.created.last)

        fixture.controller.cancelDictation()
        XCTAssertTrue(fixture.controller.isBusy)
        fixture.controller.cancelDictation()
        try await waitUntil { fixture.server.cancelled.count == 2 && !fixture.controller.isBusy }
        XCTAssertEqual(Set(fixture.server.cancelled), Set([first, second]))
        XCTAssertTrue(fixture.server.deliveries.isEmpty)
        XCTAssertEqual(fixture.controller.activity, .idle)
        fixture.controller.toggleTestRecording()
        try await waitUntil { fixture.controller.isRecording }
        fixture.controller.cancelDictation()
    }
}

@MainActor
private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(predicate(), "Timed out waiting for dictation state", file: file, line: line)
    if !predicate() { throw URLError(.timedOut) }
}

@MainActor
private final class QueueControllerFixture {
    let server = QueueHTTPFixture()
    let controller: V07Controller
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("V07-queue-tests-\(UUID())")

    init() throws {
        let server = server
        let device = AudioInputDevice(uid: "queue-test", name: "Synthetic microphone", transport: .usb)
        let devices = AudioDeviceStore(hardware: AudioHardwareClient(snapshot: {
            AudioHardwareSnapshot(deviceIDs: [42], inputs: [AudioInputHandle(deviceID: 42, device: device)], systemDefaultID: 42)
        }, observe: { _, _, _, _ in nil }))
        devices.start()
        let recorder = AudioRecorder(worker: AudioCaptureWorker(makeHardware: { _ in QueueAudioHardware() }),
                                     microphoneAuthorized: { true }, sleepNotifications: NotificationCenter())
        let configuration = ConfigurationStore(file: ConfigurationFile(url: root.appendingPathComponent("config.json")))
        controller = V07Controller(configuration: configuration, startServices: false,
                                   recorder: recorder, audioDevices: devices,
                                   serverClient: { try ServerClient(endpoint: server.endpoint, token: "", session: server.session) })
        controller.microphones.update(devices: [device], systemDefaultUID: device.uid)
        controller.permissions = PermissionSnapshot(microphone: true, accessibility: false, inputMonitoring: false)
    }

    func ready() async throws {
        controller.refreshServer()
        try await waitUntil { self.controller.canTest }
    }

    func recordAndRelease() async throws {
        controller.toggleTestRecording()
        try await waitUntil { self.controller.isRecording }
        try await Task.sleep(for: .milliseconds(275))
        controller.toggleTestRecording()
    }

    func close() {
        controller.shutdown()
        // Shutdown submits best-effort server cancellation tasks. Their captured
        // clients keep this session alive until those requests have been sent.
        try? FileManager.default.removeItem(at: root)
    }
}

private final class QueueAudioHardware: AudioCaptureHardware {
    private var writer: RecordingWriter?

    func start(request: AudioCaptureRequest, deviceID: AudioDeviceID?, preserveOriginalAudio: Bool,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable (String) -> Void) throws {
        try request.requireOpen()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let writer = try RecordingWriter(inputFormat: format, preserveOriginalAudio: preserveOriginalAudio,
                                         onLevel: { _ in }, onError: { _ in }, onChunk: request.onChunk)
        self.writer = writer
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0.1, count: 8_000)
        writer.append(buffer)
    }

    func stop() -> RecordingWriter? {
        defer { writer = nil }
        return writer
    }

    func cancel() { writer?.cancel(); writer = nil }
}

/// Keeps finish responses pending while accepting unrelated recordings. Using
/// URLSession and the real uploader exercises take ownership across suspension.
private final class QueueHTTPFixture: @unchecked Sendable {
    let id = UUID().uuidString.lowercased()
    let session: URLSession
    var endpoint: String { "https://\(id).queue-test" }
    private let lock = NSLock()
    private var records: [GenerationRecord] = []
    private var finishRequests: [UUID: QueueURLProtocol] = [:]
    private var finishValues: [UUID: FinishGenerationRequest] = [:]
    private var delivered: [UUID] = []
    private var cancellations: [UUID] = []
    private var uploadedFrames: [String: Int64] = [:]
    var created: [UUID] { lock.withLock { records.map(\.id) } }
    var finishing: Set<UUID> { lock.withLock { Set(finishRequests.keys) } }
    var deliveries: [UUID] { lock.withLock { delivered } }
    var cancelled: [UUID] { lock.withLock { cancellations } }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueURLProtocol.self]
        session = URLSession(configuration: configuration)
        QueueURLProtocol.register(self)
    }

    deinit { QueueURLProtocol.unregister(id) }

    func finishValue(_ id: UUID) -> FinishGenerationRequest? { lock.withLock { finishValues[id] } }

    func fail(_ id: UUID, message: String) {
        let response = lock.withLock { () -> (QueueURLProtocol, GenerationRecord)? in
            guard let pending = finishRequests[id], let index = records.firstIndex(where: { $0.id == id }) else { return nil }
            records[index].status = .failed
            records[index].error = message
            return (pending, records[index])
        }
        if let (pending, record) = response { pending.respond(record) }
    }

    func complete(_ id: UUID, text: String, listNextNumber: Int? = nil) {
        let response = lock.withLock { () -> (QueueURLProtocol, GenerationRecord)? in
            guard let pending = finishRequests[id], let index = records.firstIndex(where: { $0.id == id }) else { return nil }
            records[index].status = .completed
            records[index].finalText = text
            records[index].insertionText = text
            if let listNextNumber {
                records[index].continuation = .init(list: .init(style: .numbered, nextNumber: listNextNumber),
                                                  preview: text, boundary: .line)
            }
            return (pending, records[index])
        }
        if let (pending, record) = response { pending.respond(record) }
    }

    func handle(_ transport: QueueURLProtocol) throws {
        let request = transport.request
        let parts = request.url!.pathComponents
        if parts.last == "health" {
            let model = ModelRuntimeInfo(modelID: "test", backend: "test", ready: true)
            transport.respond(ServerHealth(ready: true, speech: model, proofreading: model))
        } else if parts.last == "preferences" {
            transport.respond(PreferencesSnapshot())
        } else if parts.last == "generations", request.httpMethod == "POST" {
            let record = GenerationRecord(requestID: UUID(), device: .init(id: "test", name: "Test"), mode: .test, settings: .init())
            lock.withLock { records.append(record) }
            transport.respond(record)
        } else if parts.last == "generations" {
            transport.respond(GenerationPage(items: lock.withLock { records }))
        } else if parts.count >= 4, let id = UUID(uuidString: parts[3]) {
            switch parts.last {
            case "finish":
                let value = try V07API.decodeWire(FinishGenerationRequest.self, from: body(request))
                lock.withLock { finishValues[id] = value; finishRequests[id] = transport }
            case "cancel":
                lock.withLock { cancellations.append(id) }
                transport.respondEmpty()
            case "delivery":
                lock.withLock { delivered.append(id) }
                transport.respondEmpty()
            case "inference", "original":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let sequence = Int(query.first { $0.name == "sequence" }!.value!)!
                let channels = Int(query.first { $0.name == "channels" }!.value!)!
                let bytes = try body(request).count
                let frames = lock.withLock {
                    let key = "\(id)-\(parts.last!)"
                    uploadedFrames[key, default: 0] += Int64(bytes / (4 * channels))
                    return uploadedFrames[key]!
                }
                transport.respond(AudioChunkReceipt(nextSequence: sequence + 1, frameCount: frames))
            default: transport.respondEmpty(status: 404)
            }
        } else { transport.respondEmpty(status: 404) }
    }

    private func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class QueueURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: WeakFixture] = [:]
    private struct WeakFixture { weak var value: QueueHTTPFixture? }
    private let responseLock = NSLock()
    private var stopped = false
    static func register(_ fixture: QueueHTTPFixture) { lock.withLock { fixtures[fixture.id] = WeakFixture(value: fixture) } }
    static func unregister(_ id: String) { _ = lock.withLock { fixtures.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".queue-test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = String((request.url?.host ?? "").dropLast(".queue-test".count))
        guard let fixture = Self.lock.withLock({ Self.fixtures[id]?.value }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        do { try fixture.handle(self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { responseLock.withLock { stopped = true } }

    func respond<T: APIWireModel>(_ value: T) {
        do { respondData(try V07API.encodeWire(value), status: 200) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    func respondEmpty(status: Int = 200) { respondData(Data(), status: status) }
    private func respondData(_ data: Data, status: Int) {
        let shouldRespond = responseLock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldRespond else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
