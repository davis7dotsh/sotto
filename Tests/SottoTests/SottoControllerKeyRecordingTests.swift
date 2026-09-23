import CoreGraphics
import SottoCore
import XCTest
@testable import Sotto

@MainActor
final class SottoControllerKeyRecordingTests: XCTestCase {
    private final class FakeTap {
        var valid = true
        var enabled = false

        var handle: HotkeyEventTap {
            HotkeyEventTap(
                isValid: { self.valid }, isEnabled: { self.enabled },
                setEnabled: { self.enabled = $0 && self.valid },
                lifetime: HotkeyCancellation { self.valid = false }
            )
        }
    }

    private final class TapList {
        var items: [FakeTap] = []
        var latest: FakeTap? { items.last }
    }

    private func makeController(granted: Bool) -> (SottoController, TapList, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SottoControllerKeyRecordingTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = ConfigurationStore(file: ConfigurationFile(url: root.appendingPathComponent("config.json")))
        let taps = TapList()
        let monitor = HotkeyMonitor(environment: .init(
            permissions: { PermissionSnapshot(microphone: granted, accessibility: granted, inputMonitoring: false) },
            isKeyDown: { _ in false },
            flags: { [] },
            createTap: { _ in
                let tap = FakeTap()
                taps.items.append(tap)
                return tap.handle
            },
            delayPress: { _ in HotkeyCancellation {} },
            repeatingTimer: { _, _ in HotkeyCancellation {} }
        ))
        let controller = SottoController(configuration: store, startServices: false,
                                         hotkey: monitor, permissionCapture: {
            PermissionSnapshot(microphone: granted, accessibility: granted, inputMonitoring: false)
        })
        return (controller, taps, root)
    }

    func testKeyRecordingSuspendsAndRestoresTheHoldMonitor() throws {
        let (controller, taps, root) = makeController(granted: true)
        defer {
            controller.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertFalse(controller.isHotkeyActive)

        controller.refreshPermissions()
        XCTAssertTrue(controller.permissions.canListenForHotkey)
        XCTAssertTrue(controller.isHotkeyActive, "A granted fixture must start the hold monitor")
        XCTAssertEqual(taps.latest?.enabled, true)

        controller.setKeyRecording(true)
        XCTAssertTrue(controller.isRecordingKey)
        XCTAssertFalse(controller.isHotkeyActive, "Recording a key must suspend the monitor")

        controller.refreshPermissions()
        XCTAssertFalse(controller.isHotkeyActive, "A permission refresh must not re-arm a suspended monitor")

        controller.setKeyRecording(false)
        XCTAssertFalse(controller.isRecordingKey)
        XCTAssertTrue(controller.isHotkeyActive, "Stopping the recording must restore the monitor")
        XCTAssertTrue(taps.latest?.enabled ?? false, "Restoring must build a fresh, enabled tap")
    }

    func testKeyRecordingKeepsDictationEntryPointsClosed() throws {
        let (controller, _, root) = makeController(granted: true)
        defer {
            controller.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        controller.setKeyRecording(true)
        XCTAssertFalse(controller.canTest, "The microphone test must stay disabled during key capture")
        controller.toggleTestRecording()
        XCTAssertEqual(controller.activity, .idle, "A test take must not start during key capture")
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.isCapturing)
        controller.startShortcutCheck()
        XCTAssertFalse(controller.isCheckingShortcut, "A shortcut check against the suspended monitor would only record silence")
    }
}
