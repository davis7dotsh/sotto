import Combine
import Foundation
import V07Core
import XCTest
@testable import V07

final class ConfigurationStoreTests: XCTestCase {
    func testFirstStartCreatesDefaultPreferences() async throws {
        try await withStore { store, file in
            XCTAssertEqual(store.configuration, .default)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
            XCTAssertFalse(store.isLoaded)

            await store.start()

            XCTAssertTrue(store.isLoaded)
            XCTAssertNil(store.errorMessage)
            let disk = try await file.read().get()
            XCTAssertEqual(disk, store.configuration)
        }
    }

    func testExistingJSONIsLoadedAndRepeatedStartIsIdempotent() async throws {
        try await withStore { store, file in
            let expected = V07Configuration(holdKey: "rightControl", launchAtLogin: true)
            _ = try await file.load(orCreate: expected).get()

            await store.start()
            await store.start()

            XCTAssertEqual(store.configuration, expected)
            let disk = try await file.read().get()
            XCTAssertEqual(disk, expected)
            XCTAssertNil(store.errorMessage)
        }
    }

    func testRapidAppEditsAreOptimisticAndFlushPersistsTheFinalValues() async throws {
        try await withStore { store, file in
            await store.start()
            for index in 1...40 {
                store.update { $0.microphones.profiles[0].name = "Profile \(index)" }
            }
            store.update {
                $0.launchAtLogin = true
                $0.holdKey = "fn"
            }
            XCTAssertEqual(store.configuration.microphones.profiles[0].name, "Profile 40")
            XCTAssertEqual(store.configuration.holdKey, "fn")
            XCTAssertGreaterThan(store.pendingWriteCount, 0)

            await store.flush()

            XCTAssertEqual(store.pendingWriteCount, 0)
            XCTAssertNil(store.errorMessage)
            let disk = try await file.read().get()
            XCTAssertEqual(disk, store.configuration)
            XCTAssertTrue(store.configuration.launchAtLogin)
        }
    }

    func testQueuedAppEditsMergeUnrelatedExternalFieldsAndStartupEdits() async throws {
        try await withStore { store, file in
            var disk = V07Configuration.default
            disk.microphones.profiles[0].name = "External profile"
            _ = try await file.load(orCreate: disk).get()
            // An explicit early UI edit does not overwrite untouched fields from JSON.
            store.update { $0.launchAtLogin = true }
            store.update { $0.holdKey = "rightControl" }

            await store.flush()

            disk.launchAtLogin = true
            disk.holdKey = "rightControl"
            XCTAssertEqual(store.configuration, disk)
            let firstSaved = try await file.read().get()
            XCTAssertEqual(firstSaved, disk)

            store.update { $0.holdKey = "fn" }
            disk.microphones.profiles[0].name = "Another external profile"
            try Self.write(disk, to: file.url, atomically: true)
            store.update { $0.launchAtLogin = false }
            await store.flush()

            disk.holdKey = "fn"
            disk.launchAtLogin = false
            XCTAssertEqual(store.configuration, disk)
            let finalSaved = try await file.read().get()
            XCTAssertEqual(finalSaved, disk)
        }
    }

    func testWatcherReloadsInPlaceWritesAndRepeatedAtomicReplacementsWithoutReSaving() async throws {
        try await withStore { store, file in
            await store.start()
            var expected = store.configuration
            expected.microphones.profiles[0].name = "Desk"
            try Self.write(expected, to: file.url, atomically: false)
            try await Self.waitUntil { store.configuration == expected }

            expected.microphones.profiles[0].name = "Travel"
            try Self.write(expected, to: file.url, atomically: true)
            try await Self.waitUntil { store.configuration == expected }

            expected.holdKey = "fn"
            try Self.write(expected, to: file.url, atomically: true)
            try await Self.waitUntil { store.configuration == expected }
            let savedDate = try FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date
            try await Task.sleep(for: .milliseconds(400))
            let laterDate = try FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date

            XCTAssertEqual(savedDate, laterDate, "Reloading external edits must not rewrite the config")
            XCTAssertEqual(store.pendingWriteCount, 0)
            XCTAssertNil(store.errorMessage)
        }
    }

    func testInvalidExternalJSONPreservesLastGoodStateAndCannotBeClobberedByAppEdits() async throws {
        try await withStore { store, file in
            await store.start()
            let valid = store.configuration
            let invalid = Data("{ \"holdKey\": ".utf8)
            try invalid.write(to: file.url)
            try await Self.waitUntil { store.errorMessage != nil }
            XCTAssertEqual(store.configuration, valid)

            store.update { $0.holdKey = "rightControl" }
            await store.flush()
            XCTAssertEqual(try Data(contentsOf: file.url), invalid)
            XCTAssertEqual(store.configuration, valid)
            XCTAssertNotNil(store.errorMessage)

            var repaired = valid
            repaired.holdKey = "fn"
            try Self.write(repaired, to: file.url, atomically: true)
            try await Self.waitUntil { store.configuration == repaired && store.errorMessage == nil }
            XCTAssertEqual(store.pendingWriteCount, 0)
        }
    }

    func testInvalidExistingFileIsNeverReplacedWithDefaults() async throws {
        try await withStore { store, file in
            let invalid = Data("not JSON".utf8)
            try invalid.write(to: file.url)
            await store.start()
            XCTAssertTrue(store.isLoaded)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.configuration, .default)
            XCTAssertEqual(try Data(contentsOf: file.url), invalid)
        }
    }

    func testExplicitReloadDoesNotRollBackPendingUIEdits() async throws {
        try await withStore { store, file in
            await store.start()
            var observed: [String] = []
            let subscription = store.$configuration.map { $0.microphones.activeProfile.name }.removeDuplicates().dropFirst().sink { observed.append($0) }
            defer { subscription.cancel() }
            store.update { $0.microphones.profiles[0].name = "First" }
            let reload = Task { await store.reload() }
            store.update { $0.microphones.profiles[0].name = "Second" }
            store.update { $0.microphones.profiles[0].name = "Final" }
            await reload.value
            await store.flush()

            XCTAssertEqual(store.configuration.microphones.activeProfile.name, "Final")
            let disk = try await file.read().get()
            XCTAssertEqual(disk.microphones.activeProfile.name, "Final")
            XCTAssertEqual(observed, ["First", "Second", "Final"])
        }
    }

    @MainActor
    private func withStore(
        _ operation: @MainActor (ConfigurationStore, ConfigurationFile) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("V07ConfigurationStoreTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = ConfigurationFile(url: root.appendingPathComponent("config.json"))
        let store = ConfigurationStore(file: file)
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try await operation(store, file)
            await store.flush()
        } catch {
            await store.flush()
            throw error
        }
    }

    private static func write(_ configuration: V07Configuration, to url: URL, atomically: Bool) throws {
        let data = try JSONEncoder().encode(configuration)
        if atomically {
            try data.write(to: url, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
        }
    }

    @MainActor
    private static func waitUntil(_ predicate: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), "Expected configuration update was not observed", file: file, line: line)
    }
}
