import Darwin
import Foundation
import XCTest
@testable import V07Core

final class ConfigurationFileTests: XCTestCase {
    func testCreatesPrivateConfigOnlyOnce() async throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let file = ConfigurationFile(url: location.url)
        let desk = AudioInputDevice(uid: "usb:desk", name: "Desk", transport: .usb)
        let initial = V07Configuration(holdKey: "fn", launchAtLogin: true,
            microphones: MicrophonePreferences(profiles: [MicrophoneProfile(id: "desk", name: "Desk", priority: [desk])],
                                               selection: .fixed(desk)))
        let created = try await file.load(orCreate: initial).get()
        XCTAssertEqual(created, initial)
        let secondLoad = try await file.load(orCreate: .default).get()
        XCTAssertEqual(secondLoad, initial)
        XCTAssertEqual(try JSONDecoder().decode(V07Configuration.self, from: Data(contentsOf: location.url)), initial)
        XCTAssertEqual(try mode(location.url), 0o600)
        XCTAssertEqual(try mode(location.url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.url.deletingLastPathComponent().path), ["config.json"])
    }

    func testKnownMissingFieldsDefaultButExplicitNullAndInvalidTypesDoNot() throws {
        let decoder = JSONDecoder()
        for json in ["{}", #"{"microphones":{}}"#] {
            XCTAssertEqual(try decoder.decode(V07Configuration.self, from: Data(json.utf8)), .default)
        }
        for json in [
            "[]", "null", #"{"holdKey":null}"#, #"{"holdKey":1}"#,
            #"{"schemaVersion":2}"#, #"{"schemaVersion":true}"#, #"{"holdKey":"function"}"#,
            #"{"launchAtLogin":"true"}"#, #"{"launchAtLogin":null}"#,
        ] {
            XCTAssertThrowsError(try decoder.decode(V07Configuration.self, from: Data(json.utf8)), json)
        }
    }

    func testStrictMicrophoneValidationDoesNotSilentlyDiscardBadManualEdits() throws {
        let invalidMicrophones = [
            "null", "[]", #"{"profiles":false}"#, #"{"profiles":[]}"#,
            #"{"profiles":[{"id":"","name":"Desk"}]}"#,
            #"{"profiles":[{"id":"desk"},{"id":"desk"}]}"#,
            #"{"profiles":[{"id":"desk","priority":[42]}]}"#,
            #"{"profiles":[{"id":"desk","priority":[{"uid":" "}]}]}"#,
            #"{"profiles":[{"id":"desk","priority":[{"uid":"a"},{"uid":"a"}]}]}"#,
            #"{"profiles":[{"id":"desk","priority":[{"uid":"a","transport":"typo"}]}]}"#,
            #"{"activeProfileID":"missing"}"#,
            #"{"selection":{"mode":"typo"}}"#,
            #"{"selection":{"mode":"fixed"}}"#,
            #"{"selection":{"mode":"fixed","device":{"name":"No UID"}}}"#,
        ]
        for microphones in invalidMicrophones {
            let data = Data("{\"microphones\":\(microphones)}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(V07Configuration.self, from: data), microphones)
        }
        let valid = Data(#"{"microphones":{"profiles":[{"id":"desk","priority":[{"uid":"usb:desk"}]}],"selection":{"mode":"systemDefault"}}}"#.utf8)
        let decoded = try JSONDecoder().decode(V07Configuration.self, from: valid)
        XCTAssertEqual(decoded.microphones.activeProfileID, "desk")
        XCTAssertEqual(decoded.microphones.activeProfile.priority.first?.name, "Microphone")
        XCTAssertEqual(decoded.microphones.selection, .systemDefault)
    }

    func testUpdatesMergeChangedFieldsWithLatestExternalEditAndPreserveUnknownFields() async throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let file = ConfigurationFile(url: location.url)
        let initial = try await file.load(orCreate: .default).get()
        var external = try json(location.url)
        external["holdKey"] = "fn"
        external["futureOption"] = ["nested": [1, 2, 3], "enabled": true]
        let microphones = try XCTUnwrap(external["microphones"] as? [String: Any])
        var extendedMicrophones = microphones
        extendedMicrophones["futureMicrophoneSetting"] = "retained"
        external["microphones"] = extendedMicrophones
        try JSONSerialization.data(withJSONObject: external).write(to: location.url, options: .atomic)
        var desired = initial
        desired.launchAtLogin = true
        let merged = try await file.update(from: initial, to: desired).get()
        XCTAssertEqual(merged.holdKey, "fn")
        XCTAssertTrue(merged.launchAtLogin)
        let written = try json(location.url)
        XCTAssertEqual((written["futureOption"] as? NSDictionary), (external["futureOption"] as? NSDictionary))
        XCTAssertEqual((written["microphones"] as? NSDictionary), (external["microphones"] as? NSDictionary))
        XCTAssertEqual(try mode(location.url), 0o600)
    }

    func testPartialFileStaysPartialAndNoOpReadsLatestWithoutRewriting() async throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.root) }
        try FileManager.default.createDirectory(at: location.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"holdKey":"fn","notes":"keep me"}"#.utf8)
        try original.write(to: location.url)
        let file = ConfigurationFile(url: location.url)
        let loaded = try await file.load(orCreate: .default).get()
        XCTAssertEqual(loaded.holdKey, "fn")
        XCTAssertEqual(try Data(contentsOf: location.url), original)
        let noOp = try await file.update(from: .default, to: .default).get()
        XCTAssertEqual(noOp.holdKey, "fn")
        XCTAssertEqual(try Data(contentsOf: location.url), original)
        var desired = loaded
        desired.launchAtLogin = true
        _ = try await file.update(from: loaded, to: desired).get()
        let written = try json(location.url)
        XCTAssertEqual(written.keys.sorted(), ["holdKey", "launchAtLogin", "notes"])
    }

    func testInvalidExistingFileIsUntouchedByLoadAndUpdate() async throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let file = ConfigurationFile(url: location.url)
        _ = try await file.load(orCreate: .default).get()
        var changed = V07Configuration.default
        changed.holdKey = "fn"
        for invalid in ["{", #"{"holdKey":"typo"}"#, #"{"microphones":{"profiles":null}}"#] {
            let bytes = Data(invalid.utf8)
            try bytes.write(to: location.url)
            assertInvalid(await file.load(orCreate: changed))
            assertInvalid(await file.read())
            assertInvalid(await file.update(from: .default, to: changed))
            XCTAssertEqual(try Data(contentsOf: location.url), bytes)
        }
    }

    func testReadAndUpdateDoNotCreateADeletedConfigOrFolder() async throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let file = ConfigurationFile(url: location.url)
        let absentRead = await file.read()
        XCTAssertEqual(absentRead, .failure(.missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.url.deletingLastPathComponent().path))
        let initial = try await file.load(orCreate: .default).get()
        try FileManager.default.removeItem(at: location.url)
        var changed = initial
        changed.holdKey = "fn"
        let absentUpdate = await file.update(from: initial, to: changed)
        XCTAssertEqual(absentUpdate, .failure(.missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.url.path))
    }

    func testSymlinkRootAndConfigAreRejectedWithoutTouchingTargets() async throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let target = location.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let targetFile = target.appendingPathComponent("config.json")
        let bytes = Data("{}".utf8)
        try bytes.write(to: targetFile)
        let configRoot = location.url.deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: configRoot, withDestinationURL: target)
        let file = ConfigurationFile(url: location.url)
        assertUnsafe(await file.load(orCreate: .default))
        assertUnsafe(await file.read())
        try FileManager.default.removeItem(at: configRoot)
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: location.url, withDestinationURL: targetFile)
        assertUnsafe(await file.load(orCreate: .default))
        assertUnsafe(await file.read())
        XCTAssertEqual(try Data(contentsOf: targetFile), bytes)
    }

    func testNonregularAndOversizedFilesAreRejectedWithoutBlockingOrReplacing() async throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let file = ConfigurationFile(url: location.url)
        try FileManager.default.createDirectory(at: location.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(location.url.path, mode_t(0o600)), 0)
        assertUnsafe(await file.read())
        try FileManager.default.removeItem(at: location.url)
        let oversized = Data(repeating: 0x20, count: ConfigurationFile.maximumFileSize + 1)
        try oversized.write(to: location.url)
        assertInvalid(await file.read())
        assertInvalid(await file.load(orCreate: .default))
        XCTAssertEqual(try Data(contentsOf: location.url).count, oversized.count)
    }

    func testInvalidAppUpdateDoesNotChangeConfigAndExternalAtomicReplacementIsReadable() async throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let file = ConfigurationFile(url: location.url)
        let initial = try await file.load(orCreate: .default).get()
        let original = try Data(contentsOf: location.url)
        var invalid = initial
        invalid.holdKey = "typo"
        assertInvalid(await file.update(from: initial, to: invalid))
        XCTAssertEqual(try Data(contentsOf: location.url), original)
        let replacement = V07Configuration(holdKey: "fn", launchAtLogin: true)
        try JSONEncoder().encode(replacement).write(to: location.url, options: .atomic)
        let refreshed = try await file.read().get()
        XCTAssertEqual(refreshed, replacement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.url.deletingLastPathComponent().path), ["config.json"])
    }

    private func fixture() throws -> (root: URL, url: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("V07-config-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, root.appendingPathComponent("V07 Dev", isDirectory: true).appendingPathComponent("config.json"))
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func assertInvalid(_ result: Result<V07Configuration, ConfigurationFileError>,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(.invalid) = result else {
            XCTFail("Expected invalid configuration, received \(result)", file: file, line: line)
            return
        }
    }

    private func assertUnsafe(_ result: Result<V07Configuration, ConfigurationFileError>,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(.unsafePath) = result else {
            XCTFail("Expected unsafe path, received \(result)", file: file, line: line)
            return
        }
    }
}
