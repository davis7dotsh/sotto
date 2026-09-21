import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import SottoCore
import OSLog

/// Headerless little-endian float32 PCM, emitted on the serial writer queue.
/// Original channels are interleaved; normalized audio is 16 kHz mono.
struct CapturedAudioChunk: Sendable {
    enum Kind: Sendable { case normalized, original }

    let kind: Kind
    let data: Data
    let sampleRate: Double
    let channels: Int
}

struct CapturedAudio: Sendable {
    let url: URL
    let duration: TimeInterval
    /// Absolute sample peak, in the range 0...1 for normal microphone audio.
    let peak: Float
    /// Unmixed, unresampled PCM delivered by the selected input unit.
    let original: OriginalCapturedAudio?
    let spool: RecordingSpool?
    fileprivate let directory: URL

    init(url: URL, duration: TimeInterval, peak: Float, original: OriginalCapturedAudio?,
         spool: RecordingSpool? = nil, directory: URL) {
        self.url = url; self.duration = duration; self.peak = peak
        self.original = original; self.spool = spool; self.directory = directory
    }

    /// Persistent spools require explicit discard; temporary legacy WAVs are owned by the caller.
    func cleanup() {
        guard spool == nil else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Only this development client's generated capture names qualify.
    /// Other Sotto builds and server archives are untouched.
    static func cleanupOrphans(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            let isCapture = ["Sotto-Dev-recording-"].contains { prefix in
                name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
            }
            if isCapture { try? files.removeItem(at: entry) }
        }
    }
}

struct OriginalCapturedAudio: Sendable {
    let url: URL
    let sampleRate: Double
    let channelCount: UInt32
    let frameCount: Int64
    /// WAV storage uses the input unit's PCM precision in little-endian order.
    let encoding: String
}

enum AudioRecordingError: LocalizedError {
    case permissionRequired
    case alreadyRecording
    case notRecording
    case microphoneUnavailable
    case microphoneSelectionFailed(OSStatus)
    case conversionUnavailable
    case noAudio
    case cancelled
    case processing(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired: "Allow microphone access in System Settings first."
        case .alreadyRecording: "A recording is already in progress."
        case .notRecording: "There is no recording to finish."
        case .microphoneUnavailable: "The selected microphone is unavailable. Choose another input in Sotto."
        case .microphoneSelectionFailed(let status): "This microphone could not be opened (audio error \(status)). Choose another input in Sotto."
        case .conversionUnavailable: "This microphone's audio format could not be converted. Try another input device."
        case .noAudio: "The microphone did not provide any audio."
        case .cancelled: "The recording was cancelled."
        case .processing(let message): "Could not save microphone audio: \(message)"
        }
    }
}

/// Owns the hardware only between explicit start() and stop()/cancel() calls.
@MainActor
final class AudioRecorder {
    var onLevel: ((Float) -> Void)?
    var onInterruption: ((String) -> Void)?
    /// Captured at start(), so changing the callback cannot redirect an active take.
    /// Enqueue network work here; this callback must not block the audio writer.
    var onChunk: (@Sendable (CapturedAudioChunk) -> Void)?

    private let worker: AudioCaptureWorker
    private let microphoneAuthorized: () -> Bool
    private let sleepNotifications: NotificationCenter
    private var request: AudioCaptureRequest?
    private var sleepObserver: NSObjectProtocol?
    private var finishTask: Task<CapturedAudio, Error>?

    init(worker: AudioCaptureWorker? = nil,
         microphoneAuthorized: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
         sleepNotifications: NotificationCenter? = nil) {
        self.worker = worker ?? AudioCaptureWorker(makeHardware: { QueuedAudioHardware(queue: $0) })
        self.microphoneAuthorized = microphoneAuthorized
        self.sleepNotifications = sleepNotifications ?? NSWorkspace.shared.notificationCenter
    }

    func start(deviceID: AudioDeviceID? = nil, preserveOriginalAudio: Bool = false, spool: RecordingSpool? = nil) async throws {
        guard request == nil, finishTask == nil else { throw AudioRecordingError.alreadyRecording }
        guard microphoneAuthorized() else { throw AudioRecordingError.permissionRequired }
        guard !Task.isCancelled else { throw AudioRecordingError.cancelled }
        let current = AudioCaptureRequest(onChunk: onChunk, spool: spool)
        request = current
        sleepObserver = sleepNotifications.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interrupt(id: current.id, message: "Recording stopped because your Mac is going to sleep.")
            }
        }
        do {
            try await worker.start(
                request: current, deviceID: deviceID,
                preserveOriginalAudio: preserveOriginalAudio,
                onLevel: { [weak self] level in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.request?.id == current.id, current.acceptsAudio else { return }
                        self.onLevel?(level)
                    }
                },
                onInterruption: { [weak self] message in
                    DispatchQueue.main.async { [weak self] in
                        self?.interrupt(id: current.id, message: message)
                    }
                }
            )
            guard !Task.isCancelled else {
                worker.cancel(request: current)
                throw AudioRecordingError.cancelled
            }
        } catch {
            if let audioError = error as? InputAudioUnitError {
                Logger(subsystem: "dev.davis.murmur", category: "audio-capture")
                    .error("Capture startup failed: \(audioError.localizedDescription, privacy: .public)")
            }
            // A release can race a slow startup failure. Retain that request
            // until stop() consumes it, so a quick hold becomes noAudio rather
            // than accidentally stopping or publishing into a later take.
            if request?.id == current.id, !current.isReleased {
                request = nil
                removeSleepObserver()
                onLevel?(0)
            }
            throw error
        }
    }

    /// Call directly on key release, before scheduling the async stop task.
    /// No tap arriving after this gate closes may admit additional PCM.
    func stopAcceptingAudio() {
        request?.release()
        onLevel?(0)
    }

    func stop(pausing: Bool = false, interruption: String? = nil) async throws -> CapturedAudio {
        guard let current = request else { throw AudioRecordingError.notRecording }
        current.release()
        request = nil
        removeSleepObserver()
        onLevel?(0)
        let task = Task { try await worker.stop(request: current, pausing: pausing, interruption: interruption) }
        finishTask = task
        defer { finishTask = nil }
        return try await task.value
    }

    /// Used by orderly termination: drain the admitted writer prefix before exit.
    func preserve() async {
        stopAcceptingAudio()
        if let finishTask { _ = try? await finishTask.value }
        else { _ = try? await stop(pausing: request?.spool != nil, interruption: "Recording paused when Sotto closed.") }
    }

    func cancel() {
        let current = request
        current?.cancel()
        request = nil
        removeSleepObserver()
        onLevel?(0)
        if let current { worker.cancel(request: current) }
    }

    private func interrupt(id: UUID, message: String) {
        guard request?.id == id else { return }
        if let request, request.spool != nil {
            request.release()
            removeSleepObserver()
            onLevel?(0)
        } else {
            cancel()
        }
        onInterruption?(message)
    }

    private func removeSleepObserver() {
        if let sleepObserver { sleepNotifications.removeObserver(sleepObserver) }
        sleepObserver = nil
    }

    deinit {
        if let request { worker.cancel(request: request) }
        if let sleepObserver { sleepNotifications.removeObserver(sleepObserver) }
    }
}

/// Capture queue ownership is independent of the Mac's default output route.
private final class QueuedAudioHardware: AudioCaptureHardware, @unchecked Sendable {
    private let queue: DispatchQueue
    private var inputUnit: InputOnlyAudioUnit?
    private var writer: RecordingWriter?
    private var request: AudioCaptureRequest?
    private var onInterruption: (@Sendable (String) -> Void)?
    private var selectedDevice: AudioDeviceID?
    private var deviceObservers: [AudioDeviceObservation] = []
    private var watchdog: DispatchSourceTimer?

    init(queue: DispatchQueue) { self.queue = queue }

    func start(request: AudioCaptureRequest, deviceID: AudioDeviceID?, preserveOriginalAudio: Bool,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable (String) -> Void) throws {
        try request.requireOpen()
        guard inputUnit == nil else { throw AudioRecordingError.alreadyRecording }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRecordingError.permissionRequired
        }
        guard let selectedDevice = deviceID ?? AudioInputHardware.defaultInputID(),
              AudioInputHardware.isAvailable(selectedDevice) else { throw AudioRecordingError.microphoneUnavailable }
        self.request = request
        self.onInterruption = onInterruption
        self.selectedDevice = selectedDevice
        let inputUnit = InputOnlyAudioUnit()
        self.inputUnit = inputUnit
        let format = try inputUnit.prepare(deviceID: selectedDevice)
        try request.requireOpen()
        let id = request.id
        let writer = try RecordingWriter(
            inputFormat: format, preserveOriginalAudio: preserveOriginalAudio, onLevel: onLevel,
            onError: { [weak self] message in self?.enqueueInterruption(id: id, message: message) },
            onChunk: request.onChunk, spool: request.spool
        )
        self.writer = writer
        deviceObservers = [
            AudioDeviceObservation.observe(selectedDevice, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
            AudioDeviceObservation.observe(selectedDevice, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
            AudioDeviceObservation.observe(selectedDevice, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
            AudioDeviceObservation.observe(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
        ].compactMap { $0 }
        try inputUnit.start(request: request, onAudio: { buffer in writer.append(buffer) }, onError: { [weak self] status in
            self?.enqueueInterruption(id: id, message: InputAudioUnitError.driver("read input", status).localizedDescription)
        })
        guard AudioInputHardware.isAvailable(selectedDevice) else { throw AudioRecordingError.microphoneUnavailable }
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 3, repeating: 1)
        watchdog.setEventHandler { [weak self, weak writer] in
            guard let self, self.request?.id == id, self.request?.acceptsAudio == true,
                  let writer, writer.secondsSinceCallback > 3 else { return }
            self.interrupt(id: id, message: "The microphone stopped providing audio. Your saved recording has been preserved.")
        }
        self.watchdog = watchdog
        watchdog.resume()
    }

    func stop() -> RecordingWriter? {
        request?.release()
        let currentWriter = writer
        detachMicrophone()
        return currentWriter
    }

    func cancel() {
        request?.release()
        let currentWriter = writer
        detachMicrophone()
        currentWriter?.cancel()
    }

    private func enqueueRouteCheck(id: UUID) {
        queue.async { [weak self] in
            guard let self, self.request?.id == id, self.request?.acceptsAudio == true,
                  let selectedDevice = self.selectedDevice, let inputUnit = self.inputUnit else { return }
            do {
                guard AudioInputHardware.isAvailable(selectedDevice) else { throw InputAudioUnitError.routeChanged }
                try inputUnit.validateRoute(requireRunning: true)
            } catch {
                self.interrupt(id: id, message: error.localizedDescription)
            }
        }
    }

    private func enqueueInterruption(id: UUID, message: String) {
        queue.async { [weak self] in self?.interrupt(id: id, message: message) }
    }

    private func interrupt(id: UUID, message: String) {
        guard request?.id == id, request?.acceptsAudio == true else { return }
        Logger(subsystem: "dev.davis.murmur", category: "audio-capture")
            .error("Capture interrupted: \(message, privacy: .public)")
        let callback = onInterruption
        if request?.spool != nil {
            request?.release()
            deviceObservers.forEach { $0.cancel() }
            deviceObservers.removeAll()
            watchdog?.cancel()
            watchdog = nil
            inputUnit?.stop()
            inputUnit = nil
        } else {
            request?.cancel()
            cancel()
        }
        callback?(message)
    }

    private func detachMicrophone() {
        watchdog?.cancel()
        watchdog = nil
        deviceObservers.forEach { $0.cancel() }
        deviceObservers.removeAll()
        inputUnit?.stop()
        inputUnit = nil
        writer = nil
        request = nil
        selectedDevice = nil
        onInterruption = nil
    }

    deinit { cancel() }
}

/// Only the admission gate is shared between the audio callback and the caller.
/// Converter, file, counters, and errors are confined to the serial writer queue.
final class RecordingWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.sotto.audio-writer", qos: .userInitiated)
    private let admissionLock = NSLock()
    private let failureNotifications = DispatchQueue(label: "local.sotto.audio-writer-failure", qos: .userInitiated)
    private var failureNotificationSent = false
    private var accepting = true
    private var finishScheduled = false
    private var queuedBytes = 0
    private var queuedSourceFrames: Int64 = 0
    private var maximumObservedQueuedBytes = 0
    private var lastCallback = DispatchTime.now().uptimeNanoseconds
    /// Includes the buffer currently being converted, independent of network speed.
    static let maximumQueuedPCMBytes = 8 * 1_048_576
    private let spool: RecordingSpool?

    var peakQueuedPCMBytes: Int { admissionLock.withLock { maximumObservedQueuedBytes } }
    var secondsSinceCallback: Double {
        admissionLock.withLock { Double(DispatchTime.now().uptimeNanoseconds - lastCallback) / 1_000_000_000 }
    }

    private let directory: URL
    private let url: URL
    private let originalURL: URL?
    private let format: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let onLevel: (Float) -> Void
    private let onError: (String) -> Void
    private let onChunk: (@Sendable (CapturedAudioChunk) -> Void)?
    private var file: AVAudioFile?
    private var originalFile: AVAudioFile?
    private var failure: Error?
    private var frames: AVAudioFramePosition = 0
    private var inputFrames: AVAudioFramePosition = 0
    private var peak: Float = 0
    private var meter = AudioLevelMeter()
    private var meterSumSquares = 0.0
    private var meterFrames = 0
    private let meterWindowFrames = 800 // 50 ms at the WAV's 16 kHz sample rate.

    init(inputFormat: AVAudioFormat, preserveOriginalAudio: Bool = false,
         onLevel: @escaping (Float) -> Void, onError: @escaping (String) -> Void,
         onChunk: (@Sendable (CapturedAudioChunk) -> Void)? = nil, spool: RecordingSpool? = nil) throws {
        // InputOnlyAudioUnit negotiates float32 PCM. Keep non-streaming callers
        // free to archive other PCM formats, but never label their bytes float32.
        guard !preserveOriginalAudio || onChunk == nil || inputFormat.commonFormat == .pcmFormatFloat32 else {
            throw AudioRecordingError.conversionUnavailable
        }
        let conversionInput: AVAudioFormat
        if inputFormat.channelCount > 2 {
            guard inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved,
                  let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                                           channels: 1, interleaved: false) else {
                throw AudioRecordingError.conversionUnavailable
            }
            conversionInput = mono
        } else {
            conversionInput = inputFormat
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: conversionInput, to: format) else {
            throw AudioRecordingError.conversionUnavailable
        }
        self.format = format
        self.inputFormat = inputFormat
        self.converter = converter
        self.onLevel = onLevel
        self.onError = onError
        // Persistent transfer consumes committed spool batches; per-callback
        // notifications would expose the intentionally uncheckpointed tail.
        self.onChunk = spool == nil ? onChunk : nil
        self.spool = spool
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        directory = spool?.directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("Sotto-Dev-recording-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("microphone.wav")
        originalURL = preserveOriginalAudio && spool == nil ? directory.appendingPathComponent("original.wav") : nil
        if let spool {
            try spool.beginCapture(originalSampleRate: preserveOriginalAudio ? inputFormat.sampleRate : nil, originalChannels: preserveOriginalAudio ? Int(inputFormat.channelCount) : nil)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try queue.sync {
                file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                if let originalURL {
                    // WAV interleaves channels on disk, but no samples are mixed or
                    // resampled. AVAudioFile accepts the unit's original buffer layout.
                    var settings = inputFormat.settings
                    settings[AVLinearPCMIsNonInterleaved] = false
                    settings[AVLinearPCMIsBigEndianKey] = false
                    originalFile = try AVAudioFile(
                        forWriting: originalURL, settings: settings,
                        commonFormat: inputFormat.commonFormat, interleaved: inputFormat.isInterleaved
                    )
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalURL.path)
                }
            }
        } catch {
            file = nil
            originalFile = nil
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func append(_ source: AVAudioPCMBuffer) {
        guard source.frameLength > 0 else { return }
        let sourceFrameCount = Int64(source.frameLength)
        let byteCount = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
            .reduce(0) { $0 + Int($1.mDataByteSize) }
        // Reserve before allocating: a stalled writer cannot accumulate PCM copies.
        admissionLock.lock()
        guard accepting else { admissionLock.unlock(); return }
        lastCallback = DispatchTime.now().uptimeNanoseconds
        let queueLimit = spool == nil ? 48 * 1_048_576 : Self.maximumQueuedPCMBytes
        guard byteCount <= queueLimit - queuedBytes,
              spool == nil || queuedSourceFrames + sourceFrameCount <= Int64(source.format.sampleRate * 2) else {
            accepting = false
            let error = AudioRecordingError.processing("The audio writer could not keep up. The saved prefix has been preserved.")
            failureNotificationSent = true
            // Notification must not wait behind a stalled disk write. Hardware
            // admission closes promptly while the existing writer prefix drains.
            failureNotifications.async { [self] in onError(error.localizedDescription) }
            queue.async { [self] in fail(error, notify: false) }
            admissionLock.unlock()
            return
        }
        queuedBytes += byteCount
        queuedSourceFrames += sourceFrameCount
        maximumObservedQueuedBytes = max(maximumObservedQueuedBytes, queuedBytes)
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            queuedBytes -= byteCount
            queuedSourceFrames -= sourceFrameCount
            accepting = false
            failureNotificationSent = true
            failureNotifications.async { [self] in onError(AudioRecordingError.conversionUnavailable.localizedDescription) }
            queue.async { [self] in fail(AudioRecordingError.conversionUnavailable, notify: false) }
            admissionLock.unlock()
            return
        }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (sourceBuffer, destinationBuffer) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else { continue }
            memcpy(destinationData, sourceData, Int(min(sourceBuffer.mDataByteSize, destinationBuffer.mDataByteSize)))
        }
        queue.async { [self] in
            process(copy)
            admissionLock.withLock {
                queuedBytes -= byteCount
                queuedSourceFrames -= sourceFrameCount
            }
        }
        admissionLock.unlock()
    }

    /// A writer barrier used for deliberate checkpoints and deterministic tests.
    /// It never waits from the hardware callback.
    func checkpoint() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do { try spool?.checkpoint() } catch { fail(error) }
                continuation.resume()
            }
        }
    }

    func finish(pausing: Bool = false, interruption: String? = nil) async throws -> CapturedAudio {
        try await withCheckedThrowingContinuation { continuation in
            admissionLock.lock()
            guard !finishScheduled, accepting || spool != nil || failureNotificationSent else {
                admissionLock.unlock()
                continuation.resume(throwing: AudioRecordingError.cancelled)
                return
            }
            accepting = false
            finishScheduled = true
            queue.async { [self] in
                do {
                    if let failure, spool == nil { throw failure }
                    if failure == nil { try flushConverter() }
                    if pausing { try spool?.pauseCapture(interrupted: failure?.localizedDescription ?? interruption) }
                    else { try spool?.seal(interrupted: failure?.localizedDescription ?? interruption) }
                    guard frames > 0 else { throw AudioRecordingError.noAudio }
                    file = nil // Close and finalize the WAV header before handing it off.
                    originalFile = nil
                    let original = originalURL.map {
                        let descriptor = inputFormat.streamDescription.pointee
                        let precision = descriptor.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "f" : "s"
                        return OriginalCapturedAudio(
                            url: $0, sampleRate: inputFormat.sampleRate,
                            channelCount: inputFormat.channelCount, frameCount: inputFrames,
                            encoding: "pcm_\(precision)\(descriptor.mBitsPerChannel)le"
                        )
                    }
                    continuation.resume(returning: CapturedAudio(
                        url: url, duration: Double(spool?.finalManifest.last?.inferenceFrames ?? frames) / format.sampleRate, peak: peak,
                        original: original, spool: spool, directory: directory
                    ))
                } catch {
                    if let spool { try? spool.pauseCapture(interrupted: error.localizedDescription) }
                    discardFile()
                    continuation.resume(throwing: error)
                }
            }
            admissionLock.unlock()
        }
    }

    func cancel() {
        admissionLock.lock()
        if !finishScheduled {
            accepting = false
            finishScheduled = true
            queue.async { [self] in
                if let spool {
                    if failure == nil { try? flushConverter() }
                    try? spool.pauseCapture(interrupted: "Recording interrupted before completion.")
                }
                discardFile()
            }
        }
        admissionLock.unlock()
    }

    private func process(_ input: AVAudioPCMBuffer) {
        guard failure == nil else { return }
        guard input.format == inputFormat else {
            fail(AudioRecordingError.microphoneUnavailable)
            return
        }
        // Bound both files to the same admitted input interval. This also avoids
        // converting late driver buffers after the three-minute cap is reached.
        if spool == nil {
            let remainingInputFrames = AVAudioFramePosition(input.format.sampleRate * 180) - inputFrames
            guard remainingInputFrames > 0 else { return }
            input.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(input.frameLength), remainingInputFrames))
        }
        do {
            try originalFile?.write(from: input)
            if originalFile != nil || spool?.preservesOriginalAudio == true { try emitOriginal(input) }
            inputFrames += AVAudioFramePosition(input.frameLength)
        } catch {
            fail(error)
            return
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            fail(AudioRecordingError.conversionUnavailable)
            return
        }
        // AVAudioConverter's speaker downmix produces silence for discrete
        // interface layouts. Mix every input equally before resampling, while
        // retaining the untouched channels in the original recording.
        let conversionBuffer: AVAudioPCMBuffer
        if input.format.channelCount > 2 {
            guard let mono = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: input.frameLength),
                  let source = input.floatChannelData, let destination = mono.floatChannelData else {
                fail(AudioRecordingError.conversionUnavailable)
                return
            }
            mono.frameLength = input.frameLength
            let count = Int(input.format.channelCount)
            for frame in 0..<Int(input.frameLength) {
                var sample: Float = 0
                for channel in 0..<count { sample += source[channel][frame] / Float(count) }
                destination[0][frame] = sample
            }
            conversionBuffer = mono
        } else {
            conversionBuffer = input
        }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return conversionBuffer
        }
        if status == .error {
            fail(conversionError ?? AudioRecordingError.conversionUnavailable as NSError)
            return
        }
        do {
            try write(output)
        } catch {
            fail(error)
        }
    }

    private func flushConverter() throws {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw AudioRecordingError.conversionUnavailable
        }
        // A bounded flush avoids hanging shutdown on a malfunctioning converter.
        for _ in 0..<8 {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error { throw conversionError ?? AudioRecordingError.conversionUnavailable as NSError }
            try write(output)
            if status == .endOfStream || status == .inputRanDry || output.frameLength == 0 { return }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { return }
        // The controller stops the microphone at 180 seconds, but its timer can
        // run one callback late. Keep the WAV within the helper's strict limit.
        if spool == nil {
            let remainingFrames = AVAudioFramePosition(format.sampleRate * 180) - frames
            guard remainingFrames > 0 else { return }
            buffer.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameLength), remainingFrames))
        }
        try file?.write(from: buffer)
        let chunk = CapturedAudioChunk(
            kind: .normalized,
            data: Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Float>.size),
            sampleRate: format.sampleRate, channels: 1
        )
        try spool?.append(chunk)
        onChunk?(chunk)
        for index in 0..<Int(buffer.frameLength) {
            let sample = samples[index]
            let magnitude = sample.isFinite ? abs(sample) : 0
            peak = max(peak, magnitude)
            // Sanitize only the measurement; the PCM written above is untouched.
            let measured = Double(min(1, magnitude))
            meterSumSquares += measured * measured
            meterFrames += 1
            if meterFrames == meterWindowFrames {
                let rms = sqrt(meterSumSquares / Double(meterFrames))
                onLevel(meter.update(rms: rms, frameCount: meterFrames, sampleRate: format.sampleRate))
                meterSumSquares = 0
                meterFrames = 0
            }
        }
        frames += AVAudioFramePosition(buffer.frameLength)
    }

    private func emitOriginal(_ buffer: AVAudioPCMBuffer) throws {
        guard spool != nil || onChunk != nil else { return }
        guard let samples = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let data: Data
        if buffer.format.isInterleaved || channels == 1 {
            data = Data(bytes: samples[0], count: frameCount * channels * MemoryLayout<Float>.size)
        } else {
            // The input unit supplies planar buffers. The HTTP format is packed
            // frame-by-frame, preserving every original channel sample.
            var interleaved = [Float](repeating: 0, count: frameCount * channels)
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    interleaved[frame * channels + channel] = samples[channel][frame]
                }
            }
            data = interleaved.withUnsafeBytes { Data($0) }
        }
        let chunk = CapturedAudioChunk(kind: .original, data: data, sampleRate: buffer.format.sampleRate, channels: channels)
        try spool?.append(chunk)
        onChunk?(chunk)
    }

    private func fail(_ error: Error, notify: Bool = true) {
        guard failure == nil else { return }
        failure = error
        let shouldNotify = admissionLock.withLock {
            accepting = false
            let shouldNotify = notify && !failureNotificationSent
            failureNotificationSent = true
            return shouldNotify
        }
        if shouldNotify { onError(error.localizedDescription) }
    }

    private func discardFile() {
        file = nil
        originalFile = nil
        if spool == nil { try? FileManager.default.removeItem(at: directory) }
    }
}
