import Foundation

public struct RecordingCapabilities: Codable, Equatable, Sendable {
    public var protocolName: String
    public var maximumPCMBytes: Int
    private enum CodingKeys: String, CodingKey { case protocolName = "protocol", maximumPCMBytes }
    public init(protocolName: String = RecordingWire.webSocketProtocol, maximumPCMBytes: Int = RecordingWire.maximumPCMBytes) {
        self.protocolName = protocolName; self.maximumPCMBytes = maximumPCMBytes
    }
}

public enum RecordingCaptureState: String, Codable, Equatable, Sendable {
    case recording, interrupted, stopped, discarded
}

public enum RecordingProcessingState: String, Codable, Equatable, Sendable {
    case queued, processing, completed, failed
}

public struct RecordingProtocolError: Codable, Equatable, Sendable, Error {
    public var code: String
    public var message: String
    public var retryable: Bool
    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code; self.message = message; self.retryable = retryable
    }
}

public struct RecordingStreamCheckpoint: Codable, Equatable, Sendable {
    public var runID: UUID
    public var kind: AudioKind
    public var format: AudioStreamFormat
    public var nextSequence: Int
    public var frameCount: Int64
    public init(runID: UUID, kind: AudioKind, format: AudioStreamFormat, nextSequence: Int = 0, frameCount: Int64 = 0) {
        self.runID = runID; self.kind = kind; self.format = format
        self.nextSequence = nextSequence; self.frameCount = frameCount
    }
}

public struct RecordingRunEndpoint: Codable, Equatable, Sendable {
    public var runID: UUID
    public var inferenceFrames: Int64
    public var originalFrames: Int64?
    public init(runID: UUID, inferenceFrames: Int64, originalFrames: Int64? = nil) {
        self.runID = runID; self.inferenceFrames = inferenceFrames; self.originalFrames = originalFrames
    }
}

public struct RecordingRunTiming: Codable, Equatable, Sendable {
    public var runID: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var gapBeforeMilliseconds: Int64?
    public init(runID: UUID, startedAt: Date, endedAt: Date? = nil, gapBeforeMilliseconds: Int64? = nil) {
        self.runID = runID; self.startedAt = startedAt; self.endedAt = endedAt
        self.gapBeforeMilliseconds = gapBeforeMilliseconds
    }
}

public struct RecordingSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var requestID: UUID
    public var device: DeviceIdentity
    public var mode: GenerationMode
    public var settings: PreferencesSnapshot
    public var createdAt: Date
    public var revision: Int
    public var captureState: RecordingCaptureState
    public var processingState: RecordingProcessingState
    public var uploadedFrames: Int64
    public var transcribedFrames: Int64
    public var proofreadFrames: Int64
    public var streams: [RecordingStreamCheckpoint]
    public var epoch: Int
    public var stopRuns: [RecordingRunEndpoint]?
    public var closedRuns: [RecordingRunEndpoint]?
    public var runTimings: [RecordingRunTiming]?
    public var continuationID: UUID?
    public var error: String?
    public var previewText: String
    public init(id: UUID, requestID: UUID, device: DeviceIdentity, mode: GenerationMode = .dictation,
                settings: PreferencesSnapshot, createdAt: Date = Date(), revision: Int = 0,
                captureState: RecordingCaptureState = .recording, processingState: RecordingProcessingState = .queued,
                uploadedFrames: Int64 = 0, transcribedFrames: Int64 = 0, proofreadFrames: Int64 = 0,
                streams: [RecordingStreamCheckpoint] = [], epoch: Int = 0,
                stopRuns: [RecordingRunEndpoint]? = nil, closedRuns: [RecordingRunEndpoint]? = nil,
                runTimings: [RecordingRunTiming]? = nil, continuationID: UUID? = nil, error: String? = nil, previewText: String = "") {
        self.id = id; self.requestID = requestID; self.device = device; self.mode = mode; self.settings = settings
        self.createdAt = createdAt; self.revision = revision; self.captureState = captureState
        self.processingState = processingState; self.uploadedFrames = uploadedFrames
        self.transcribedFrames = transcribedFrames; self.proofreadFrames = proofreadFrames
        self.streams = streams; self.epoch = epoch; self.stopRuns = stopRuns; self.closedRuns = closedRuns
        self.runTimings = runTimings; self.continuationID = continuationID
        self.error = error; self.previewText = previewText
    }
}

public typealias RecordingSessionSnapshot = RecordingSnapshot

public struct RecordingDetail: Codable, Equatable, Sendable {
    public var snapshot: RecordingSnapshot
    public var result: GenerationRecord?
    public init(snapshot: RecordingSnapshot, result: GenerationRecord? = nil) {
        self.snapshot = snapshot; self.result = result
    }
}

public struct RecordingPage: Codable, Equatable, Sendable {
    public var items: [RecordingSnapshot]
    public var nextCursor: String?
    public init(items: [RecordingSnapshot], nextCursor: String? = nil) {
        self.items = items; self.nextCursor = nextCursor
    }
}

public struct RecordingAudioHeader: Codable, Equatable, Sendable {
    public var type: String
    public var epoch: Int
    public var runID: UUID
    public var kind: AudioKind
    public var sequence: Int
    public var firstFrame: Int64
    public var format: AudioStreamFormat
    public var frameCount: Int64
    public var sha256: String
    public init(epoch: Int, runID: UUID, kind: AudioKind, sequence: Int, firstFrame: Int64,
                format: AudioStreamFormat, frameCount: Int64, sha256: String) {
        type = "audio"; self.epoch = epoch; self.runID = runID; self.kind = kind
        self.sequence = sequence; self.firstFrame = firstFrame; self.format = format
        self.frameCount = frameCount; self.sha256 = sha256
    }
}

public struct RecordingAudioMessage: Equatable, Sendable {
    public var header: RecordingAudioHeader
    public var pcm: Data
    public init(header: RecordingAudioHeader, pcm: Data) { self.header = header; self.pcm = pcm }
}

public struct RecordingStopRequest: Codable, Equatable, Sendable {
    public var type: String
    public var epoch: Int
    public var runs: [RecordingRunEndpoint]
    public var runTimings: [RecordingRunTiming]?
    public init(epoch: Int, runs: [RecordingRunEndpoint], runTimings: [RecordingRunTiming]? = nil) {
        type = "stop"; self.epoch = epoch; self.runs = runs; self.runTimings = runTimings
    }
}

public struct RecordingPauseRequest: Codable, Equatable, Sendable {
    public var type: String
    public var epoch: Int
    public var runs: [RecordingRunEndpoint]
    public var runTimings: [RecordingRunTiming]
    public var interruption: String?
    public init(epoch: Int, runs: [RecordingRunEndpoint], runTimings: [RecordingRunTiming], interruption: String? = nil) {
        type = "pause"; self.epoch = epoch; self.runs = runs
        self.runTimings = runTimings; self.interruption = interruption
    }
}

public struct RecordingAck: Codable, Equatable, Sendable {
    public var type: String
    public var runID: UUID
    public var kind: AudioKind
    public var nextSequence: Int
    public var frameCount: Int64
    public var revision: Int
    public init(runID: UUID, kind: AudioKind, nextSequence: Int, frameCount: Int64, revision: Int) {
        type = "ack"; self.runID = runID; self.kind = kind
        self.nextSequence = nextSequence; self.frameCount = frameCount; self.revision = revision
    }
}

public struct RecordingContextRequest: Codable, Equatable, Sendable {
    public var type: String
    public var epoch: Int
    public var continuationID: UUID
    public init(epoch: Int, continuationID: UUID) {
        type = "context"; self.epoch = epoch; self.continuationID = continuationID
    }
}

public enum RecordingClientMessage: Codable, Equatable, Sendable {
    case resume
    case stop(RecordingStopRequest)
    case pause(RecordingPauseRequest)
    case context(RecordingContextRequest)
    case ping
    private enum CodingKeys: String, CodingKey { case type }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "resume": self = .resume
        case "stop": self = .stop(try RecordingStopRequest(from: decoder))
        case "pause": self = .pause(try RecordingPauseRequest(from: decoder))
        case "context": self = .context(try RecordingContextRequest(from: decoder))
        case "ping": self = .ping
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown recording control message.")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .stop(let request): try request.encode(to: encoder)
        case .pause(let request): try request.encode(to: encoder)
        case .context(let request): try request.encode(to: encoder)
        case .resume, .ping:
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(self == .resume ? "resume" : "ping", forKey: .type)
        }
    }
}

public enum RecordingServerMessage: Codable, Equatable, Sendable {
    case snapshot(RecordingSnapshot)
    case progress(RecordingSnapshot)
    case ack(RecordingAck)
    case error(RecordingProtocolError)
    private enum CodingKeys: String, CodingKey { case type, snapshot, code, message, retryable }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "snapshot": self = .snapshot(try values.decode(RecordingSnapshot.self, forKey: .snapshot))
        case "progress": self = .progress(try values.decode(RecordingSnapshot.self, forKey: .snapshot))
        case "ack": self = .ack(try RecordingAck(from: decoder))
        case "error": self = .error(try RecordingProtocolError(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown recording server message.")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .ack(let receipt): try receipt.encode(to: encoder)
        case .snapshot(let snapshot), .progress(let snapshot):
            var values = encoder.container(keyedBy: CodingKeys.self)
            let type: String
            if case .snapshot = self { type = "snapshot" } else { type = "progress" }
            try values.encode(type, forKey: .type)
            try values.encode(snapshot, forKey: .snapshot)
        case .error(let error):
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode("error", forKey: .type)
            try values.encode(error.code, forKey: .code)
            try values.encode(error.message, forKey: .message)
            try values.encode(error.retryable, forKey: .retryable)
        }
    }
}

/// Standalone v2 codecs. Recording models do not depend on generated v1 wire adapters.
public enum RecordingWire {
    public static let webSocketProtocol = "sotto.recording.v1"
    public static let maximumPCMBytes = 1_048_576
    public static let maximumHeaderBytes = 16_384
    public static let maximumMessageBytes = 4 + maximumHeaderBytes + maximumPCMBytes
    public static let maximumInFlightBytes = 4 * maximumMessageBytes
    public static let maximumServerControlMessageBytes = 2 * 1_048_576
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try value.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let string = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid ISO8601 recording timestamp.")
        }
        return decoder
    }
    public static func encodeAudio(header: RecordingAudioHeader, pcm: Data) throws -> Data {
        try validate(header: header, pcmBytes: pcm.count)
        let json = try encoder().encode(header)
        guard json.count <= maximumHeaderBytes else { throw invalid("Audio JSON header exceeds its size limit.") }
        let length = UInt32(json.count)
        var data = Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        data.append(json)
        data.append(pcm)
        return data
    }
    public static func decodeAudio(_ data: Data) throws -> RecordingAudioMessage {
        guard data.count >= 4, data.count <= maximumMessageBytes else {
            throw invalid("Binary recording message is truncated or exceeds its size limit.")
        }
        let prefix = Array(data.prefix(4))
        let length = Int(UInt32(prefix[0]) << 24 | UInt32(prefix[1]) << 16 | UInt32(prefix[2]) << 8 | UInt32(prefix[3]))
        guard length > 0, length <= maximumHeaderBytes, length <= data.count - 4 else {
            throw invalid("Binary recording message has an invalid header length.")
        }
        let base = data.startIndex
        let json = data.subdata(in: (base + 4)..<(base + 4 + length))
        let header = try decoder().decode(RecordingAudioHeader.self, from: json)
        let pcm = data.subdata(in: (base + 4 + length)..<data.endIndex)
        try validate(header: header, pcmBytes: pcm.count)
        return RecordingAudioMessage(header: header, pcm: pcm)
    }
    private static func validate(header: RecordingAudioHeader, pcmBytes: Int) throws {
        let safeMaximum: Int64 = 9_007_199_254_740_991
        guard header.type == "audio", header.epoch > 0, Int64(header.epoch) <= safeMaximum,
              header.sequence >= 0, Int64(header.sequence) <= safeMaximum,
              header.firstFrame >= 0, header.firstFrame <= safeMaximum,
              header.frameCount > 0, header.frameCount <= safeMaximum - header.firstFrame,
              header.format.sampleRate >= 8_000, header.format.sampleRate <= 192_000,
              header.format.channels >= 1, header.format.channels <= 8,
              header.sha256.utf8.count == 64,
              header.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw invalid("Invalid audio header fields, format, counters, or SHA-256.")
        }
        if header.kind == .inference && (header.format.sampleRate != 16_000 || header.format.channels != 1) {
            throw invalid("Inference audio must be 16 kHz mono float32 PCM.")
        }
        let bytesPerFrame = Int64(header.format.channels * 4)
        guard header.frameCount <= Int64(maximumPCMBytes) / bytesPerFrame,
              pcmBytes == Int(header.frameCount * bytesPerFrame) else {
            throw invalid("PCM exceeds the message limit or does not match its declared frame count.")
        }
    }
    private static func invalid(_ message: String) -> RecordingProtocolError {
        RecordingProtocolError(code: "invalid_recording_message", message: message)
    }
}
