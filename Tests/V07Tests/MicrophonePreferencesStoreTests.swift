import Foundation
import V07Core
import XCTest
@testable import V07

final class MicrophonePreferencesStoreTests: XCTestCase {
    private let builtIn = AudioInputDevice(uid: "builtin", name: "Mac microphone", transport: .builtIn)
    private let usb = AudioInputDevice(uid: "usb", name: "Desk microphone", transport: .usb)
    private let headset = AudioInputDevice(uid: "headset", name: "Headset", transport: .bluetooth)

    func testPreferredDeviceReturnsWithoutLosingSavedOrder() async throws {
        try await withPreferences { store, fixture in
            store.update(devices: [builtIn, usb], systemDefaultUID: builtIn.uid)
            store.addToPriority(usb)
            store.addToPriority(builtIn)
            XCTAssertEqual(store.resolution.device, usb)
            store.update(devices: [builtIn], systemDefaultUID: builtIn.uid)
            XCTAssertEqual(store.resolution.device, builtIn)
            XCTAssertEqual(store.activeProfile.priority.map(\.uid), [usb.uid, builtIn.uid])

            let restored = await fixture.restoredStore()
            restored.update(devices: [builtIn, usb], systemDefaultUID: builtIn.uid)
            XCTAssertEqual(restored.resolution.device, usb)
            XCTAssertEqual(restored.activeProfile.priority, store.activeProfile.priority)
        }
    }

    func testDragMoveAndKeyboardMovePersistWithoutAffectingOtherProfiles() async throws {
        try await withPreferences { store, fixture in
            [builtIn, usb, headset].forEach(store.addToPriority)
            store.movePriority(fromOffsets: IndexSet(integer: 2), toOffset: 0)
            XCTAssertEqual(store.activeProfile.priority.map(\.uid), [headset.uid, builtIn.uid, usb.uid])
            store.movePriority(uid: usb.uid, by: -1)
            XCTAssertEqual(store.activeProfile.priority.map(\.uid), [headset.uid, usb.uid, builtIn.uid])
            let firstProfile = store.activeProfile

            try store.addProfile(named: "Travel").get()
            store.addToPriority(builtIn)
            store.addToPriority(headset)
            store.movePriority(fromOffsets: IndexSet(integer: 0), toOffset: 2)
            XCTAssertEqual(store.activeProfile.priority.map(\.uid), [headset.uid, builtIn.uid])

            let restored = await fixture.restoredStore()
            XCTAssertEqual(restored.activeProfile.name, "Travel")
            restored.selectProfile(firstProfile.id)
            XCTAssertEqual(restored.activeProfile, firstProfile)
        }
    }

    func testMultipleRowMovesUseListDestinationSemanticsAndIgnoreBadOffsets() async throws {
        try await withPreferences { store, _ in
            [builtIn, usb, headset].forEach(store.addToPriority)
            store.movePriority(fromOffsets: IndexSet([0, 2]), toOffset: 3)
            XCTAssertEqual(store.activeProfile.priority, [usb, builtIn, headset])
            let before = store.preferences
            store.movePriority(fromOffsets: IndexSet(integer: 20), toOffset: 0)
            store.movePriority(fromOffsets: IndexSet(integer: 0), toOffset: 20)
            store.movePriority(uid: usb.uid, by: -1)
            XCTAssertEqual(store.preferences, before)
        }
    }

    func testFixedSelectionStaysSelectedDuringFallbackAndDeviceRename() async throws {
        try await withPreferences { store, fixture in
            store.select(.fixed(usb))
            store.update(devices: [builtIn], systemDefaultUID: builtIn.uid)
            XCTAssertEqual(store.preferences.selection, .fixed(usb))
            XCTAssertEqual(store.resolution.device, builtIn)

            let renamed = AudioInputDevice(uid: usb.uid, name: "USB studio mic", transport: .usb)
            store.update(devices: [builtIn, renamed], systemDefaultUID: builtIn.uid)
            XCTAssertEqual(store.resolution.device, renamed)
            let restored = await fixture.restoredStore()
            XCTAssertEqual(restored.preferences.selection, .fixed(renamed))
            store.select(.systemDefault)
            XCTAssertEqual(store.resolution.device, builtIn)
        }
    }

    func testProfileEditsRejectAmbiguityAndPreserveAtLeastOneList() async throws {
        try await withPreferences { store, _ in
            let firstID = store.activeProfile.id
            XCTAssertThrowsError(try store.addProfile(named: " ").get())
            XCTAssertThrowsError(try store.addProfile(named: "default").get())
            XCTAssertThrowsError(try store.removeProfile(firstID).get())
            try store.addProfile(named: "Travel").get()
            let travelID = store.activeProfile.id
            try store.renameProfile(travelID, to: "  On the go  ").get()
            XCTAssertEqual(store.activeProfile.name, "On the go")
            XCTAssertThrowsError(try store.renameProfile(travelID, to: "Default").get())
            try store.removeProfile(travelID).get()
            XCTAssertEqual(store.activeProfile.id, firstID)
        }
    }

    func testExternalMicrophoneConfigurationUpdatesSelectionWithoutWritingBack() async throws {
        try await withPreferences { store, fixture in
            store.update(devices: [builtIn, usb], systemDefaultUID: builtIn.uid)
            var external = fixture.configuration.configuration
            external.microphones = MicrophonePreferences(
                profiles: [MicrophoneProfile(id: "desk", name: "Desk", priority: [usb, builtIn])],
                activeProfileID: "desk", selection: .fixed(usb)
            )
            external.holdKey = "fn"
            let bytes = try JSONEncoder().encode(external)
            try bytes.write(to: fixture.file.url, options: .atomic)
            await fixture.configuration.reload()

            XCTAssertEqual(store.preferences, external.microphones)
            XCTAssertEqual(store.resolution.device, usb)
            await fixture.configuration.flush()
            XCTAssertEqual(try Data(contentsOf: fixture.file.url), bytes, "Applying external values must not write them back")

            store.select(.automatic)
            await fixture.configuration.flush()
            let saved = try await fixture.file.read().get()
            XCTAssertEqual(saved.microphones.selection, .automatic)
            XCTAssertEqual(saved.microphones.activeProfile.priority, [usb, builtIn])
            XCTAssertEqual(saved.holdKey, "fn")
        }
    }

    func testInvalidExternalConfigurationKeepsLastSelectionAndShowsStorageErrorUntilRepair() async throws {
        try await withPreferences { store, fixture in
            store.select(.fixed(usb))
            await fixture.configuration.flush()
            let valid = fixture.configuration.configuration
            try Data("not JSON".utf8).write(to: fixture.file.url, options: .atomic)
            await fixture.configuration.reload()
            XCTAssertEqual(store.preferences.selection, .fixed(usb))
            XCTAssertNotNil(store.storageError)

            try JSONEncoder().encode(valid).write(to: fixture.file.url, options: .atomic)
            await fixture.configuration.reload()
            XCTAssertEqual(store.preferences.selection, .fixed(usb))
            XCTAssertNil(store.storageError)
        }
    }

    @MainActor
    private func withPreferences(_ operation: @MainActor (MicrophonePreferencesStore, MicrophoneConfigurationFixture) async throws -> Void) async throws {
        let suite = "V07MicrophoneTests.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let file = ConfigurationFile(url: root.appendingPathComponent("config.json"))
        let configuration = ConfigurationStore(file: file)
        await configuration.start()
        configuration.stopWatching()
        let fixture = MicrophoneConfigurationFixture(configuration: configuration, file: file)
        do { try await operation(MicrophonePreferencesStore(configuration: configuration), fixture) }
        catch { await fixture.flush(); throw error }
        await fixture.flush()
    }
}

@MainActor
private final class MicrophoneConfigurationFixture {
    let configuration: ConfigurationStore
    let file: ConfigurationFile
    private var restoredConfigurations: [ConfigurationStore] = []

    init(configuration: ConfigurationStore, file: ConfigurationFile) {
        self.configuration = configuration
        self.file = file
    }

    func restoredStore() async -> MicrophonePreferencesStore {
        await flush()
        let restored = ConfigurationStore(file: file)
        await restored.start()
        restored.stopWatching()
        restoredConfigurations.append(restored)
        return MicrophonePreferencesStore(configuration: restored)
    }

    func flush() async {
        await configuration.flush()
        for restored in restoredConfigurations { await restored.flush() }
    }
}
