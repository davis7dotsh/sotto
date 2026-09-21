import CryptoKit
import Darwin
import Foundation
import SottoAPI

struct RecordingSpoolBatch: Sendable {
    var header: RecordingAudioHeader
    let data: Data
}

/// Persistent, privately owned PCM. A batch is published only after both its
/// sealed file and the small stream checkpoint have been synced. No growing WAV
/// header or in-memory queue is necessary to recover an acknowledged prefix.
final class RecordingSpool: @unchecked Sendable {
    struct CaptureRun: Codable, Sendable {
        let id: UUID
        let startedAt: Date
        var endedAt: Date?
        var originalFormat: AudioStreamFormat?
        var gapBeforeMilliseconds: Int64?
        var interruption: String?
    }

    private struct Manifest: Codable {
        var version = 1
        var snapshot: RecordingSessionSnapshot
        let endpoint: URL
        let deviceIdentity: String
        var runs: [CaptureRun] = []
        var sealed = false
        var paused: Bool? = false
        var interruption: String?
        var deliveryAttempted = false
        var continuationID: UUID?
        var contextReady: Bool? = false
    }

    enum SpoolError: LocalizedError {
        case invalid(String)
        case storage(Int32)
        var errorDescription: String? {
            switch self {
            case .invalid(let message): message
            case .storage(let code): "Recording storage failed: \(String(cString: strerror(code))). The saved prefix is retained."
            }
        }
    }

    let directory: URL
    private let lock = NSRecursiveLock()
    private var manifest: Manifest
    private var streams: [RecordingStreamCheckpoint] = []
    private var stagedStreams: [RecordingStreamCheckpoint] = []
    private var discarded = false
    private var pending: [String: Data] = [:]
    /// Only this active tail can be absent after an abrupt process/power loss.
    static let maximumUncheckpointedSeconds = 0.25
    private static let envelopeHeaderLimit = 16_384

    var continuationID: UUID? { lock.withLock { manifest.continuationID } }
    var contextReady: Bool { lock.withLock { manifest.contextReady == true } }
    var snapshot: RecordingSessionSnapshot { lock.withLock { manifest.snapshot } }
    var endpoint: URL { lock.withLock { manifest.endpoint } }
    var deviceIdentity: String { lock.withLock { manifest.deviceIdentity } }
    var isSealed: Bool { lock.withLock { manifest.sealed } }
    var isPaused: Bool { lock.withLock { manifest.paused == true } }
    var runTimings: [RecordingRunTiming] {
        lock.withLock {
            manifest.runs.map { RecordingRunTiming(runID: $0.id, startedAt: $0.startedAt, endedAt: $0.endedAt,
                                                  gapBeforeMilliseconds: $0.gapBeforeMilliseconds) }
        }
    }
    var deliveryAttempted: Bool { lock.withLock { manifest.deliveryAttempted } }
    var interruption: String? { lock.withLock { manifest.interruption } }
    var checkpoints: [RecordingStreamCheckpoint] { lock.withLock { streams } }
    var preservesOriginalAudio: Bool { lock.withLock { manifest.runs.last?.originalFormat != nil } }
    var finalManifest: [RecordingRunEndpoint] {
        lock.withLock {
            manifest.runs.map { run in
                let inference = streams.first { $0.runID == run.id && $0.kind == .inference }
                let original = streams.first { $0.runID == run.id && $0.kind == .original }
                return RecordingRunEndpoint(runID: run.id, inferenceFrames: inference?.frameCount ?? 0,
                                            originalFrames: run.originalFormat == nil ? nil : original?.frameCount ?? 0)
            }
        }
    }

    init(directory: URL, snapshot: RecordingSessionSnapshot, endpoint: URL, deviceIdentity: String) throws {
        guard endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            throw SpoolError.invalid("The recording endpoint cannot contain credentials or query parameters.")
        }
        self.directory = directory
        manifest = Manifest(snapshot: snapshot, endpoint: endpoint, deviceIdentity: deviceIdentity)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw SpoolError.invalid("This local recording already exists.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try saveManifest()
        let recordingsRoot = directory.deletingLastPathComponent()
        try Self.syncDirectory(recordingsRoot)
        // createDirectory may have created Recordings itself. Sync its entry in
        // the existing client data directory before admitting microphone audio.
        try Self.syncDirectory(recordingsRoot.deletingLastPathComponent())
    }

    private init(recovering directory: URL) throws {
        self.directory = directory
        manifest = try RecordingWire.decoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.version == 1 else { throw SpoolError.invalid("Unsupported local recording version.") }
        for run in manifest.runs {
            let runCheckpointURL = directory.appendingPathComponent(run.id.uuidString).appendingPathComponent("capture-checkpoint.json")
            let committedRun: [RecordingStreamCheckpoint]?
            if FileManager.default.fileExists(atPath: runCheckpointURL.path) {
                committedRun = try SottoAPI.decoder().decode([RecordingStreamCheckpoint].self, from: Data(contentsOf: runCheckpointURL))
            } else { committedRun = nil }
            for kind in [AudioKind.inference, .original] {
                let streamDirectory = streamDirectory(runID: run.id, kind: kind)
                guard FileManager.default.fileExists(atPath: streamDirectory.path) else { continue }
                let checkpoint: RecordingStreamCheckpoint
                if let committedRun {
                    guard let saved = committedRun.first(where: { $0.kind == kind }) else { throw SpoolError.invalid("The paired capture checkpoint is incomplete.") }
                    checkpoint = saved
                } else {
                    checkpoint = try SottoAPI.decoder().decode(RecordingStreamCheckpoint.self, from: Data(contentsOf: streamDirectory.appendingPathComponent("checkpoint.json")))
                }
                guard checkpoint.runID == run.id, checkpoint.kind == kind,
                      checkpoint.nextSequence >= 0, checkpoint.frameCount >= 0 else {
                    throw SpoolError.invalid("The saved recording checkpoint is invalid.")
                }
                streams.append(checkpoint)
                // A crash after batch sync but before checkpoint publication may
                // leave a suffix. It was never reported as durably captured.
                guard let files = FileManager.default.enumerator(at: streamDirectory, includingPropertiesForKeys: nil,
                                                                  options: [.skipsSubdirectoryDescendants]) else {
                    throw SpoolError.invalid("The saved audio directory could not be read.")
                }
                for case let file as URL in files {
                    if file.pathExtension == "batch", let sequence = Int(file.deletingPathExtension().lastPathComponent), sequence >= checkpoint.nextSequence {
                        try FileManager.default.removeItem(at: file)
                    } else if file.lastPathComponent.hasPrefix(".pending-") {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            }
        }
        stagedStreams = streams
        if manifest.contextReady != true {
            manifest.continuationID = nil
            manifest.contextReady = true
            // A full disk must not hide an otherwise readable committed prefix.
            // The uploader/UI can retry persistence once storage is available.
            try? saveManifest()
        }
        if !manifest.sealed, manifest.paused != true {
            let message = "Recording interrupted when Sotto closed. The saved prefix is ready to recover."
            do { try pauseCapture(interrupted: message) }
            catch {
                manifest.paused = true
                if !manifest.runs.isEmpty { manifest.runs[manifest.runs.count - 1].endedAt = Date() }
                manifest.interruption = "\(message) Local checkpoint persistence failed: \(error.localizedDescription)"
            }
        }
    }

    /// Discovery does not delete undecodable recordings. They remain available
    /// on disk for diagnosis/recovery rather than becoming disposable orphans.
    static func recover(in root: URL, excluding sessionIDs: Set<UUID> = []) -> [RecordingSpool] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return entries.compactMap { directory in
            if let id = UUID(uuidString: directory.lastPathComponent), sessionIDs.contains(id) { return nil }
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return try? RecordingSpool(recovering: directory)
        }
    }

    func beginCapture(originalSampleRate: Double?, originalChannels: Int?) throws {
        try lock.withLock {
            guard !manifest.sealed, !discarded, manifest.runs.last?.endedAt != nil || manifest.runs.isEmpty else {
                throw SpoolError.invalid("This local recording cannot admit another capture run.")
            }
            let original: AudioStreamFormat?
            if let originalSampleRate, let originalChannels {
                guard originalSampleRate.isFinite, originalSampleRate.rounded() == originalSampleRate,
                      (8_000...192_000).contains(originalSampleRate), (1...8).contains(originalChannels) else {
                    throw SpoolError.invalid("Original audio requires a supported sample rate and channel count.")
                }
                original = AudioStreamFormat(sampleRate: Int(originalSampleRate), channels: originalChannels)
            } else { original = nil }
            let startedAt = Date()
            let gap: Int64?
            if let endedAt = manifest.runs.last?.endedAt {
                let milliseconds = startedAt.timeIntervalSince(endedAt) * 1_000
                gap = milliseconds >= 0 && milliseconds < Double(Int64.max) ? Int64(milliseconds) : nil
            } else { gap = nil }
            let run = CaptureRun(id: UUID(), startedAt: startedAt, originalFormat: original, gapBeforeMilliseconds: gap)
            var additions = [RecordingStreamCheckpoint(runID: run.id, kind: .inference,
                                                       format: .init(sampleRate: 16_000, channels: 1), nextSequence: 0, frameCount: 0)]
            if let original { additions.append(.init(runID: run.id, kind: .original, format: original, nextSequence: 0, frameCount: 0)) }
            for checkpoint in additions {
                let directory = streamDirectory(runID: run.id, kind: checkpoint.kind)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Self.durableWrite(SottoAPI.encoder().encode(checkpoint), to: directory.appendingPathComponent("checkpoint.json"))
            }
            try Self.durableWrite(SottoAPI.encoder().encode(additions), to: self.directory.appendingPathComponent(run.id.uuidString).appendingPathComponent("capture-checkpoint.json"))
            try Self.syncDirectory(self.directory.appendingPathComponent(run.id.uuidString))
            try Self.syncDirectory(self.directory)
            let previous = manifest
            manifest.runs.append(run)
            manifest.paused = false
            manifest.interruption = nil
            do { try saveManifest() } catch { manifest = previous; throw error }
            streams.append(contentsOf: additions)
            stagedStreams.append(contentsOf: additions)
        }
    }

    /// Runs only on the writer queue. The real-time callback never touches disk.
    /// Transport reads only batches below the durably committed checkpoint.
    func append(_ chunk: CapturedAudioChunk) throws {
        try lock.withLock {
            guard !manifest.sealed, !discarded, let run = manifest.runs.last, run.endedAt == nil else { throw SpoolError.invalid("The recording is closed.") }
            let kind: AudioKind = chunk.kind == .normalized ? .inference : .original
            guard let index = streams.firstIndex(where: { $0.runID == run.id && $0.kind == kind }) else {
                throw SpoolError.invalid("This audio stream was not admitted.")
            }
            let checkpoint = streams[index]
            guard chunk.sampleRate == Double(checkpoint.format.sampleRate), chunk.channels == checkpoint.format.channels,
                  !chunk.data.isEmpty, chunk.data.count % (chunk.channels * 4) == 0 else {
                throw SpoolError.invalid("Audio does not match the admitted stream format.")
            }
            // Coalesce independently from hardware callbacks. This bounds both
            // file/fsync frequency and ACK-gated transport overhead.
            let key = streamKey(checkpoint)
            var buffer = pending[key] ?? Data()
            var offset = 0
            while offset < chunk.data.count {
                let targetBytes = nextSegmentBytes(streamIndex: index)
                let count = min(targetBytes - buffer.count, chunk.data.count - offset)
                buffer.append(chunk.data.subdata(in: offset..<(offset + count)))
                offset += count
                pending[key] = buffer
                if buffer.count == targetBytes {
                    try stageBuffer(buffer, streamIndex: index, key: key)
                    buffer = Data()
                    try publishPairedCheckpoint(runID: checkpoint.runID)
                }
            }

        }
    }

    private func nextSegmentBytes(streamIndex: Int) -> Int {
        let stream = stagedStreams[streamIndex]
        let framesPerSegment = Double(stream.format.sampleRate) * Self.maximumUncheckpointedSeconds
        let segment = floor(Double(stream.frameCount) / framesPerSegment)
        let nextBoundary = Int64(ceil((segment + 1) * framesPerSegment))
        return Int(max(1, nextBoundary - stream.frameCount)) * stream.format.channels * 4
    }

    /// Storage cadence follows absolute sample-clock quarter boundaries, even
    /// for rates not divisible by four. Large original segments split into wire
    /// messages without shifting that cadence or publishing a partial segment.
    private func stageBuffer(_ data: Data, streamIndex: Int, key: String) throws {
        let frameSize = stagedStreams[streamIndex].format.channels * 4
        let maximumBytes = RecordingWire.maximumPCMBytes / frameSize * frameSize
        var remainder = data
        while !remainder.isEmpty {
            let count = min(maximumBytes, remainder.count)
            let packet = remainder.subdata(in: remainder.startIndex..<(remainder.startIndex + count))
            try appendPayload(packet, streamIndex: streamIndex)
            remainder = Data(remainder.dropFirst(count))
            // On a later storage failure the already staged portion is never
            // written twice when pause/checkpoint retries the remaining tail.
            pending[key] = remainder
        }
    }

    private func appendPayload(_ payload: Data, streamIndex: Int) throws {
        guard payload.withUnsafeBytes({ bytes in
            stride(from: 0, to: bytes.count, by: 4).allSatisfy {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))).isFinite
            }
        }) else { throw SpoolError.invalid("The microphone produced non-finite audio. The saved prefix is retained.") }
        let free = try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber
        guard let free, free.int64Value >= Int64(payload.count) + 16 * 1_048_576 else {
            throw SpoolError.invalid("Recording stopped because local storage is nearly full. The saved prefix is retained.")
        }
        let old = stagedStreams[streamIndex]
        let frameCount = Int64(payload.count / (old.format.channels * 4))
        let header = RecordingAudioHeader(epoch: 0, runID: old.runID, kind: old.kind, sequence: old.nextSequence,
                                          firstFrame: old.frameCount, format: old.format, frameCount: frameCount,
                                          sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        let json = try SottoAPI.encoder().encode(header)
        var headerLength = UInt32(json.count).bigEndian
        var envelope = withUnsafeBytes(of: &headerLength) { Data($0) }
        envelope.append(json)
        envelope.append(payload)
        let batchURL = batchURL(runID: old.runID, kind: old.kind, sequence: old.nextSequence)
        try Self.durableWrite(envelope, to: batchURL)
        var committed = old
        committed.nextSequence += 1
        committed.frameCount += frameCount
        stagedStreams[streamIndex] = committed
    }

    /// Independent file syncs do not imply independently publishable intervals.
    /// A single atomic checkpoint fences both streams: a crash during conversion
    /// cannot strand an acknowledged source prefix without matching inference.
    private func publishPairedCheckpoint(runID: UUID) throws {
        let run = stagedStreams.filter { $0.runID == runID }
        guard let inference = run.first(where: { $0.kind == .inference }) else { return }
        if let original = run.first(where: { $0.kind == .original }) {
            let sourceDuration = Double(original.frameCount) / Double(original.format.sampleRate)
            let inferenceDuration = Double(inference.frameCount) / 16_000
            // Allow only the converter's short buffered tail. Acoustic/transport
            // batch sizes never justify publishing a whole source buffer ahead.
            guard abs(sourceDuration - inferenceDuration) <= 0.025 else { return }
        }
        let url = directory.appendingPathComponent(runID.uuidString).appendingPathComponent("capture-checkpoint.json")
        try Self.durableWrite(SottoAPI.encoder().encode(run), to: url)
        for index in streams.indices where streams[index].runID == runID { streams[index] = stagedStreams[index] }
    }

    func nextBatch(after positions: [RecordingStreamCheckpoint], maxBytes: Int = RecordingWire.maximumPCMBytes, runIDs: Set<UUID>? = nil) throws -> RecordingSpoolBatch? {
        try lock.withLock {
            guard !discarded else { return nil }
            // Inference has priority; original PCM cannot starve speech progress.
            for kind in [AudioKind.inference, .original] {
                for stream in streams where stream.kind == kind && (runIDs?.contains(stream.runID) ?? true) {
                    let position = positions.first { $0.runID == stream.runID && $0.kind == kind }
                    let nextSequence = position?.nextSequence ?? 0
                    if let position {
                        guard position.format == stream.format, position.frameCount >= 0,
                              position.frameCount <= stream.frameCount,
                              nextSequence != stream.nextSequence || position.frameCount == stream.frameCount else {
                            throw SpoolError.invalid("The server audio checkpoint does not match the saved recording.")
                        }
                    }
                    guard nextSequence >= 0, nextSequence <= stream.nextSequence else {
                        throw SpoolError.invalid("The server audio position exceeds the saved recording.")
                    }
                    guard nextSequence < stream.nextSequence else { continue }
                    let url = batchURL(runID: stream.runID, kind: kind, sequence: nextSequence)
                    let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard fileSize <= RecordingWire.maximumMessageBytes else { throw SpoolError.invalid("The saved audio file exceeds its batch limit.") }
                    let envelope = try Data(contentsOf: url)
                    guard envelope.count >= 4 else { throw SpoolError.invalid("The saved audio batch is incomplete.") }
                    let headerLength = envelope.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                    guard headerLength > 0, headerLength <= Self.envelopeHeaderLimit, 4 + headerLength <= envelope.count else {
                        throw SpoolError.invalid("The saved audio header is invalid.")
                    }
                    let header = try SottoAPI.decoder().decode(RecordingAudioHeader.self, from: envelope.subdata(in: 4..<(4 + headerLength)))
                    let payload = envelope.subdata(in: (4 + headerLength)..<envelope.count)
                    guard payload.count <= maxBytes, header.runID == stream.runID, header.kind == kind,
                          header.sequence == nextSequence, header.format == stream.format,
                          header.firstFrame == (position?.frameCount ?? 0), header.frameCount > 0,
                          header.frameCount <= Int64(RecordingWire.maximumPCMBytes / (stream.format.channels * 4)),
                          header.frameCount * Int64(stream.format.channels * 4) == Int64(payload.count),
                          header.sha256 == SHA256.hash(data: payload).map({ String(format: "%02x", $0) }).joined() else {
                        throw SpoolError.invalid("The saved audio batch failed validation.")
                    }
                    return RecordingSpoolBatch(header: header, data: payload)
                }
            }
            return nil
        }
    }

    /// Explicit durable barrier. Normal capture commits on the bounded cadence;
    /// shutdown and tests can flush the shorter tail without waiting for a timer.
    func checkpoint() throws {
        try lock.withLock {
            for index in streams.indices {
                let key = streamKey(streams[index])
                guard let buffer = pending[key], !buffer.isEmpty else { continue }
                try stageBuffer(buffer, streamIndex: index, key: key)
                try publishPairedCheckpoint(runID: streams[index].runID)
            }
            // A prior publication failure does not mean its already synced PCM
            // must be staged twice. Retrying the checkpoint publishes that data.
            for run in manifest.runs { try publishPairedCheckpoint(runID: run.id) }
        }
    }

    private func streamKey(_ stream: RecordingStreamCheckpoint) -> String {
        "\(stream.runID.uuidString)/\(stream.kind.rawValue)"
    }

    /// A closed capture run stays part of the same admitted logical recording.
    /// Its exact prefix is durable before the transport reports the interruption.
    func pauseCapture(interrupted: String? = nil) throws {
        try lock.withLock {
            guard !discarded, !manifest.sealed else { return }
            try checkpoint()
            let previous = manifest
            manifest.paused = true
            manifest.interruption = interrupted
            if !manifest.runs.isEmpty {
                let last = manifest.runs.count - 1
                if manifest.runs[last].endedAt == nil { manifest.runs[last].endedAt = Date() }
                if let interrupted { manifest.runs[last].interruption = interrupted }
            }
            do { try saveManifest() } catch { manifest = previous; throw error }
        }
    }

    func prepareToResume() throws {
        try lock.withLock {
            guard !discarded, !manifest.sealed, manifest.paused == true else {
                throw SpoolError.invalid("This recording is not available to resume.")
            }
            let previous = manifest
            manifest.paused = false
            do { try saveManifest() } catch { manifest = previous; throw error }
        }
    }

    func seal(interrupted: String? = nil) throws {
        try lock.withLock {
            guard !discarded else { return }
            if manifest.sealed {
                if let interrupted, manifest.interruption != interrupted {
                    manifest.interruption = interrupted
                    try saveManifest()
                }
                return
            }
            try checkpoint()
            let previous = manifest
            manifest.sealed = true
            manifest.paused = false
            manifest.interruption = interrupted
            if !manifest.runs.isEmpty, manifest.runs[manifest.runs.count - 1].endedAt == nil {
                manifest.runs[manifest.runs.count - 1].endedAt = Date()
            }
            do { try saveManifest() } catch { manifest = previous; throw error }
        }
    }

    /// This barrier is persisted before the uploader sends its first PCM batch.
    /// Nil is a deliberate request to begin a fresh composition context.
    func setContinuationID(_ id: UUID?) throws {
        try lock.withLock {
            guard !discarded else { throw SpoolError.invalid("This recording was discarded.") }
            if manifest.contextReady == true {
                guard manifest.continuationID == id else { throw SpoolError.invalid("This recording's composition context is already fixed.") }
                return
            }
            let previous = manifest
            manifest.continuationID = id
            manifest.contextReady = true
            do { try saveManifest() } catch { manifest = previous; throw error }
        }
    }

    func markSnapshot(_ snapshot: RecordingSessionSnapshot) throws {
        try lock.withLock {
            guard snapshot.id == manifest.snapshot.id, snapshot.settings == manifest.snapshot.settings, !discarded else { throw SpoolError.invalid("A different server recording cannot replace this session.") }
            // Admission settings are immutable. Do not let a later server settings
            // change silently alter the captured session's accepted preferences.
            let previous = manifest.snapshot
            manifest.snapshot = snapshot
            do { try saveManifest() } catch { manifest.snapshot = previous; throw error }
        }
    }

    /// Persist before invoking paste. Recovery never repeats an ambiguous paste.
    func markDeliveryAttempted() throws {
        try lock.withLock {
            guard !discarded else { throw SpoolError.invalid("This recording was discarded.") }
            manifest.deliveryAttempted = true
            try saveManifest()
        }
    }

    /// Deletion is explicit, and serialized against pending writer operations.
    func discard() throws {
        try lock.withLock {
            discarded = true
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func streamDirectory(runID: UUID, kind: AudioKind) -> URL {
        directory.appendingPathComponent(runID.uuidString, isDirectory: true).appendingPathComponent(kind.rawValue, isDirectory: true)
    }
    private func batchURL(runID: UUID, kind: AudioKind, sequence: Int) -> URL {
        streamDirectory(runID: runID, kind: kind).appendingPathComponent("\(sequence).batch")
    }
    private func saveManifest() throws {
        try Self.durableWrite(RecordingWire.encoder().encode(manifest), to: directory.appendingPathComponent("manifest.json"))
    }

    private static func durableWrite(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".pending-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SpoolError.storage(errno) }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SpoolError.storage(errno) }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw SpoolError.storage(errno) }
        guard rename(temporary.path, url.path) == 0 else { throw SpoolError.storage(errno) }
        try syncDirectory(parent)
    }

    private static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw SpoolError.storage(errno) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw SpoolError.storage(errno) }
    }
}
