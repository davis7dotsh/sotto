import Foundation
import XCTest
@testable import V07Core

final class MicrophonePreferencesTests: XCTestCase {
    private let desk = AudioInputDevice(uid: "usb:desk", name: "Desk microphone", transport: .usb)
    private let headset = AudioInputDevice(uid: "bluetooth:headset", name: "Headset", transport: .bluetooth)
    private let builtIn = AudioInputDevice(uid: "builtin:mac", name: "Mac microphone", transport: .builtIn)

    func testAutomaticReclaimsHigherPriorityOnReconnectWithoutForgettingIt() {
        let preferences = preferences(priority: [desk, headset, builtIn])
        let disconnected = resolve(preferences, available: [builtIn, headset])
        XCTAssertEqual(disconnected.device, headset)
        XCTAssertEqual(disconnected.reason, .priority)
        XCTAssertEqual(resolve(preferences, available: [builtIn, desk, headset]).device, desk)
        XCTAssertEqual(resolve(preferences, available: [builtIn]).device, builtIn)
        XCTAssertEqual(preferences.activeProfile.priority, [desk, headset, builtIn])
    }

    func testEmptyPriorityFollowsSystemDefault() {
        let result = resolve(MicrophonePreferences(), available: [headset, builtIn, desk])
        XCTAssertEqual(result.device, builtIn)
        XCTAssertEqual(result.reason, .systemDefault)
        XCTAssertEqual(resolve(MicrophonePreferences(), available: [builtIn, desk], systemDefaultUID: desk.uid).device, desk)
    }

    func testMissingFavoritesFallBackToSystemThenStableUIDOrder() {
        let preferences = preferences(priority: [desk])
        XCTAssertEqual(resolve(preferences, available: [headset, builtIn]).device, builtIn)
        let first = resolve(preferences, available: [headset, builtIn], systemDefaultUID: "missing")
        let reordered = resolve(preferences, available: [builtIn, headset], systemDefaultUID: nil)
        XCTAssertEqual(first, reordered)
        XCTAssertEqual(first.device, headset)
        XCTAssertEqual(first.reason, .fallback(requested: nil))
    }

    func testFixedDeviceReturnsAfterFallbackAndUsesCurrentMetadata() {
        let preferences = preferences(priority: [headset], selection: .fixed(desk))
        XCTAssertEqual(resolve(preferences, available: [builtIn, desk]).reason, .fixed)
        let fallback = resolve(preferences, available: [builtIn, headset])
        XCTAssertEqual(fallback.device, builtIn)
        XCTAssertEqual(fallback.reason, .fallback(requested: desk))
        let renamedDesk = AudioInputDevice(uid: desk.uid, name: "Renamed desk microphone", transport: .usb)
        XCTAssertEqual(resolve(preferences, available: [builtIn, headset, renamedDesk]).device, renamedDesk)
        XCTAssertEqual(preferences.selection, .fixed(desk))
    }

    func testIdentityIsUIDNotDisplayName() {
        let lookalike = AudioInputDevice(uid: "usb:another", name: desk.name, transport: .usb)
        let preferences = preferences(priority: [desk])
        XCTAssertEqual(resolve(preferences, available: [builtIn, lookalike]).device, builtIn)
        XCTAssertEqual(resolve(preferences, available: [lookalike, desk, builtIn]).device, desk)
        XCTAssertEqual(resolve(self.preferences(priority: [], selection: .fixed(desk)), available: [lookalike]).reason,
                       .fallback(requested: desk))
    }

    func testSystemDefaultModeIgnoresPriorities() {
        let result = resolve(preferences(priority: [desk, headset], selection: .systemDefault),
                             available: [desk, headset, builtIn])
        XCTAssertEqual(result.device, builtIn)
        XCTAssertEqual(result.reason, .systemDefault)
    }

    func testProfilesAndReorderingHaveIndependentPriority() {
        var preferences = MicrophonePreferences(profiles: [
            MicrophoneProfile(id: "desk", name: "At the desk", priority: [desk, headset]),
            MicrophoneProfile(id: "away", name: "On the go", priority: [headset, builtIn]),
        ], activeProfileID: "desk")
        XCTAssertEqual(resolve(preferences, available: [builtIn, headset, desk]).device, desk)
        preferences.profiles[0].priority.swapAt(0, 1)
        XCTAssertEqual(resolve(preferences, available: [builtIn, headset, desk]).device, headset)
        XCTAssertEqual(preferences.profiles[1].priority, [headset, builtIn])
        preferences.activeProfileID = "away"
        XCTAssertEqual(resolve(preferences, available: [desk, builtIn]).device, builtIn)
        XCTAssertEqual(preferences.profiles[0].priority, [headset, desk])
    }

    func testNoInputsReturnsUnavailableForEveryMode() {
        for selection in [MicrophoneSelection.automatic, .systemDefault, .fixed(desk)] {
            let result = resolve(preferences(priority: [desk], selection: selection), available: [])
            XCTAssertNil(result.device)
            XCTAssertEqual(result.reason, .unavailable)
        }
    }

    func testNormalizationKeepsFirstDuplicateUIDWithoutChangingPriority() {
        let renamedDuplicate = AudioInputDevice(uid: desk.uid, name: "Old name", transport: .other)
        let invalid = AudioInputDevice(uid: "  ", name: "Invalid", transport: .usb)
        let result = preferences(priority: [desk, invalid, headset, renamedDuplicate, builtIn]).normalized()
        XCTAssertEqual(result.activeProfile.priority, [desk, headset, builtIn])
        XCTAssertEqual(result.normalized(), result)
    }

    func testDeletingActiveOrLastProfileLeavesUsableDefaults() {
        var preferences = MicrophonePreferences(profiles: [
            MicrophoneProfile(id: "desk", name: "Desk", priority: [desk]),
            MicrophoneProfile(id: "away", name: "Away", priority: [headset]),
        ], activeProfileID: "away")
        preferences.profiles.removeLast()
        preferences = preferences.normalized()
        XCTAssertEqual(preferences.activeProfileID, "desk")
        preferences.profiles.removeAll()
        preferences = preferences.normalized()
        XCTAssertEqual(preferences, MicrophonePreferences())
        XCTAssertEqual(resolve(preferences, available: [builtIn]).device, builtIn)
    }

    func testNormalizationRepairsInvalidIdentitySelectionAndNames() {
        let invalidDevice = AudioInputDevice(uid: "", name: "Invalid", transport: .usb)
        let result = MicrophonePreferences(profiles: [
            MicrophoneProfile(id: "", name: "Invalid", priority: [desk]),
            MicrophoneProfile(id: "valid", name: " \n ", priority: [headset]),
            MicrophoneProfile(id: "valid", name: "Duplicate", priority: [desk]),
        ], activeProfileID: "not-a-profile", selection: .fixed(invalidDevice))
        XCTAssertEqual(result.profiles.count, 1)
        XCTAssertEqual(result.activeProfile.name, "Default")
        XCTAssertEqual(result.activeProfile.priority, [headset])
        XCTAssertEqual(result.activeProfileID, "valid")
        XCTAssertEqual(result.selection, .automatic)
    }

    func testAllSelectionModesAndOfflineProfilesSurvivePersistence() throws {
        for selection in [MicrophoneSelection.automatic, .systemDefault, .fixed(desk)] {
            let original = MicrophonePreferences(profiles: [
                MicrophoneProfile(id: "desk", name: "At the desk", priority: [desk, builtIn]),
                MicrophoneProfile(id: "away", name: "On the go", priority: [headset, builtIn]),
            ], activeProfileID: "away", selection: selection)
            let data = try JSONEncoder().encode(original)
            XCTAssertEqual(try JSONDecoder().decode(MicrophonePreferences.self, from: data), original)
        }
    }

    func testCorruptedEntriesDoNotEraseValidSavedProfiles() throws {
        let data = Data(#"""
        {
          "profiles": [
            null,
            {"id": "desk", "name": " Desk ", "priority": [
              {"uid": "usb:desk", "name": "Desk microphone", "transport": "futureTransport"},
              42,
              {"name": "No UID"},
              {"uid": "usb:desk", "name": "Duplicate"},
              {"uid": "bluetooth:headset", "name": "Headset", "transport": "bluetooth"}
            ]},
            {"id": "away", "name": "Away", "priority": "broken"}
          ],
          "activeProfileID": "missing",
          "selection": {"mode": "fixed", "device": {"uid": "", "name": "Missing"}}
        }
        """#.utf8)
        let result = try JSONDecoder().decode(MicrophonePreferences.self, from: data)
        XCTAssertEqual(result.profiles.map(\.id), ["desk", "away"])
        XCTAssertEqual(result.activeProfile.name, "Desk")
        XCTAssertEqual(result.activeProfile.priority.map(\.uid), [desk.uid, headset.uid])
        XCTAssertEqual(result.activeProfile.priority.first?.transport, .other)
        XCTAssertTrue(result.profiles[1].priority.isEmpty)
        XCTAssertEqual(result.selection, .automatic)
    }

    func testMissingAndUnknownSavedFieldsChooseSafeDefaults() throws {
        for json in ["{}", "null", "[]", #"{"profiles":false,"activeProfileID":12,"selection":{"mode":"unknown"}}"#] {
            let decoded = try JSONDecoder().decode(MicrophonePreferences.self, from: Data(json.utf8))
            XCTAssertEqual(decoded, MicrophonePreferences())
        }
    }

    private func preferences(priority: [AudioInputDevice], selection: MicrophoneSelection = .automatic) -> MicrophonePreferences {
        MicrophonePreferences(profiles: [MicrophoneProfile(id: "test", name: "Test", priority: priority)], selection: selection)
    }

    private func resolve(_ preferences: MicrophonePreferences, available: [AudioInputDevice],
                         systemDefaultUID: String? = "builtin:mac") -> MicrophoneResolution {
        MicrophoneSelectionPolicy.resolve(preferences: preferences, available: available, systemDefaultUID: systemDefaultUID)
    }
}
