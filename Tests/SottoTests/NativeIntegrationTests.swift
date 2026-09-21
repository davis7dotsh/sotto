import AppKit
import Combine
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreGraphics
import SottoCore
import SwiftUI
import XCTest
@testable import Sotto

final class NativeIntegrationTests: XCTestCase {
    @MainActor
    func testHiddenRecordingNoticeRemovesExtraWindowAreaWithoutMovingHUDContent() {
        let expanded = NSRect(x: 200, y: 100, width: DictationPanelLayout.contentSize.width,
                              height: DictationPanelLayout.contentSize.height)
        let collapsed = DictationPanelLayout.windowFrame(from: expanded, showsNotice: false)
        XCTAssertEqual(collapsed.maxY, expanded.maxY)
        XCTAssertEqual(collapsed.width, expanded.width)
        XCTAssertEqual(collapsed.minY - expanded.minY, DictationHUD.noticeHeight)

        let extraArea = NSPoint(x: expanded.midX, y: expanded.minY + DictationHUD.noticeHeight / 2)
        XCTAssertTrue(expanded.contains(extraArea))
        XCTAssertFalse(collapsed.contains(extraArea), "The hidden notice must not reserve a native mouse hit area")

        let expandedContent = DictationPanelLayout.contentFrame(in: expanded.size)
            .offsetBy(dx: expanded.minX, dy: expanded.minY)
        let collapsedContent = DictationPanelLayout.contentFrame(in: collapsed.size)
            .offsetBy(dx: collapsed.minX, dy: collapsed.minY)
        XCTAssertEqual(collapsedContent, expandedContent, "Resizing must not re-center the SwiftUI capsule")
        XCTAssertEqual(DictationPanelLayout.windowFrame(from: collapsed, showsNotice: true), expanded)
    }

    @MainActor
    func testCompactHUDReleasesSideHitAreasWithoutMovingItsCenterOrNotice() {
        let expanded = NSRect(x: 200, y: 100, width: DictationPanelLayout.contentSize.width,
                              height: DictationHUD.height + 36)
        let compact = DictationPanelLayout.windowFrame(from: expanded, showsNotice: false, compact: true)
        XCTAssertEqual(compact.midX, expanded.midX)
        XCTAssertEqual(compact.maxY, expanded.maxY)
        XCTAssertFalse(compact.contains(NSPoint(x: expanded.minX + 1, y: expanded.midY)))
        let expandedContent = DictationPanelLayout.contentFrame(in: expanded.size)
            .offsetBy(dx: expanded.minX, dy: expanded.minY)
        let compactContent = DictationPanelLayout.contentFrame(in: compact.size)
            .offsetBy(dx: compact.minX, dy: compact.minY)
        XCTAssertEqual(compactContent, expandedContent)
        let notice = DictationPanelLayout.windowFrame(from: compact, showsNotice: true, compact: true)
        XCTAssertEqual(notice.width, expanded.width, "The recording-limit note must keep its full text width")
        XCTAssertEqual(notice.midX, expanded.midX)
        XCTAssertEqual(notice.maxY, expanded.maxY)
        XCTAssertEqual(DictationPanelLayout.windowFrame(from: compact, showsNotice: false), expanded)
    }

    @MainActor
    func testHUDDistinguishesClipboardFallbackAndUncertainDelivery() {
        XCTAssertNotEqual(DictationDeliveryStatus.inserted.hudSymbol, DictationDeliveryStatus.copied.hudSymbol)
        for status in [DictationDeliveryStatus.failed, .unconfirmed, .none] {
            XCTAssertNotEqual(status.hudSymbol, DictationDeliveryStatus.inserted.hudSymbol)
        }
        XCTAssertTrue(DictationDeliveryStatus.unconfirmed.needsAttention)
        XCTAssertTrue(DictationDeliveryStatus.failed.needsAttention)
        for status in [DictationDeliveryStatus.none, .inserted, .copied, .tested, .listUpdated, .unconfirmed, .failed] {
            XCTAssertNotNil(NSImage(systemSymbolName: status.hudSymbol, accessibilityDescription: status.hudLabel))
        }
    }

    @MainActor
    func testGlacierTextRemainsLegibleOnReadingAndOpaqueFallbackSurfaces() throws {
        let app = NSApplication.shared
        let previousAppearance = app.appearance
        defer { app.appearance = previousAppearance }

        func luminance(_ color: NSColor) -> CGFloat {
            zip([color.redComponent, color.greenComponent, color.blueComponent], [0.2126, 0.7152, 0.0722])
                .reduce(0) { result, pair in
                    let (channel, weight) = pair
                    let linear = channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
                    return result + linear * weight
                }
        }
        for appearanceName in [NSAppearance.Name.darkAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            // The SwiftUI Color → NSColor bridge also consults the application
            // appearance; a drawing-only override does not carry its contrast.
            app.appearance = appearance
            func resolve(_ color: Color) throws -> NSColor {
                var resolved: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    resolved = NSColor(color).usingColorSpace(.sRGB)
                }
                return try XCTUnwrap(resolved)
            }
            let backgrounds = [SottoPalette.canvas, SottoPalette.surface, SottoPalette.sidebar]
            for background in backgrounds {
                let surface = try resolve(background)
                XCTAssertEqual(surface.alphaComponent, 1, "Accessibility fallbacks must not read through the desktop")
                for foreground in [SottoPalette.ink, SottoPalette.muted, SottoPalette.accentInk] {
                    let ink = try resolve(foreground)
                    let lighter = max(luminance(ink), luminance(surface))
                    let darker = min(luminance(ink), luminance(surface))
                    XCTAssertGreaterThanOrEqual((lighter + 0.05) / (darker + 0.05), 4.5,
                                               "Small text must remain readable in \(appearanceName)")
                }
            }
        }
    }

    @MainActor
    func testStatusButtonKeepsVisibleArtworkAcrossRecordingAndProcessingTransitions() throws {
        let app = NSApplication.shared
        let previousAppearance = app.appearance
        defer { app.appearance = previousAppearance }
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        let frame = button.frame
        let transitions: [(DictationActivity, String)] = [
            (.idle, "hold Fn / Globe"), (.starting, "starting microphone"),
            (.recording, "listening"), (.transcribing, "transcribing"),
            (.delivering, "delivering your words"), (.success, "hold Fn / Globe"),
            (.failed, "needs attention"), (.idle, "hold Fn / Globe")
        ]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua,
                               .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            app.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            for (activity, label) in transitions {
                // Simulate an earlier colored state; every update must restore
                // native menu-bar contrast rather than retain a custom tint.
                button.contentTintColor = .systemRed
                SottoBrand.updateStatusButton(button, activity: activity, shortcut: .fn)
                let image = try XCTUnwrap(button.image)
                XCTAssertTrue(image.isTemplate)
                XCTAssertNil(button.contentTintColor)
                XCTAssertEqual(button.frame, frame)
                XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
                XCTAssertTrue(button.toolTip?.contains(label) == true)
                XCTAssertEqual(button.accessibilityLabel(), button.toolTip)

                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                var ink = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                        ink += 1
                    }
                }
                XCTAssertGreaterThan(ink, 8, "\(activity) must have visible artwork in \(appearanceName)")
                XCTAssertLessThan(ink, bitmap.pixelsWide * bitmap.pixelsHigh, "Templates need a transparent background")
            }
        }
        let resting = SottoBrand.statusImage(for: .idle)
        let recording = SottoBrand.statusImage(for: .recording)
        let processing = SottoBrand.statusImage(for: .transcribing)
        XCTAssertNotEqual(resting.tiffRepresentation, recording.tiffRepresentation)
        XCTAssertNotEqual(recording.tiffRepresentation, processing.tiffRepresentation)
        XCTAssertTrue(resting === SottoBrand.statusImage(for: .success))
        XCTAssertTrue(recording === SottoBrand.statusImage(for: .starting))
        XCTAssertTrue(processing === SottoBrand.statusImage(for: .delivering))
    }

    @MainActor
    func testMicrophoneInventoryRefreshesStableUIDsAndCurrentHALHandlesWithoutOpeningAudio() async {
        let builtIn = AudioInputDevice(uid: "built-in", name: "Mac microphone", transport: .builtIn)
        let usb = AudioInputDevice(uid: "usb-serial", name: "Desk microphone", transport: .usb)
        var snapshot = AudioHardwareSnapshot(
            deviceIDs: [12, 23, 45],
            inputs: [AudioInputHandle(deviceID: 12, device: builtIn), AudioInputHandle(deviceID: 23, device: usb)],
            systemDefaultID: 12
        )
        let store = AudioDeviceStore(hardware: AudioHardwareClient(snapshot: { snapshot }, observe: { _, _, _, _ in nil }))
        var publications: [([AudioInputDevice], String?)] = []
        store.onChange = { publications.append(($0, $1)) }
        store.start()

        XCTAssertEqual(store.devices, [usb, builtIn])
        XCTAssertEqual(store.systemDefaultUID, builtIn.uid)
        XCTAssertEqual(store.deviceID(for: usb.uid), 23)
        store.refresh()
        XCTAssertEqual(publications.count, 1, "Unchanged HAL notifications should not churn UI state")

        snapshot = AudioHardwareSnapshot(deviceIDs: [12, 45], inputs: [AudioInputHandle(deviceID: 12, device: builtIn)], systemDefaultID: 12)
        store.refresh()
        XCTAssertNil(store.deviceID(for: usb.uid))
        XCTAssertEqual(store.devices, [builtIn])

        // Reconnecting the same physical microphone can allocate a different ID.
        snapshot = AudioHardwareSnapshot(
            deviceIDs: [12, 45, 99],
            inputs: [AudioInputHandle(deviceID: 12, device: builtIn), AudioInputHandle(deviceID: 99, device: usb)],
            systemDefaultID: 99
        )
        store.refresh()
        XCTAssertEqual(store.deviceID(for: usb.uid), 99)
        XCTAssertEqual(store.systemDefaultUID, usb.uid)

        snapshot = AudioHardwareSnapshot(deviceIDs: [45], inputs: [], systemDefaultID: nil)
        store.refresh()
        XCTAssertTrue(store.devices.isEmpty)
        XCTAssertNil(store.systemDefaultUID)
        XCTAssertNil(store.deviceID(for: builtIn.uid))
        store.stop()
    }

    @MainActor
    func testMicrophoneObservationRefreshesOnHotplugAndStopsLateCallbacks() async {
        let device = AudioInputDevice(uid: "microphone", name: "Microphone", transport: .usb)
        var snapshot = AudioHardwareSnapshot(deviceIDs: [72], inputs: [AudioInputHandle(deviceID: 72, device: device)], systemDefaultID: 72)
        var reads = 0
        var callbacks: [AudioObjectID: [@MainActor () -> Void]] = [:]
        var cancelledObjects: [AudioObjectID] = []
        let store = AudioDeviceStore(hardware: AudioHardwareClient(
            snapshot: { reads += 1; return snapshot },
            observe: { object, _, _, callback in
                callbacks[object, default: []].append(callback)
                return AudioDeviceObservation { cancelledObjects.append(object) }
            }
        ))
        store.start()
        let firstReadCount = reads
        store.start()
        XCTAssertEqual(reads, firstReadCount, "Starting monitoring twice must not install duplicate listeners")

        snapshot = AudioHardwareSnapshot(deviceIDs: [], inputs: [], systemDefaultID: nil)
        callbacks[AudioObjectID(kAudioObjectSystemObject)]?.first?()
        XCTAssertTrue(store.devices.isEmpty)
        XCTAssertTrue(cancelledObjects.contains(72), "Disconnected-device listeners must be released")

        store.stop()
        let stoppedReadCount = reads
        callbacks.values.flatMap { $0 }.forEach { $0() }
        XCTAssertEqual(reads, stoppedReadCount, "Previously enqueued callbacks must not revive a stopped store")
        XCTAssertTrue(cancelledObjects.contains(AudioObjectID(kAudioObjectSystemObject)))
    }

    func testInputOnlyCaptureDisablesPlaybackBeforeBindingSelectedDevice() throws {
        let driver = FakeInputAudioUnitDriver()
        let input = InputOnlyAudioUnit(operations: driver.operations)
        defer { input.stop() }
        XCTAssertThrowsError(try input.prepare(deviceID: kAudioObjectUnknown))
        XCTAssertTrue(driver.events.isEmpty, "An unknown input must never fall back to a default device")
        let format = try input.prepare(deviceID: 23)

        XCTAssertEqual(Array(driver.events.prefix(4)), ["create", "disable-output", "enable-input", "bind:23"])
        XCTAssertEqual(format.sampleRate, 48_000)
        XCTAssertEqual(format.channelCount, 2)
        XCTAssertEqual(driver.clientFormat?.mSampleRate, driver.hardware.mSampleRate)
        XCTAssertEqual(driver.clientFormat?.mChannelsPerFrame, driver.hardware.mChannelsPerFrame)
        XCTAssertEqual(driver.streamFormatWrites, ["output:1"], "Only set our capture client format, never hardware/playback formats")
        XCTAssertFalse(driver.events.contains("start"), "Preparing a take must not start IO")
    }

    func testInputOnlyCaptureRejectsChannelCountsBeyondOriginalUploadLimit() {
        for channels in [UInt32(9), 16] {
            let driver = FakeInputAudioUnitDriver()
            driver.hardware.mChannelsPerFrame = channels
            let input = InputOnlyAudioUnit(operations: driver.operations)
            XCTAssertThrowsError(try input.prepare(deviceID: 23)) { error in
                guard case InputAudioUnitError.invalidFormat = error else {
                    return XCTFail("Expected an unsupported microphone format, got \(error)")
                }
            }
            XCTAssertNil(driver.clientFormat)
            XCTAssertFalse(driver.events.contains("start"))
            XCTAssertEqual(driver.events.last, "dispose")
        }
    }

    func testFourChannelInterfacePreservesOriginalAndMixesEveryInputForSpeech() async throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
        let hardwareFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                          interleaved: false, channelLayout: layout)
        let driver = FakeInputAudioUnitDriver()
        driver.hardware = hardwareFormat.streamDescription.pointee
        let input = InputOnlyAudioUnit(operations: driver.operations)
        defer { input.stop() }
        let format = try input.prepare(deviceID: 23)
        XCTAssertEqual(format.channelCount, 4)
        XCTAssertEqual(driver.clientFormat?.mChannelsPerFrame, 4)

        // A microphone on input 2 or a higher channel must not become silence.
        for activeChannel in 0..<4 {
            let writer = try RecordingWriter(inputFormat: format, preserveOriginalAudio: true,
                                             onLevel: { _ in }, onError: { XCTFail($0) })
            defer { writer.cancel() }
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<4 {
                for frame in 0..<4_800 { channels[channel][frame] = channel == activeChannel ? 0.5 : 0 }
            }
            writer.append(buffer)
            let audio = try await writer.finish()
            defer { audio.cleanup() }
            let speechFile = try AVAudioFile(forReading: audio.url)
            let speech = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: speechFile.processingFormat, frameCapacity: 1_600))
            try speechFile.read(into: speech)
            XCTAssertEqual(speech.floatChannelData![0][800], 0.125, accuracy: 0.001)
            let original = try XCTUnwrap(audio.original)
            XCTAssertEqual(original.channelCount, 4)
            XCTAssertEqual(original.frameCount, 4_800)
            let originalFile = try AVAudioFile(forReading: original.url)
            let raw = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: originalFile.processingFormat, frameCapacity: 4_800))
            try originalFile.read(into: raw)
            XCTAssertEqual(raw.floatChannelData![activeChannel][800], 0.5, accuracy: 0.00001)
        }
    }

    func testInputOnlyCapturePreservesDevicePCMAndStopsAdmissionBeforeTeardown() async throws {
        let driver = FakeInputAudioUnitDriver()
        let input = InputOnlyAudioUnit(operations: driver.operations)
        defer { input.stop() }
        let format = try input.prepare(deviceID: 23)
        let writer = try RecordingWriter(inputFormat: format, preserveOriginalAudio: true, onLevel: { _ in }, onError: { _ in })
        defer { writer.cancel() }
        let request = AudioCaptureRequest()
        try input.start(request: request, onAudio: { writer.append($0) }, onError: { driver.errors.append($0) })
        for _ in 0..<3 { driver.emit(frames: 3_840) }
        request.release()
        driver.emit(frames: 3_840)
        // Simulate a callback in the driver's stop call; its refCon remains alive
        // but its gate must already be closed and no PCM may be read/admitted.
        driver.onStop = { driver.emit(frames: 3_840) }
        input.stop()
        let audio = try await writer.finish()
        defer { audio.cleanup() }
        XCTAssertEqual(driver.renderCount, 3)
        XCTAssertTrue(driver.errors.isEmpty)
        XCTAssertEqual(Array(driver.events.suffix(3)), ["stop", "uninitialize", "dispose"])
        XCTAssertEqual(audio.duration, 0.24, accuracy: 1.0 / 16_000)
        let original = try XCTUnwrap(audio.original)
        XCTAssertEqual(original.sampleRate, 48_000)
        XCTAssertEqual(original.channelCount, 2)
        XCTAssertEqual(original.frameCount, 11_520)
        let file = try AVAudioFile(forReading: original.url)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 11_520))
        try file.read(into: pcm)
        let channels = try XCTUnwrap(pcm.floatChannelData)
        XCTAssertEqual(channels[0][2_000], 0.1, accuracy: 0.00001)
        XCTAssertEqual(channels[1][2_000], 0.2, accuracy: 0.00001)
    }

    func testInputOnlyCaptureDoesNotRebindOrRestartAfterRouteChanges() throws {
        let driver = FakeInputAudioUnitDriver()
        let input = InputOnlyAudioUnit(operations: driver.operations)
        defer { input.stop() }
        _ = try input.prepare(deviceID: 23)
        try input.start(request: AudioCaptureRequest(), onAudio: { _ in }, onError: { _ in })
        for _ in 0..<5 { try input.validateRoute(requireRunning: true) }
        driver.hardware.mSampleRate = 24_000
        XCTAssertThrowsError(try input.validateRoute(requireRunning: true))
        driver.hardware.mSampleRate = 48_000
        driver.selectedDevice = 99
        XCTAssertThrowsError(try input.validateRoute(requireRunning: true))
        driver.selectedDevice = 23
        driver.running = false
        XCTAssertThrowsError(try input.validateRoute(requireRunning: true))
        XCTAssertEqual(driver.events.filter { $0.hasPrefix("bind:") }, ["bind:23"])
        XCTAssertEqual(driver.events.filter { $0 == "start" }.count, 1)
    }

    func testInputOnlyCaptureCleansUpPartialStartupFailures() throws {
        for stage in ["initialize", "buffer", "start"] {
            let driver = FakeInputAudioUnitDriver()
            if stage == "initialize" { driver.initializeResult = kAudioUnitErr_FailedInitialization }
            if stage == "buffer" { driver.maximumFrames = 0 }
            if stage == "start" { driver.startResult = kAudioUnitErr_CannotDoInCurrentContext }
            let input = InputOnlyAudioUnit(operations: driver.operations)
            _ = try input.prepare(deviceID: 23)
            let request = AudioCaptureRequest()
            XCTAssertThrowsError(try input.start(request: request, onAudio: { _ in }, onError: { _ in }))
            XCTAssertTrue(request.isCancelled)
            XCTAssertEqual(Array(driver.events.suffix(2)), ["uninitialize", "dispose"])
            if stage == "start" { XCTAssertTrue(driver.events.contains("stop")) }
            input.stop()
            XCTAssertEqual(driver.events.filter { $0 == "dispose" }.count, 1)
        }
    }

    func testInputOnlyCaptureReleaseDuringInitializationCannotStartIO() throws {
        let driver = FakeInputAudioUnitDriver()
        let input = InputOnlyAudioUnit(operations: driver.operations)
        defer { input.stop() }
        _ = try input.prepare(deviceID: 23)
        let request = AudioCaptureRequest()
        driver.onInitialize = { request.release() }
        XCTAssertThrowsError(try input.start(request: request, onAudio: { _ in }, onError: { _ in }))
        XCTAssertFalse(driver.events.contains("start"))
        XCTAssertEqual(driver.events.last, "dispose")
    }

    func testInputOnlyCaptureBoundsCallbacksAndReportsDriverErrorsOnce() throws {
        for oversized in [true, false] {
            let driver = FakeInputAudioUnitDriver()
            let input = InputOnlyAudioUnit(operations: driver.operations)
            defer { input.stop() }
            _ = try input.prepare(deviceID: 23)
            try input.start(request: AudioCaptureRequest(), onAudio: { _ in XCTFail("Bad PCM must not be delivered") },
                            onError: { driver.errors.append($0) })
            if !oversized { driver.renderResult = kAudioUnitErr_CannotDoInCurrentContext }
            driver.emit(frames: oversized ? driver.maximumFrames + 1 : 512)
            driver.emit(frames: 512)
            XCTAssertEqual(driver.errors, [oversized ? kAudioUnitErr_TooManyFramesToProcess : kAudioUnitErr_CannotDoInCurrentContext])
            XCTAssertEqual(driver.renderCount, oversized ? 0 : 1)
        }
    }

    @MainActor
    func testRecorderRecoversAfterAnAudioSetupErrorWithoutReusingFailedHardware() async throws {
        let failed = FakeRecorderHardware(startupError: InputAudioUnitError.routeChanged)
        let next = FakeRecorderHardware()
        let factory = FakeRecorderFactory([failed, next])
        let recorder = AudioRecorder(worker: factory.worker, microphoneAuthorized: { true }, sleepNotifications: NotificationCenter())
        defer { recorder.cancel() }
        do { try await recorder.start(deviceID: 23); XCTFail("Format failure must be reported") }
        catch InputAudioUnitError.routeChanged { }
        XCTAssertTrue(try XCTUnwrap(failed.captureRequest).isCancelled)
        try await recorder.start(deviceID: 23)
        let audio = try await recorder.stop()
        defer { audio.cleanup() }
        XCTAssertEqual(audio.duration, 0.5)
        XCTAssertEqual(factory.createdCount, 2)
        XCTAssertFalse(failed.observedMainThread || next.observedMainThread)
    }

    func testDevOrphanedCapturesAreRemovedWithoutTouchingStableAppFiles() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("Sotto-cleanup-test-\(UUID())", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let captures = ["Sotto-Dev-recording-\(UUID())"]
        let unrelated = ["Sotto-recording-\(UUID())", "Murmur-recording-\(UUID())", "Sotto-recording-notes", "Murmur-recording-notes", "transcripts"]
        for name in captures + unrelated {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try files.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("synthetic audio".utf8).write(to: directory.appendingPathComponent("audio.wav"))
        }

        CapturedAudio.cleanupOrphans(in: root)

        XCTAssertEqual(Set(try files.contentsOfDirectory(atPath: root.path)), Set(unrelated))
        for name in unrelated {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name + "/audio.wav")), Data("synthetic audio".utf8))
        }
    }

    @MainActor
    func testRecorderReleaseBeforeHardwareStartupClosesAdmissionWithoutLateActivation() async throws {
        let entered = expectation(description: "Background startup entered")
        let gate = DispatchSemaphore(value: 0)
        let hardware = FakeRecorderHardware(entered: entered, gate: gate)
        let factory = FakeRecorderFactory([hardware])
        let recorder = AudioRecorder(worker: factory.worker, microphoneAuthorized: { true }, sleepNotifications: NotificationCenter())
        defer { gate.signal(); recorder.cancel() }
        let start = Task { try await recorder.start(deviceID: 23) }
        await fulfillment(of: [entered], timeout: 2)

        XCTAssertFalse(hardware.observedMainThread)
        recorder.stopAcceptingAudio()
        XCTAssertFalse(try XCTUnwrap(hardware.captureRequest).acceptsAudio)
        let stop = Task { try await recorder.stop() }
        gate.signal()
        do { try await start.value; XCTFail("A released, unopened take must not start") }
        catch AudioRecordingError.noAudio { }
        do { let audio = try await stop.value; audio.cleanup(); XCTFail("There was no admitted audio") }
        catch AudioRecordingError.noAudio { }
        XCTAssertEqual(hardware.openCount, 0)
    }

    @MainActor
    func testRecorderReleaseDuringStartupPreservesOnlyAlreadyAdmittedPCM() async throws {
        let entered = expectation(description: "Hardware started before slow start returned")
        let gate = DispatchSemaphore(value: 0)
        let hardware = FakeRecorderHardware(entered: entered, gate: gate, capturesBeforeGate: true)
        let factory = FakeRecorderFactory([hardware])
        let recorder = AudioRecorder(worker: factory.worker, microphoneAuthorized: { true }, sleepNotifications: NotificationCenter())
        defer { gate.signal(); recorder.cancel() }
        let start = Task { try await recorder.start(deviceID: 23, preserveOriginalAudio: true) }
        await fulfillment(of: [entered], timeout: 2)

        recorder.stopAcceptingAudio()
        try hardware.emitPCM(frames: 8_000) // A callback arriving after release is ignored.
        let stop = Task { try await recorder.stop() }
        gate.signal()
        try await start.value
        let audio = try await stop.value
        defer { audio.cleanup() }

        XCTAssertEqual(audio.duration, 0.5)
        XCTAssertEqual(try AVAudioFile(forReading: audio.url).length, 8_000)
        let original = try XCTUnwrap(audio.original)
        XCTAssertEqual(original.frameCount, 8_000, "Original audio must use the same admission gate")
        XCTAssertEqual(try AVAudioFile(forReading: original.url).length, 8_000)
        XCTAssertEqual(hardware.selectedDevice, 23)
        XCTAssertEqual(hardware.stopCount, 1)
        XCTAssertFalse(hardware.observedMainThread)
    }

    @MainActor
    func testRecorderCancelledStartupAndLateCallbacksCannotAffectNextTake() async throws {
        let entered = expectation(description: "First startup entered")
        let gate = DispatchSemaphore(value: 0)
        let first = FakeRecorderHardware(entered: entered, gate: gate, capturesBeforeGate: true)
        let second = FakeRecorderHardware()
        let factory = FakeRecorderFactory([first, second])
        let worker = factory.worker
        let recorder = AudioRecorder(worker: worker, microphoneAuthorized: { true }, sleepNotifications: NotificationCenter())
        defer { gate.signal(); recorder.cancel() }
        var levels: [Float] = []
        var interruptions: [String] = []
        recorder.onLevel = { levels.append($0) }
        recorder.onInterruption = { interruptions.append($0) }
        let oldStart = Task { try await recorder.start(deviceID: 23) }
        await fulfillment(of: [entered], timeout: 2)

        recorder.cancel()
        let oldRequest = try XCTUnwrap(first.captureRequest)
        XCTAssertFalse(oldRequest.acceptsAudio)
        let newStart = Task { try await recorder.start(deviceID: 99) }
        gate.signal()
        do { try await oldStart.value; XCTFail("Cancelled startup must not succeed") }
        catch AudioRecordingError.cancelled { }
        try await newStart.value
        levels.removeAll()
        first.emitLevel(0.98765)
        first.emitInterruption("Late old-take interruption")
        second.emitLevel(0.25)
        worker.cancel(request: oldRequest) // An already queued old teardown must be harmless.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertFalse(levels.contains(0.98765))
        XCTAssertEqual(levels.last, 0.25)
        XCTAssertTrue(interruptions.isEmpty)
        let audio = try await recorder.stop()
        defer { audio.cleanup() }
        XCTAssertEqual(audio.duration, 0.5)
        XCTAssertEqual(second.selectedDevice, 99)
        XCTAssertEqual(second.stopCount, 1)
        XCTAssertFalse(first.observedMainThread || second.observedMainThread)
    }

    @MainActor
    func testCancellingTheStartupTaskClosesAdmissionBeforeDriverReturns() async throws {
        let entered = expectation(description: "Slow startup entered")
        let gate = DispatchSemaphore(value: 0)
        let hardware = FakeRecorderHardware(entered: entered, gate: gate)
        let factory = FakeRecorderFactory([hardware])
        let recorder = AudioRecorder(worker: factory.worker, microphoneAuthorized: { true }, sleepNotifications: NotificationCenter())
        defer { gate.signal(); recorder.cancel() }
        let start = Task { try await recorder.start(deviceID: 23) }
        await fulfillment(of: [entered], timeout: 2)

        start.cancel()
        XCTAssertTrue(try XCTUnwrap(hardware.captureRequest).isCancelled)
        gate.signal()
        do { try await start.value; XCTFail("Cancelled task must not activate capture") }
        catch AudioRecordingError.cancelled { }
        XCTAssertEqual(hardware.openCount, 0)
    }

    @MainActor
    func testRecorderDoesNotConstructHardwareAtIdleOrWithoutMicrophonePermission() async {
        let factory = FakeRecorderFactory([FakeRecorderHardware()])
        let recorder = AudioRecorder(worker: factory.worker, microphoneAuthorized: { false }, sleepNotifications: NotificationCenter())
        XCTAssertEqual(factory.createdCount, 0)
        do { try await recorder.start(deviceID: 23); XCTFail("Missing permission must prevent hardware creation") }
        catch AudioRecordingError.permissionRequired { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(factory.createdCount, 0)
    }

    func testHotkeyAccessAcceptsAccessibilityOrInputMonitoringWithoutConflatingThem() {
        let accessibilityOnly = PermissionSnapshot(microphone: false, accessibility: true, inputMonitoring: false)
        let monitoringOnly = PermissionSnapshot(microphone: false, accessibility: false, inputMonitoring: true)
        let neither = PermissionSnapshot(microphone: true, accessibility: false, inputMonitoring: false)
        let both = PermissionSnapshot(microphone: true, accessibility: true, inputMonitoring: true)
        XCTAssertTrue(accessibilityOnly.canListenForHotkey)
        XCTAssertTrue(monitoringOnly.canListenForHotkey)
        XCTAssertFalse(neither.canListenForHotkey)
        XCTAssertTrue(both.canListenForHotkey)
        XCTAssertFalse(accessibilityOnly.inputMonitoring)
    }

    func testOnlyPhysicalRightOptionStartsOptionHold() {
        let leftOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        let rightOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        XCTAssertFalse(HoldKey.rightOption.isDown(in: leftOption))
        XCTAssertTrue(HoldKey.rightOption.isDown(in: rightOption))
        XCTAssertFalse(HoldKey.rightOption.isDown(in: .maskAlternate))
        XCTAssertTrue(HoldKey.rightOption.hasOtherModifiers(in: leftOption.union(rightOption)))
        XCTAssertFalse(HoldKey.rightOption.hasOtherModifiers(in: rightOption))
    }

    func testOnlyPhysicalRightControlStartsControlHold() {
        let leftControl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x1)
        let rightControl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)
        XCTAssertFalse(HoldKey.rightControl.isDown(in: leftControl))
        XCTAssertTrue(HoldKey.rightControl.isDown(in: rightControl))
        XCTAssertTrue(HoldKey.rightControl.hasOtherModifiers(in: leftControl.union(rightControl)))
        XCTAssertFalse(HoldKey.rightControl.hasOtherModifiers(in: rightControl))
    }

    func testModifierChordsAreNotDictationButCapsLockIsAllowed() {
        for key in HoldKey.allCases {
            XCTAssertTrue(key.hasOtherModifiers(in: .maskCommand))
            XCTAssertTrue(key.hasOtherModifiers(in: .maskShift))
            XCTAssertFalse(key.hasOtherModifiers(in: .maskAlphaShift))
        }
        XCTAssertTrue(HoldKey.fn.isDown(in: .maskSecondaryFn))
        XCTAssertFalse(HoldKey.fn.isDown(in: .maskAlternate))
        XCTAssertTrue(HoldKey.fn.hasOtherModifiers(in: [.maskSecondaryFn, .maskAlternate]))
    }

    func testSecureAndUnknownFieldsAreRejected() {
        XCTAssertTrue(InsertionFieldPolicy.allows(role: "AXTextArea", subrole: nil, protectedContent: false, enabled: true))
        XCTAssertTrue(InsertionFieldPolicy.allows(role: "AXTextField", subrole: "AXSearchField", protectedContent: false, enabled: true))
        XCTAssertFalse(InsertionFieldPolicy.allows(role: "AXTextField", subrole: "AXSecureTextField", protectedContent: false, enabled: true))
        XCTAssertFalse(InsertionFieldPolicy.allows(role: "AXTextArea", subrole: nil, protectedContent: true, enabled: true))
        XCTAssertFalse(InsertionFieldPolicy.allows(role: "AXTextArea", subrole: nil, protectedContent: false, enabled: false))
        XCTAssertFalse(InsertionFieldPolicy.allows(role: "AXWebArea", subrole: nil, protectedContent: false, enabled: true))
        XCTAssertFalse(InsertionFieldPolicy.allows(role: nil, subrole: nil, protectedContent: false, enabled: true))
        // A confirmed noneditable surface may use clipboard delivery; unknown
        // field metadata must remain blocked, not silently become a copy.
        XCTAssertEqual(InsertionFieldPolicy.eligibility(role: "AXWebArea", subrole: nil, protectedContent: false, enabled: true), .notEditable)
        XCTAssertEqual(InsertionFieldPolicy.eligibility(role: nil, subrole: nil, protectedContent: false, enabled: true), .unverified)
        XCTAssertEqual(InsertionFieldPolicy.eligibility(role: "", subrole: nil, protectedContent: false, enabled: true), .unverified)
        XCTAssertEqual(InsertionFieldPolicy.eligibility(role: nil, subrole: "AXSecureTextField", protectedContent: false, enabled: true), .protected)
    }

    func testContinuationCaretUsesUTF16AndReplacementOffset() {
        let selection = NSRange(location: 12, length: 5)
        XCTAssertTrue(InsertionCaretPolicy.matches(NSRange(location: 14, length: 0), replacing: selection, with: "🙂"))
        XCTAssertFalse(InsertionCaretPolicy.matches(NSRange(location: 13, length: 0), replacing: selection, with: "🙂"))
        XCTAssertFalse(InsertionCaretPolicy.matches(NSRange(location: 19, length: 0), replacing: selection, with: "🙂"))
        XCTAssertFalse(InsertionCaretPolicy.matches(NSRange(location: 14, length: 1), replacing: selection, with: "🙂"))
        XCTAssertFalse(InsertionCaretPolicy.matches(NSRange(location: 0, length: 0), replacing: NSRange(location: NSNotFound, length: 0), with: "text"))
        XCTAssertFalse(InsertionCaretPolicy.matches(NSRange(location: 0, length: 0), replacing: NSRange(location: Int.max - 1, length: 0), with: "🙂"))
    }

    func testInsertionCaptureAllowsCompletionBeforeOrExactlyAtRelease() {
        XCTAssertTrue(InsertionCapturePolicy.permitsInsertion(capturedAt: 7.5, releasedAt: 10))
        XCTAssertTrue(InsertionCapturePolicy.permitsInsertion(capturedAt: 10, releasedAt: 10))
        XCTAssertTrue(InsertionCapturePolicy.permitsInsertion(capturedAt: 0, releasedAt: 0))
    }

    func testInsertionCaptureRejectsGenuinelyLateOrInvalidTimes() {
        let releasedAt: TimeInterval = 10
        XCTAssertFalse(InsertionCapturePolicy.permitsInsertion(capturedAt: releasedAt.nextUp, releasedAt: releasedAt))
        for invalid in [TimeInterval.nan, .infinity, -.infinity, -1] {
            XCTAssertFalse(InsertionCapturePolicy.permitsInsertion(capturedAt: invalid, releasedAt: releasedAt))
            XCTAssertFalse(InsertionCapturePolicy.permitsInsertion(capturedAt: 0, releasedAt: invalid))
        }
    }

    func testAudioWriterProducesPrivate16kMonoWAVWithoutDuplicatingInput() async throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let writer = try RecordingWriter(inputFormat: inputFormat, onLevel: { _ in }, onError: { _ in })
        for chunk in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<4_800 {
                let time = Double(chunk * 4_800 + frame) / 48_000
                let value = Float(sin(time * 440 * 2 * .pi)) * 0.3
                channels[0][frame] = value
                channels[1][frame] = value
            }
            writer.append(buffer)
        }
        let audio = try await writer.finish()
        defer { audio.cleanup() }

        let file = try AVAudioFile(forReading: audio.url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 1, accuracy: 0.002)
        XCTAssertEqual(audio.duration, 1, accuracy: 0.002)
        XCTAssertGreaterThan(audio.peak, 0.25)
        XCTAssertLessThan(audio.peak, 0.36)
        let filePermissions = try FileManager.default.attributesOfItem(atPath: audio.url.path)[.posixPermissions] as? Int
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: audio.url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(filePermissions, 0o600)
        XCTAssertEqual(directoryPermissions, 0o700)
        XCTAssertNil(audio.original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audio.url.deletingLastPathComponent().path), ["microphone.wav"])
    }

    func testAudioWriterPreservesOriginalStereoSamplesAndCleansUpBothFiles() async throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let writer = try RecordingWriter(inputFormat: inputFormat, preserveOriginalAudio: true, onLevel: { _ in }, onError: { _ in })
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<4_800 {
            channels[0][frame] = Float(frame) / 4_800
            channels[1][frame] = -Float(frame) / 9_600
        }
        writer.append(buffer)
        // The engine is allowed to immediately reuse its tap buffer.
        for channel in 0..<2 { channels[channel].update(repeating: 0, count: 4_800) }
        let audio = try await writer.finish()
        defer { audio.cleanup() }

        let original = try XCTUnwrap(audio.original)
        XCTAssertEqual(original.sampleRate, 48_000)
        XCTAssertEqual(original.channelCount, 2)
        XCTAssertEqual(original.frameCount, 4_800)
        XCTAssertEqual(original.encoding, "pcm_f32le")
        let file = try AVAudioFile(forReading: original.url)
        XCTAssertEqual(file.length, 4_800)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        let written = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800))
        try file.read(into: written)
        let samples = try XCTUnwrap(written.floatChannelData)
        for frame in 0..<4_800 {
            XCTAssertEqual(samples[0][frame].bitPattern, (Float(frame) / 4_800).bitPattern)
            XCTAssertEqual(samples[1][frame].bitPattern, (-Float(frame) / 9_600).bitPattern)
        }
        XCTAssertEqual(try AVAudioFile(forReading: audio.url).processingFormat.sampleRate, 16_000)
        XCTAssertEqual(try AVAudioFile(forReading: audio.url).processingFormat.channelCount, 1)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: original.url.path)[.posixPermissions] as? Int, 0o600)

        audio.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.url.deletingLastPathComponent().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.url.path))
    }

    func testAudioWriterPreservesInterleavedIntegerPCMPrecision() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 2, interleaved: true))
        let writer = try RecordingWriter(inputFormat: format, preserveOriginalAudio: true, onLevel: { _ in }, onError: { _ in })
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        let samples = try XCTUnwrap(buffer.int16ChannelData)[0]
        for frame in 0..<4_410 {
            samples[frame * 2] = Int16(frame)
            samples[frame * 2 + 1] = -Int16(frame)
        }
        writer.append(buffer)
        let audio = try await writer.finish()
        defer { audio.cleanup() }

        let original = try XCTUnwrap(audio.original)
        XCTAssertEqual(original.sampleRate, 44_100)
        XCTAssertEqual(original.frameCount, 4_410)
        XCTAssertEqual(original.channelCount, 2)
        XCTAssertEqual(original.encoding, "pcm_s16le")
        let file = try AVAudioFile(forReading: original.url, commonFormat: .pcmFormatInt16, interleaved: true)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
        let written = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_410))
        try file.read(into: written)
        let output = try XCTUnwrap(written.int16ChannelData)[0]
        for index in 0..<8_820 { XCTAssertEqual(output[index], samples[index]) }
    }

    func testQuietAudioDrivesTwentyHistorySamplesPerSecondWithoutChangingTheWAV() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        var levels: [Float] = []
        let writer = try RecordingWriter(inputFormat: format, onLevel: { levels.append($0) }, onError: { _ in })
        let amplitude = Float(sqrt(2.0) * 0.001) // A -60 dBFS RMS tone.
        var offset = 0
        while offset < 32_000 {
            // Deliberately not aligned to the meter's 800-frame windows.
            let count = min(257, 32_000 - offset)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for frame in 0..<count {
                let position = offset + frame
                samples[frame] = position < 16_000 ? amplitude * Float(sin(Double(position) * 440 * 2 * .pi / 16_000)) : 0
            }
            writer.append(buffer)
            offset += count
        }
        let audio = try await writer.finish()
        defer { audio.cleanup() }

        XCTAssertEqual(levels.count, 40)
        XCTAssertTrue(levels.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertEqual(try XCTUnwrap(levels.dropFirst(19).first), 0.16, accuracy: 0.002)
        XCTAssertEqual(Array(levels.suffix(5)), Array(repeating: 0, count: 5))
        let quietHistory = Array(levels.prefix(9))
        let heights = await MainActor.run { LiveWaveform(levels: quietHistory, height: 30).barHeights }
        XCTAssertGreaterThan(try XCTUnwrap(heights.min()), 6)

        let file = try AVAudioFile(forReading: audio.url)
        let written = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16))
        try file.read(into: written)
        let expectedSample = amplitude * Float(sin(7.0 * 440 * 2 * .pi / 16_000))
        XCTAssertEqual(try XCTUnwrap(written.floatChannelData)[0][7], expectedSample, accuracy: 0.0000001)
        XCTAssertEqual(audio.peak, amplitude, accuracy: 0.000001)
    }

    @MainActor
    func testWaveformUsesActualRecentHistoryAndKeepsNineBars() async {
        let waveform = LiveWaveform(levels: [0, 0.25, 0.5, 0.75, 1, .nan, .infinity, -1, 2], height: 30)
        XCTAssertEqual(waveform.barHeights, [3, 9.75, 16.5, 23.25, 30, 3, 3, 3, 30])
        XCTAssertEqual(LiveWaveform(levels: [1], height: 30).barHeights, Array(repeating: 3, count: 8) + [30])
        let longerHistory: [Float] = [1, 0.5] + Array(repeating: 0.25, count: 9)
        XCTAssertEqual(LiveWaveform(levels: longerHistory, height: 30).barHeights, Array(repeating: 9.75, count: 9))
    }

    @MainActor
    func testRecordingFeedbackDrainsPeaksThenStopsPublishingSilence() {
        let feedback = RecordingFeedback()
        var updates = 0
        let observation = feedback.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }

        for _ in 0..<20 { feedback.append(0) }
        XCTAssertEqual(updates, 0)
        feedback.append(1)
        for _ in 0..<8 { feedback.append(0) }
        XCTAssertEqual(feedback.levels.first, 1, "A peak remains visible until it traverses the full history")
        feedback.append(0)
        let settledUpdates = updates
        for _ in 0..<100 { feedback.append(0) }
        XCTAssertEqual(feedback.levels, Array(repeating: 0, count: 9))
        XCTAssertEqual(updates, settledUpdates, "Settled silence must not keep invalidating views")
    }

    @MainActor
    func testRecordingClockIgnoresSubsecondAndMeterOnlyUpdates() {
        let feedback = RecordingFeedback()
        var seconds: [Int] = []
        let observation = feedback.$elapsedSeconds.dropFirst().sink { seconds.append($0) }
        defer { observation.cancel() }

        for step in 0..<20 {
            feedback.updateElapsed(Double(step) / 20)
            feedback.append(Float(step) / 20)
        }
        XCTAssertTrue(seconds.isEmpty)
        feedback.updateElapsed(1.01)
        feedback.updateElapsed(1.99)
        feedback.updateElapsed(2.01)
        feedback.updateElapsed(10_000)
        XCTAssertEqual(seconds, [1, 2, 10_000])
        feedback.reset()
        XCTAssertEqual(seconds, [1, 2, 10_000, 0])
        XCTAssertEqual(feedback.levels, Array(repeating: 0, count: 9))
    }

    @MainActor
    func testRecordingTransferNoticeChangesOnlyWhenConnectionOrBacklogChanges() {
        let feedback = RecordingFeedback()
        var notices: [RecordingTransferNotice?] = []
        let observation = feedback.$transferNotice.dropFirst().sink { notices.append($0) }
        defer { observation.cancel() }

        feedback.updateTransfer(connected: false)
        XCTAssertEqual(feedback.transferNotice?.text, "Saved locally")
        for _ in 0..<20 { feedback.updateTransfer(connected: false); feedback.append(0.5) }
        XCTAssertEqual(notices.count, 1, "Waveform and unchanged state do not republish the notice")
        feedback.updateTransfer(connected: true, catchingUp: true)
        XCTAssertEqual(feedback.transferNotice?.text, "Transferring saved audio")
        feedback.updateTransfer(connected: true)
        XCTAssertNil(feedback.transferNotice)
        feedback.reset()
        XCTAssertEqual(notices.count, 3)
    }

    @MainActor
    func testRecordingTransferNoticeKeepsItsFootprintWhenHiddenAndVisible() throws {
        let feedback = RecordingFeedback()
        let view = NSHostingView(rootView: RecordingTransferNote(feedback: feedback)
            .frame(width: DictationHUD.width, height: DictationHUD.noticeHeight))
        let expected = NSSize(width: DictationHUD.width, height: DictationHUD.noticeHeight)
        for connected in [true, false, true] {
            feedback.updateTransfer(connected: connected, catchingUp: true)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.fittingSize, expected)
        }
    }

    @MainActor
    func testRecordingFeedbackNormalizesSamplesAndResetIsIdempotent() {
        let feedback = RecordingFeedback()
        for sample: Float in [.nan, .infinity, -1] { feedback.append(sample) }
        XCTAssertEqual(feedback.levels, Array(repeating: 0, count: 9))
        feedback.append(3)
        XCTAssertEqual(feedback.levels.last, 1)
        feedback.updateElapsed(2)
        feedback.reset()

        var updates = 0
        let observation = feedback.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }
        feedback.reset()
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(feedback.elapsedSeconds, 0)
    }

    func testAudioWriterRejectsAnEmptyRecording() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let writer = try RecordingWriter(inputFormat: format, onLevel: { _ in }, onError: { _ in })
        do {
            let audio = try await writer.finish()
            audio.cleanup()
            XCTFail("An empty recording must not be passed to the recognizer")
        } catch AudioRecordingError.noAudio {
            // Expected; no microphone or permission prompts are involved.
        }
    }

    func testAudioWriterCannotFinishAfterCancellation() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let writer = try RecordingWriter(inputFormat: format, onLevel: { _ in }, onError: { _ in })
        writer.cancel()
        do {
            let audio = try await writer.finish()
            audio.cleanup()
            XCTFail("Cancelled recordings must not reach the recognizer")
        } catch AudioRecordingError.cancelled {
            // Expected.
        }
    }

    func testAudioWriterClampsTimerOvershootToTheEngineDurationLimit() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let writer = try RecordingWriter(inputFormat: format, preserveOriginalAudio: true, onLevel: { _ in }, onError: { _ in })
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 181))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0.1, count: Int(buffer.frameLength))
        writer.append(buffer)
        let audio = try await writer.finish()
        defer { audio.cleanup() }
        XCTAssertEqual(audio.duration, 180)
        let file = try AVAudioFile(forReading: audio.url)
        XCTAssertEqual(file.length, 16_000 * 180)
        let original = try XCTUnwrap(audio.original)
        XCTAssertEqual(original.frameCount, 48_000 * 180)
        XCTAssertEqual(try AVAudioFile(forReading: original.url).length, 48_000 * 180)
    }

    @MainActor
    func testNoInsertionTargetCopiesOnlyTheNewListChunkPersistently() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Previous clipboard", forType: .string)
        let initialCount = pasteboard.changeCount
        let first = DictationComposer.compose(SpokenListFormatter.format("Make a list. One, apples. Two, bananas."))
        let formatted = SpokenListFormatter.format("Next item, oranges.", context: first.continuation?.list)
        let composed = DictationComposer.compose(formatted, previous: first.continuation)

        let outcome = await TextInserter(pasteboard: pasteboard).deliver(
            composed.insertion, copying: formatted.text, to: .clipboard,
            clipboardUnchangedSince: initialCount
        )

        XCTAssertEqual(outcome, .copied(reason: "Copied to clipboard"))
        XCTAssertEqual(pasteboard.string(forType: .string), "3. oranges")
        XCTAssertNil(pasteboard.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
    }

    @MainActor
    func testClipboardFallbackDoesNotReplaceANewerUserCopy() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("At the start of dictation", forType: .string)
        let initialCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("A newer user copy", forType: .string)
        let latestCount = pasteboard.changeCount

        let outcome = await TextInserter(pasteboard: pasteboard).deliver(
            "Spoken words. ", copying: "Spoken words.", to: .clipboard,
            clipboardUnchangedSince: initialCount
        )

        XCTAssertEqual(outcome, .failed(reason: ClipboardCopyError.changed.localizedDescription))
        XCTAssertEqual(pasteboard.changeCount, latestCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "A newer user copy")
    }

    @MainActor
    func testCancelledDictationDoesNotCopyToClipboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep this", forType: .string)
        let initialCount = pasteboard.changeCount
        let task = Task { @MainActor in
            await TextInserter(pasteboard: pasteboard).deliver(
                "Cancelled words", copying: "Cancelled words", to: .clipboard,
                clipboardUnchangedSince: initialCount
            )
        }
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .failed(reason: ClipboardCopyError.cancelled.localizedDescription))
        XCTAssertEqual(pasteboard.changeCount, initialCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep this")
    }

    @MainActor
    func testEmptyListCommandsAndProtectedDestinationsNeverCopy() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep this", forType: .string)
        let initialCount = pasteboard.changeCount
        let inserter = TextInserter(pasteboard: pasteboard)
        let start = DictationComposer.compose(SpokenListFormatter.format("Start a list. One, apples."))
        let ending = SpokenListFormatter.format("End list.", context: start.continuation?.list)
        let composed = DictationComposer.compose(ending, previous: start.continuation)
        let empty = await inserter.deliver(composed.insertion, copying: ending.text, to: .clipboard,
                                           clipboardUnchangedSince: initialCount)
        XCTAssertEqual(empty, .failed(reason: "There is no text to deliver."))

        let blocked = await inserter.deliver("Private words", copying: "Private words",
                                             to: .blocked(reason: "Protected field"),
                                             clipboardUnchangedSince: initialCount)
        XCTAssertEqual(blocked, .failed(reason: "Protected field"))
        XCTAssertEqual(pasteboard.changeCount, initialCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep this")
    }

    @MainActor
    func testNativeWriteNeedsConfirmationAndNeverRetriesThroughPaste() async {
        for write in [NativeTextWrite.acknowledged, .uncertain(reason: "AX timed out")] {
            let fixture = TextDeliveryFixture()
            defer { fixture.pasteboard.releaseGlobally() }
            fixture.nativeResult = write

            let outcome = await fixture.transaction.deliver("New words. ", copying: "New words.",
                strategy: .nativeSelection, clipboardUnchangedSince: fixture.holdStartCount)

            XCTAssertEqual(outcome, .unconfirmed(clipboardBackup: true))
            XCTAssertEqual(fixture.nativeWrites, ["New words. "])
            XCTAssertEqual(fixture.pasteAttempts, 0, "An acknowledged no-op or uncertain write must never send a second delivery")
            XCTAssertGreaterThan(fixture.confirmationReads, 0)
            XCTAssertLessThanOrEqual(fixture.confirmationReads, 8)
            XCTAssertLessThanOrEqual(fixture.pauses.reduce(0, +), 700_000_000)
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), "New words.")
            XCTAssertNil(fixture.pasteboard.data(forType: TextDeliveryFixture.transientType))
        }
    }

    @MainActor
    func testNativeWriteCanBeConfirmedWithoutTouchingClipboard() async {
        for write in [NativeTextWrite.acknowledged, .uncertain(reason: "AX timed out")] {
            let fixture = TextDeliveryFixture()
            defer { fixture.pasteboard.releaseGlobally() }
            fixture.nativeResult = write
            fixture.onConfirmation = { $0 == 1 ? .pending : .confirmed }

            let outcome = await fixture.transaction.deliver("Words", copying: "Words",
                strategy: .nativeSelection, clipboardUnchangedSince: fixture.holdStartCount)

            XCTAssertEqual(outcome, .inserted)
            XCTAssertEqual(fixture.nativeWrites, ["Words"])
            XCTAssertEqual(fixture.pasteAttempts, 0)
            XCTAssertEqual(fixture.pasteboard.changeCount, fixture.holdStartCount)
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Original clipboard")
        }
    }

    @MainActor
    func testUnsupportedNativeWritePastesOnceAndWaitsForConfirmationBeforeRestoringRichClipboard() async {
        let fixture = TextDeliveryFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let original = NSPasteboardItem()
        original.setString("Rich original", forType: .string)
        let rtf = Data("{\\rtf1 Rich original}".utf8)
        original.setData(rtf, forType: .rtf)
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.writeObjects([original]))
        let count = fixture.pasteboard.changeCount
        fixture.onConfirmation = { [unowned fixture] attempt in
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Words. ")
            XCTAssertNotNil(fixture.pasteboard.data(forType: TextDeliveryFixture.transientType))
            if attempt == 1 { return .unavailable }
            return attempt == 2 ? .pending : .confirmed
        }

        let outcome = await fixture.transaction.deliver("Words. ", copying: "Words.",
            strategy: .nativeSelection, clipboardUnchangedSince: count)

        XCTAssertEqual(outcome, .inserted)
        XCTAssertEqual(fixture.nativeWrites, ["Words. "])
        XCTAssertEqual(fixture.pasteAttempts, 1)
        XCTAssertEqual(fixture.confirmationReads, 3)
        XCTAssertEqual(fixture.pauses, [100_000_000, 100_000_000])
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Rich original")
        XCTAssertEqual(fixture.pasteboard.data(forType: .rtf), rtf)
    }

    @MainActor
    func testUnconfirmedPasteKeepsOnlyTheNewListChunkAsPersistentBackup() async {
        let fixture = TextDeliveryFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.confirmationResult = .unavailable
        let first = DictationComposer.compose(SpokenListFormatter.format("Make a list. One, apples. Two, bananas."))
        let formatted = SpokenListFormatter.format("Next item, oranges.", context: first.continuation?.list)
        let composed = DictationComposer.compose(formatted, previous: first.continuation)
        fixture.onPaste = { [unowned fixture] canDispatch in
            XCTAssertTrue(canDispatch())
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), composed.insertion)
            return .sent
        }

        let outcome = await fixture.transaction.deliver(composed.insertion, copying: formatted.text,
            strategy: .keyboardPaste, clipboardUnchangedSince: fixture.holdStartCount)

        XCTAssertEqual(outcome, .unconfirmed(clipboardBackup: true))
        XCTAssertEqual(fixture.nativeWrites, [])
        XCTAssertEqual(fixture.pasteAttempts, 1)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "3. oranges")
        XCTAssertNil(fixture.pasteboard.data(forType: TextDeliveryFixture.transientType))
    }

    @MainActor
    func testUnavailableConfirmationKeepsStagedPasteForBoundedGraceBeforeRestoringNewerCopy() async {
        let fixture = TextDeliveryFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.replaceClipboard(with: "Copied during the hold")
        fixture.confirmationResult = .unavailable
        fixture.onPause = { [unowned fixture] in
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Words. ")
            XCTAssertNotNil(fixture.pasteboard.data(forType: TextDeliveryFixture.transientType))
        }

        let outcome = await fixture.transaction.deliver("Words. ", copying: "Words.",
            strategy: .keyboardPaste, clipboardUnchangedSince: fixture.holdStartCount)

        XCTAssertEqual(outcome, .unconfirmed(clipboardBackup: false))
        XCTAssertEqual(fixture.pasteAttempts, 1)
        XCTAssertEqual(fixture.confirmationReads, 8)
        XCTAssertEqual(fixture.pauses, Array(repeating: 100_000_000, count: 7))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Copied during the hold")
        XCTAssertNil(fixture.pasteboard.data(forType: TextDeliveryFixture.transientType))
    }

    @MainActor
    func testPasteFinalizationPreservesCopiesMadeDuringHoldOrAfterDispatch() async {
        for duringDispatch in [false, true] {
            for confirmation in [DeliveryConfirmation.unavailable, .confirmed] {
                let fixture = TextDeliveryFixture()
                defer { fixture.pasteboard.releaseGlobally() }
                if !duringDispatch { fixture.replaceClipboard(with: "Newer user copy") }
                fixture.onConfirmation = { [unowned fixture] attempt in
                    if duringDispatch && attempt == 1 { fixture.replaceClipboard(with: "Newer user copy") }
                    return confirmation
                }

                let outcome = await fixture.transaction.deliver("Words. ", copying: "Words.",
                    strategy: .keyboardPaste, clipboardUnchangedSince: fixture.holdStartCount)

                XCTAssertEqual(outcome, confirmation == .confirmed ? .inserted : .unconfirmed(clipboardBackup: false))
                XCTAssertEqual(fixture.pasteAttempts, 1)
                XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Newer user copy")
                XCTAssertNil(fixture.pasteboard.data(forType: TextDeliveryFixture.transientType))
            }
        }
    }

    @MainActor
    func testChangedDestinationCopiesButBlockedDestinationDoesNotDeliverOrMutateClipboard() async {
        for blocked in [false, true] {
            let fixture = TextDeliveryFixture()
            defer { fixture.pasteboard.releaseGlobally() }
            fixture.validation = blocked ? .blocked(reason: "Protected field") : .changed(reason: "Cursor moved")

            let outcome = await fixture.transaction.deliver("New words. ", copying: "New words.",
                strategy: .nativeSelection, clipboardUnchangedSince: fixture.holdStartCount)

            XCTAssertEqual(outcome, blocked ? .failed(reason: "Protected field") : .copied(reason: "Copied to clipboard"))
            XCTAssertEqual(fixture.nativeWrites, [])
            XCTAssertEqual(fixture.pasteAttempts, 0)
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), blocked ? "Original clipboard" : "New words.")
            if blocked { XCTAssertEqual(fixture.pasteboard.changeCount, fixture.holdStartCount) }
        }
    }

    @MainActor
    func testPasteRevalidatesSafetyAndClipboardOwnershipImmediatelyBeforeDispatch() async {
        for change in ["focus", "protected", "clipboard", "modifier"] {
            let fixture = TextDeliveryFixture()
            defer { fixture.pasteboard.releaseGlobally() }
            fixture.onValidate = { [unowned fixture] attempt in
                guard attempt == 2 else { return .valid }
                switch change {
                case "focus": return .changed(reason: "Focus changed")
                case "protected": return .blocked(reason: "Protected field")
                case "clipboard": fixture.replaceClipboard(with: "Newer user copy")
                default: fixture.modifiersHeld = true
                }
                return .valid
            }

            let outcome = await fixture.transaction.deliver("Words. ", copying: "Words.",
                strategy: .keyboardPaste, clipboardUnchangedSince: fixture.holdStartCount)

            XCTAssertEqual(fixture.pasteAttempts, 0)
            XCTAssertEqual(fixture.confirmationReads, 0)
            switch change {
            case "focus":
                XCTAssertEqual(outcome, .copied(reason: "Copied to clipboard"))
                XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Words.")
            case "clipboard":
                XCTAssertEqual(outcome, .failed(reason: ClipboardCopyError.changed.localizedDescription))
                XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Newer user copy")
            default:
                guard case .failed = outcome else { XCTFail("Unsafe delivery must fail"); return }
                XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Original clipboard")
            }
            XCTAssertNil(fixture.pasteboard.data(forType: TextDeliveryFixture.transientType))
        }
    }

    @MainActor
    func testModifierWaitIsBoundedAndRechecksDestinationBeforeDelivery() async {
        for releases in [false, true] {
            let fixture = TextDeliveryFixture()
            defer { fixture.pasteboard.releaseGlobally() }
            fixture.modifiersHeld = true
            fixture.nativeResult = .acknowledged
            fixture.confirmationResult = .confirmed
            fixture.onPause = { [unowned fixture] in if releases { fixture.modifiersHeld = false } }

            let outcome = await fixture.transaction.deliver("Words", copying: "Words",
                strategy: .nativeSelection, clipboardUnchangedSince: fixture.holdStartCount)

            if releases {
                XCTAssertEqual(outcome, .inserted)
                XCTAssertEqual(fixture.validationReads, 2)
                XCTAssertEqual(fixture.pauses, [50_000_000])
            } else {
                guard case .failed = outcome else { XCTFail("A held shortcut must prevent delivery"); return }
                XCTAssertEqual(fixture.nativeWrites, [])
                XCTAssertEqual(fixture.pauses.reduce(0, +), 400_000_000)
            }
            XCTAssertEqual(fixture.pasteAttempts, 0)
            XCTAssertEqual(fixture.pasteboard.changeCount, fixture.holdStartCount)
        }
    }

    @MainActor
    func testUnsentPasteCopiesOnlyWhenTheHoldStartClipboardIsStillOwned() async {
        for newerCopy in [false, true] {
            let fixture = TextDeliveryFixture()
            defer { fixture.pasteboard.releaseGlobally() }
            if newerCopy { fixture.replaceClipboard(with: "Newer user copy") }
            fixture.onPaste = { _ in .unavailable }

            let outcome = await fixture.transaction.deliver("Words. ", copying: "Words.",
                strategy: .keyboardPaste, clipboardUnchangedSince: fixture.holdStartCount)

            if newerCopy {
                guard case .failed = outcome else { XCTFail("An unsent paste must preserve the newer copy"); return }
            } else {
                XCTAssertEqual(outcome, .copied(reason: "Copied to clipboard"))
            }
            XCTAssertEqual(fixture.confirmationReads, 0)
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), newerCopy ? "Newer user copy" : "Words.")
            XCTAssertNil(fixture.pasteboard.data(forType: TextDeliveryFixture.transientType))
        }
    }

    @MainActor
    func testCancellationBeforeOrAfterDispatchCannotPromoteClipboardBackupOrClaimInsertion() async {
        for afterDispatch in [false, true] {
            let fixture = TextDeliveryFixture()
            defer { fixture.pasteboard.releaseGlobally() }
            fixture.confirmationResult = .confirmed
            fixture.onValidate = { _ in
                if !afterDispatch { withUnsafeCurrentTask { $0?.cancel() } }
                return .valid
            }
            fixture.onPaste = { canDispatch in
                XCTAssertTrue(canDispatch())
                withUnsafeCurrentTask { $0?.cancel() }
                return .sent
            }
            let task = Task { @MainActor in
                await fixture.transaction.deliver("Cancelled words", copying: "Cancelled words",
                    strategy: .keyboardPaste, clipboardUnchangedSince: fixture.holdStartCount)
            }
            let outcome = await task.value

            if afterDispatch {
                XCTAssertEqual(outcome, .unconfirmed(clipboardBackup: false))
            } else {
                guard case .failed = outcome else { XCTFail("Cancelled delivery must fail"); return }
                XCTAssertEqual(fixture.pasteboard.changeCount, fixture.holdStartCount)
            }
            XCTAssertEqual(fixture.pasteAttempts, afterDispatch ? 1 : 0)
            XCTAssertEqual(fixture.confirmationReads, 0)
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Original clipboard")
            XCTAssertNil(fixture.pasteboard.data(forType: TextDeliveryFixture.transientType))
        }
    }

    @MainActor
    func testBlockedPasteDispatchRestoresTemporaryClipboardWithoutPromotingBackup() async {
        let fixture = TextDeliveryFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.onPaste = { _ in .blocked(reason: "Paste is no longer permitted") }

        let outcome = await fixture.transaction.deliver("Private words", copying: "Private words",
            strategy: .keyboardPaste, clipboardUnchangedSince: fixture.holdStartCount)

        XCTAssertEqual(outcome, .failed(reason: "Paste is no longer permitted"))
        XCTAssertEqual(fixture.pasteAttempts, 1)
        XCTAssertEqual(fixture.confirmationReads, 0)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Original clipboard")
        XCTAssertNil(fixture.pasteboard.data(forType: TextDeliveryFixture.transientType))
    }

    @MainActor
    func testClipboardChangeDuringDispatchPreparationPreventsPasteAndPreservesNewerCopy() async {
        let fixture = TextDeliveryFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        var dispatched = 0
        fixture.onPaste = { [unowned fixture] canDispatch in
            XCTAssertTrue(canDispatch(), "The staged transcript is initially owned")
            // Simulate a user copy while the adapter reads AX/menu metadata.
            fixture.replaceClipboard(with: "Newer user copy")
            guard canDispatch() else { return .blocked(reason: "Clipboard changed before dispatch") }
            dispatched += 1
            return .sent
        }

        let outcome = await fixture.transaction.deliver("Words. ", copying: "Words.",
            strategy: .keyboardPaste, clipboardUnchangedSince: fixture.holdStartCount)

        XCTAssertEqual(outcome, .failed(reason: "Clipboard changed before dispatch"))
        XCTAssertEqual(fixture.pasteAttempts, 1)
        XCTAssertEqual(dispatched, 0)
        XCTAssertEqual(fixture.confirmationReads, 0)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Newer user copy")
        XCTAssertNil(fixture.pasteboard.data(forType: TextDeliveryFixture.transientType))
    }

    @MainActor
    func testBlockedConfirmationNeverCreatesPersistentBackup() async {
        for strategy in [TextDeliveryStrategy.nativeSelection, .keyboardPaste] {
            let fixture = TextDeliveryFixture()
            defer { fixture.pasteboard.releaseGlobally() }
            fixture.nativeResult = .acknowledged
            fixture.confirmationResult = .blocked

            let outcome = await fixture.transaction.deliver("Private words", copying: "Private words",
                strategy: strategy, clipboardUnchangedSince: fixture.holdStartCount)

            XCTAssertEqual(outcome, .unconfirmed(clipboardBackup: false))
            XCTAssertEqual(fixture.pauses, [], "Unsafe confirmation stops immediately instead of extending the paste grace")
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Original clipboard")
            XCTAssertNil(fixture.pasteboard.data(forType: TextDeliveryFixture.transientType))
        }
    }

    @MainActor
    func testExplicitCopyCanReplaceClipboardWithoutTheAutomaticCopyGuard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Existing clipboard", forType: .string)
        try DictationClipboard.copy("Explicitly copied words", to: pasteboard).get()
        XCTAssertEqual(pasteboard.string(forType: .string), "Explicitly copied words")
    }

    @MainActor
    func testClipboardRestoresEveryRepresentationWithoutTouchingGeneralClipboard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("Original clipboard", forType: .string)
        let richText = Data("{\\rtf1 Original clipboard}".utf8)
        item.setData(richText, forType: .rtf)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let snapshot = try ClipboardSnapshot.capture(pasteboard).get()
        pasteboard.clearContents()
        pasteboard.setString("Temporary transcript", forType: .string)
        snapshot.restore(on: pasteboard, onlyIfUnchangedSince: pasteboard.changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
        XCTAssertEqual(pasteboard.data(forType: .rtf), richText)
    }

    @MainActor
    func testClipboardRestorationDoesNotOverwriteNewUserCopy() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Original clipboard", forType: .string)
        let snapshot = try ClipboardSnapshot.capture(pasteboard).get()
        pasteboard.clearContents()
        pasteboard.setString("Temporary transcript", forType: .string)
        let transcriptChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("The user's newer copy", forType: .string)
        snapshot.restore(on: pasteboard, onlyIfUnchangedSince: transcriptChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "The user's newer copy")
    }
}

/// No AX lookups, posted events, real delays, or access to the general clipboard.
@MainActor
private final class TextDeliveryFixture {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    let pasteboard: NSPasteboard
    let holdStartCount: Int
    var validation: TargetValidation = .valid
    var nativeResult: NativeTextWrite = .unsupported
    var confirmationResult: DeliveryConfirmation = .pending
    var modifiersHeld = false
    var onValidate: ((Int) -> TargetValidation)?
    var onPaste: ((_ canDispatch: () -> Bool) -> PasteDispatch)?
    var onConfirmation: ((Int) -> DeliveryConfirmation)?
    var onPause: (() -> Void)?
    var validationReads = 0
    var nativeWrites: [String] = []
    var pasteAttempts = 0
    var confirmationReads = 0
    var pauses: [UInt64] = []

    init() {
        pasteboard = .withUniqueName()
        pasteboard.setString("Original clipboard", forType: .string)
        holdStartCount = pasteboard.changeCount
    }

    func replaceClipboard(with text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    var transaction: TextDeliveryTransaction {
        TextDeliveryTransaction(pasteboard: pasteboard, environment: TextDeliveryEnvironment(
            validate: { [self] in
                validationReads += 1
                return onValidate?(validationReads) ?? validation
            },
            modifiersAreHeld: { [self] in modifiersHeld },
            replaceSelection: { [self] text in
                nativeWrites.append(text)
                return nativeResult
            },
            postPaste: { [self] canDispatch in
                pasteAttempts += 1
                return onPaste?(canDispatch) ?? (canDispatch() ? .sent : .blocked(reason: "Dispatch was interrupted"))
            },
            confirmation: { [self] _ in
                confirmationReads += 1
                return onConfirmation?(confirmationReads) ?? confirmationResult
            },
            pause: { [self] nanoseconds in
                pauses.append(nanoseconds)
                onPause?()
                try Task.checkCancellation()
            }
        ))
    }
}

/// Synthetic PCM and a controllable driver-start gate; never opens hardware.
private final class FakeRecorderHardware: AudioCaptureHardware, @unchecked Sendable {
    private let lock = NSLock()
    private let entered: XCTestExpectation?
    private let gate: DispatchSemaphore?
    private let capturesBeforeGate: Bool
    private var request: AudioCaptureRequest?
    private var writer: RecordingWriter?
    private var levelCallback: (@Sendable (Float) -> Void)?
    private var interruptionCallback: (@Sendable (String) -> Void)?
    private var selected: AudioDeviceID?
    private var opens = 0
    private var stops = 0
    private var touchedMainThread = false

    private let startupError: Error?

    init(entered: XCTestExpectation? = nil, gate: DispatchSemaphore? = nil, capturesBeforeGate: Bool = false, startupError: Error? = nil) {
        self.startupError = startupError
        self.entered = entered
        self.gate = gate
        self.capturesBeforeGate = capturesBeforeGate
    }

    var captureRequest: AudioCaptureRequest? { lock.withLock { request } }
    var selectedDevice: AudioDeviceID? { lock.withLock { selected } }
    var openCount: Int { lock.withLock { opens } }
    var stopCount: Int { lock.withLock { stops } }
    var observedMainThread: Bool { lock.withLock { touchedMainThread } }

    func start(request: AudioCaptureRequest, deviceID: AudioDeviceID?, preserveOriginalAudio: Bool,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable (String) -> Void) throws {
        lock.withLock {
            self.request = request
            selected = deviceID
            levelCallback = onLevel
            interruptionCallback = onInterruption
            touchedMainThread = touchedMainThread || Thread.isMainThread
        }
        if let startupError { throw startupError }
        if capturesBeforeGate { try open(request: request, preserveOriginalAudio: preserveOriginalAudio) }
        entered?.fulfill()
        if let gate, gate.wait(timeout: .now() + 3) == .timedOut {
            throw AudioRecordingError.processing("Synthetic startup gate timed out")
        }
        if !capturesBeforeGate { try open(request: request, preserveOriginalAudio: preserveOriginalAudio) }
        guard !request.isCancelled else { throw AudioRecordingError.cancelled }
    }

    private func open(request: AudioCaptureRequest, preserveOriginalAudio: Bool) throws {
        try request.requireOpen()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        // Meter callbacks are explicitly driven by each test; PCM writing and
        // callback-order assertions must not race the independent writer queue.
        let writer = try RecordingWriter(inputFormat: format, preserveOriginalAudio: preserveOriginalAudio, onLevel: { _ in }, onError: { _ in })
        lock.withLock { self.writer = writer; opens += 1 }
        try emitPCM(frames: 8_000)
    }

    func emitPCM(frames: AVAudioFrameCount) throws {
        let (request, writer) = lock.withLock { (self.request, self.writer) }
        guard let request, request.acceptsAudio, let writer else { return }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0.1, count: Int(frames))
        writer.append(buffer)
    }

    func emitLevel(_ value: Float) { lock.withLock { levelCallback }?(value) }
    func emitInterruption(_ message: String) { lock.withLock { interruptionCallback }?(message) }

    func stop() -> RecordingWriter? {
        lock.withLock {
            touchedMainThread = touchedMainThread || Thread.isMainThread
            stops += 1
            let current = writer
            writer = nil
            return current
        }
    }

    func cancel() {
        let current = lock.withLock {
            touchedMainThread = touchedMainThread || Thread.isMainThread
            let current = writer
            writer = nil
            return current
        }
        current?.cancel()
    }
}

private final class FakeRecorderFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let captures: [FakeRecorderHardware]
    private var created = 0

    init(_ captures: [FakeRecorderHardware]) { self.captures = captures }
    var createdCount: Int { lock.withLock { created } }

    var worker: AudioCaptureWorker {
        AudioCaptureWorker(makeHardware: { [self] _ in
            let index = lock.withLock { let index = created; created += 1; return index }
            guard index < captures.count else {
                XCTFail("Unexpected hardware creation")
                return captures[captures.count - 1]
            }
            return captures[index]
        })
    }
}


/// All operations below are synthetic, including the opaque handle. No call
/// forwards to Core Audio. Callbacks run synchronously on each test's thread.
private final class FakeInputAudioUnitDriver: @unchecked Sendable {
    var events: [String] = []
    var streamFormatWrites: [String] = []
    var errors: [OSStatus] = []
    var hardware: AudioStreamBasicDescription = {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        return withExtendedLifetime(format) { format.streamDescription.pointee }
    }()
    var clientFormat: AudioStreamBasicDescription?
    var selectedDevice: AudioDeviceID = 0
    var maximumFrames: UInt32 = 4_096
    var running = false
    var initializeResult: OSStatus = noErr
    var startResult: OSStatus = noErr
    var renderResult: OSStatus = noErr
    var renderCount = 0
    var onInitialize: (() -> Void)?
    var onStop: (() -> Void)?
    private var callback: AURenderCallbackStruct?

    var operations: InputAudioUnitOperations {
        InputAudioUnitOperations(create: { [self] in events.append("create"); return AudioUnit(bitPattern: 0x5150)! },
            set: { [self] _, property, scope, element, data, _ in
                switch property {
                case kAudioOutputUnitProperty_EnableIO:
                    let value = data.load(as: UInt32.self)
                    if scope == kAudioUnitScope_Output && element == 0 && value == 0 { events.append("disable-output") }
                    else if scope == kAudioUnitScope_Input && element == 1 && value == 1 { events.append("enable-input") }
                    else { XCTFail("Unexpected IO direction change") }
                case kAudioOutputUnitProperty_CurrentDevice:
                    XCTAssertEqual(scope, kAudioUnitScope_Global)
                    XCTAssertEqual(element, 0)
                    selectedDevice = data.load(as: AudioDeviceID.self)
                    events.append("bind:\(selectedDevice)")
                case kAudioUnitProperty_StreamFormat:
                    streamFormatWrites.append("\(scope == kAudioUnitScope_Output ? "output" : "input"):\(element)")
                    clientFormat = data.load(as: AudioStreamBasicDescription.self)
                case kAudioUnitProperty_ShouldAllocateBuffer:
                    XCTAssertEqual(scope, kAudioUnitScope_Output)
                    XCTAssertEqual(element, 1)
                    XCTAssertEqual(data.load(as: UInt32.self), 0)
                case kAudioOutputUnitProperty_SetInputCallback:
                    XCTAssertEqual(scope, kAudioUnitScope_Global)
                    XCTAssertEqual(element, 0)
                    callback = data.load(as: AURenderCallbackStruct.self)
                default: XCTFail("Unexpected property write \(property)")
                }
                return noErr
            }, get: { [self] _, property, scope, element, data, size in
                func write<T>(_ value: T) {
                    withUnsafeBytes(of: value) { bytes in
                        XCTAssertEqual(size.pointee, UInt32(bytes.count))
                        data.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
                    }
                }
                switch property {
                case kAudioUnitProperty_StreamFormat:
                    XCTAssertEqual(scope, kAudioUnitScope_Input)
                    XCTAssertEqual(element, 1)
                    write(hardware)
                case kAudioOutputUnitProperty_CurrentDevice: write(selectedDevice)
                case kAudioUnitProperty_MaximumFramesPerSlice: write(maximumFrames)
                case kAudioOutputUnitProperty_IsRunning: write(UInt32(running ? 1 : 0))
                default: XCTFail("Unexpected property read \(property)")
                }
                return noErr
            }, initialize: { [self] _ in events.append("initialize"); onInitialize?(); return initializeResult },
            start: { [self] _ in events.append("start"); running = true; return startResult },
            stop: { [self] _ in events.append("stop"); running = false; onStop?(); return noErr },
            uninitialize: { [self] _ in events.append("uninitialize"); return noErr },
            dispose: { [self] _ in events.append("dispose"); callback = nil; return noErr },
            render: { [self] _, _, _, bus, frames, buffers in
                renderCount += 1
                XCTAssertEqual(bus, 1)
                guard renderResult == noErr else { return renderResult }
                for (channel, buffer) in UnsafeMutableAudioBufferListPointer(buffers).enumerated() {
                    XCTAssertEqual(buffer.mDataByteSize, frames * 4)
                    buffer.mData!.assumingMemoryBound(to: Float.self).initialize(repeating: Float(channel + 1) * 0.1, count: Int(frames))
                }
                return noErr
            })
    }

    func emit(frames: UInt32) {
        guard let callback, let procedure = callback.inputProc, let reference = callback.inputProcRefCon else { XCTFail("No callback installed"); return }
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        XCTAssertEqual(procedure(reference, &flags, &time, 1, frames, nil), noErr)
    }
}
