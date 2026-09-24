import AVFoundation
import Foundation
import V07API
import XCTest
@testable import V07

final class ServerClientTests: XCTestCase {
    func testConnectionRejectsCredentialsInURLsAndKeepsBearerInHeader() throws {
        XCTAssertThrowsError(try ServerClient(endpoint: "https://person:secret@example.com", token: ""))
        XCTAssertThrowsError(try ServerClient(endpoint: "https://example.com?token=secret", token: ""))
        let client = try ServerClient(endpoint: "https://example.com/v07", token: "private-token")
        let request = try client.request(path: "v1/health")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v07/v1/health")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-token")
        XCTAssertFalse(request.url?.absoluteString.contains("private-token") == true)
    }

    func testKnownWisprFlowIDsBatchesLargeHistoryWithinServerLimits() async throws {
        let fixture = HTTPFixture()
        defer { fixture.session.invalidateAndCancel() }
        let sourceIDs = (0..<10_501).map { _ in UUID() }
        let expected = Set([sourceIDs[0], sourceIDs[4_999], sourceIDs[5_000],
                            sourceIDs[9_999], sourceIDs[10_000], sourceIDs[10_500]])
        let capturedBodies = RequestBodyCollector()
        fixture.respond = { request in
            let body = try requestBody(request)
            capturedBodies.append(body)
            let input = try V07API.decoder().decode(WisprFlowKnownIDsRequest.self, from: body)
            guard input.sourceIDs.count <= 10_000, body.count <= 262_144 else {
                return (413, try V07API.encoder().encode(APIErrorResponse(
                    code: "source_id_limit", message: "Source ID lookup exceeds server limits")))
            }
            return (200, try V07API.encoder().encode(WisprFlowKnownIDsResponse(
                knownSourceIDs: input.sourceIDs.filter { expected.contains($0) })))
        }

        let client = try ServerClient(endpoint: fixture.endpoint, token: "", session: fixture.session)
        let known = try await client.knownWisprFlowSourceIDs(sourceIDs)
        XCTAssertEqual(known, expected)
        let bodies = capturedBodies.values
        XCTAssertEqual(bodies.count, 3)
        let batches = try bodies.map {
            try V07API.decoder().decode(WisprFlowKnownIDsRequest.self, from: $0)
        }
        XCTAssertEqual(batches.map { $0.sourceIDs.count }, [5_000, 5_000, 501])
        XCTAssertEqual(batches.flatMap(\.sourceIDs), sourceIDs)
        XCTAssertTrue(bodies.allSatisfy { $0.count <= 262_144 })
    }

    func testLiveUploadPreservesIndependentSequencesAndExactFrameTotals() async throws {
        let fixture = HTTPFixture()
        defer { fixture.session.invalidateAndCancel() }
        fixture.respond = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let sequence = Int(query.first { $0.name == "sequence" }!.value!)!
            let original = request.url!.path.hasSuffix("/original")
            return (200, try V07API.encoder().encode(AudioChunkReceipt(nextSequence: sequence + 1,
                frameCount: Int64((sequence + 1) * (original ? 24_000 : 8_000)))))
        }
        let client = try ServerClient(endpoint: fixture.endpoint, token: "test", session: fixture.session)
        let pipe = AudioChunkPipe()
        for _ in 0..<2 {
            pipe.append(.init(kind: .original, data: Data(repeating: 0, count: 96_000), sampleRate: 48_000, channels: 1))
            pipe.append(.init(kind: .normalized, data: Data(repeating: 0, count: 32_000), sampleRate: 16_000, channels: 1))
        }
        pipe.finish()
        let result = try await client.upload(pipe.stream, to: UUID(), preserveOriginal: true)
        XCTAssertEqual(result.inferenceFrames, 16_000)
        XCTAssertEqual(result.originalFrames, 48_000)
        XCTAssertEqual(fixture.requests.count, 4)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.httpMethod == "POST" })
        XCTAssertTrue(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test" })
    }

    func testRejectedChunkStopsUploadBeforeAnotherChunkCanBeSent() async throws {
        let fixture = HTTPFixture()
        defer { fixture.session.invalidateAndCancel() }
        fixture.respond = { _ in (409, try V07API.encoder().encode(APIErrorResponse(code: "sequence", message: "Upload sequence mismatch"))) }
        let client = try ServerClient(endpoint: fixture.endpoint, token: "", session: fixture.session)
        let pipe = AudioChunkPipe()
        for _ in 0..<2 {
            pipe.append(.init(kind: .normalized, data: Data(repeating: 0, count: 32_000), sampleRate: 16_000, channels: 1))
        }
        pipe.finish()
        do {
            _ = try await client.upload(pipe.stream, to: UUID(), preserveOriginal: false)
            XCTFail("Rejected upload must fail instead of sealing or continuing")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Upload sequence mismatch")
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testRecorderStreamsOriginalChannelsAndEveryNormalizedFrameBeforeFinishing() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                channels: 2, interleaved: false))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        input.frameLength = 4_800
        let samples = try XCTUnwrap(input.floatChannelData)
        for index in 0..<4_800 { samples[0][index] = 0.25; samples[1][index] = -0.5 }
        let chunks = ChunkCollector()
        let writer = try RecordingWriter(inputFormat: format, preserveOriginalAudio: true,
                                         onLevel: { _ in }, onError: { _ in }, onChunk: { chunks.append($0) })
        writer.append(input)
        let audio = try await writer.finish()
        defer { audio.cleanup() }
        let original = chunks.values.filter { if case .original = $0.kind { return true }; return false }
        let normalized = chunks.values.filter { if case .normalized = $0.kind { return true }; return false }
        XCTAssertEqual(original.reduce(0) { $0 + $1.data.count }, 4_800 * 2 * 4)
        XCTAssertEqual(normalized.reduce(0) { $0 + $1.data.count } / 4, Int((audio.duration * 16_000).rounded()))
        XCTAssertTrue(normalized.allSatisfy { $0.sampleRate == 16_000 && $0.channels == 1 })
        let first = try XCTUnwrap(original.first)
        let pair = first.data.withUnsafeBytes { bytes in
            (bytes.loadUnaligned(fromByteOffset: 0, as: Float.self), bytes.loadUnaligned(fromByteOffset: 4, as: Float.self))
        }
        XCTAssertEqual(pair.0, 0.25)
        XCTAssertEqual(pair.1, -0.5)
    }

    func testBackpressureFailsInsteadOfKeepingAnOfflineRecordingQueue() async throws {
        let pipe = AudioChunkPipe()
        for _ in 0..<514 {
            pipe.append(.init(kind: .normalized, data: Data([0, 0, 0, 0]), sampleRate: 16_000, channels: 1))
        }
        do {
            for try await _ in pipe.stream {}
            XCTFail("An overloaded stream must fail")
        } catch ServerClientError.uploadBacklog {
        } catch { XCTFail("Unexpected failure: \(error)") }
    }
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotParseResponse) }
        if count == 0 { break }
        body.append(buffer, count: count)
    }
    return body
}

private final class RequestBodyCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    var values: [Data] { lock.withLock { bodies } }
    func append(_ body: Data) { lock.withLock { bodies.append(body) } }
}

private final class HTTPFixture: @unchecked Sendable {
    let id = UUID().uuidString.lowercased()
    let session: URLSession
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var respond: ((URLRequest) throws -> (Int, Data))?
    var endpoint: String { "https://\(id).test" }
    var requests: [URLRequest] { lock.withLock { captured } }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        session = URLSession(configuration: configuration)
        FixtureURLProtocol.register(self)
    }
    deinit { FixtureURLProtocol.unregister(id) }
    func response(_ request: URLRequest) throws -> (Int, Data) {
        lock.withLock { captured.append(request) }
        return try respond?(request) ?? (500, Data())
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: WeakFixture] = [:]
    private struct WeakFixture { weak var value: HTTPFixture? }
    static func register(_ fixture: HTTPFixture) { lock.withLock { fixtures[fixture.id] = WeakFixture(value: fixture) } }
    static func unregister(_ id: String) { _ = lock.withLock { fixtures.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = String((request.url?.host ?? "").dropLast(5))
        guard let fixture = Self.lock.withLock({ Self.fixtures[id]?.value }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        do {
            let (status, data) = try fixture.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [CapturedAudioChunk] = []
    var values: [CapturedAudioChunk] { lock.withLock { chunks } }
    func append(_ chunk: CapturedAudioChunk) { lock.withLock { chunks.append(chunk) } }
}
