import CryptoKit
import Foundation
import SQLite3
import V07API
@testable import V07
import XCTest

final class WisprFlowSourceReaderTests: XCTestCase {
    func testActiveWALSnapshotIncludesUncheckpointedRowWithoutTouchingSourceFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v07-flow-active-wal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("flow.sqlite")
        var connection: OpaquePointer?
        guard sqlite3_open(source.path, &connection) == SQLITE_OK, let connection else {
            throw NSError(domain: "WisprFlowFixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not open WAL fixture."])
        }
        defer { sqlite3_close(connection) }
        let sql = """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE History (transcriptEntityId TEXT PRIMARY KEY, timestamp TEXT, pastedText TEXT);
            INSERT INTO History VALUES ('\(Fixture.sharedID.uuidString)', '2026-01-03 12:00:00.000 +00:00', 'Uncheckpointed text');
            """
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "WisprFlowFixture", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(connection))])
        }
        let sourceFiles = [source, URL(fileURLWithPath: source.path + "-wal"), URL(fileURLWithPath: source.path + "-shm")]
        let before = try sourceFiles.map { try Data(contentsOf: $0) }

        let reader = try WisprFlowSourceReader(sourceURLs: [source])
        XCTAssertEqual(reader.sourceIDs, [Fixture.sharedID])
        XCTAssertEqual(try reader.session(for: Fixture.sharedID).displayText, "Uncheckpointed text")
        for (index, url) in sourceFiles.enumerated() { XCTAssertEqual(try Data(contentsOf: url), before[index]) }
    }

    func testClosedWALModeSourceCanBeSnapshottedAndReopened() throws {
        let fixture = try Fixture(walMode: true)
        defer { fixture.remove() }
        let live = fixture.urls[0]
        let before = try Data(contentsOf: live)
        XCTAssertEqual(before[18], 2)
        XCTAssertEqual(before[19], 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path + "-wal"))

        let reader = try WisprFlowSourceReader(sourceURLs: fixture.urls)
        XCTAssertEqual(reader.preview.sessionCount, 3)
        XCTAssertEqual(reader.sourceIDs, [Fixture.sharedID, Fixture.textOnlyID, Fixture.metadataOnlyID])
        XCTAssertEqual(try Data(contentsOf: live), before)
    }

    func testSnapshotMergesBackupMediaWithoutChangingReadOnlySources() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sourceBytes = try fixture.urls.map { try Data(contentsOf: $0) }
        let sourceDates = try fixture.urls.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let reader = try WisprFlowSourceReader(sourceURLs: fixture.urls)

        XCTAssertEqual(reader.sourceIDs, [Fixture.sharedID, Fixture.textOnlyID, Fixture.metadataOnlyID])
        let shared = try reader.session(for: Fixture.sharedID)
        XCTAssertEqual(shared.displayText, "Current pasted text")
        XCTAssertEqual(shared.rawText, "Current ASR text")
        XCTAssertEqual(Set(shared.artifacts.map(\.filename)), [.sourceJSON, .sourceWAV, .opusJSON])
        let wav = try XCTUnwrap(shared.artifacts.first(where: { $0.filename == .sourceWAV }))
        XCTAssertEqual(try Data(contentsOf: wav.url), Fixture.backupWAV)
        let source = try XCTUnwrap(shared.artifacts.first(where: { $0.filename == .sourceJSON }))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.url)) as? [String: Any])
        let versions = try XCTUnwrap(document["sources"] as? [[String: Any]])
        XCTAssertEqual(versions.count, 2)
        let current = try XCTUnwrap(versions.first?["values"] as? [String: [String: Any]])
        XCTAssertEqual(current["pastedText"]?["value"] as? String, "Current pasted text")
        XCTAssertEqual(current["duration"]?["type"] as? String, "real")
        let backup = try XCTUnwrap(versions.last?["values"] as? [String: [String: Any]])
        XCTAssertEqual(backup["audio"]?["artifact"] as? String, "source.wav")

        let textOnly = try reader.session(for: Fixture.textOnlyID)
        XCTAssertEqual(textOnly.displayText, "Finalized text only")
        XCTAssertFalse(textOnly.artifacts.contains(where: { $0.filename == .sourceWAV }))

        let metadataOnly = try reader.session(for: Fixture.metadataOnlyID)
        XCTAssertTrue(metadataOnly.displayText.isEmpty)
        XCTAssertFalse(metadataOnly.artifacts.contains(where: { $0.filename == .sourceWAV }))

        for (index, url) in fixture.urls.enumerated() {
            XCTAssertEqual(try Data(contentsOf: url), sourceBytes[index])
            XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, sourceDates[index])
        }
    }

    func testOversizedCurrentWAVStillImportsTextAndUsesSmallerBackupWithExplicitOmission() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addOversizedCurrentWAV()
        let reader = try WisprFlowSourceReader(sourceURLs: fixture.urls)
        let session = try reader.session(for: Fixture.sharedID)
        XCTAssertEqual(session.displayText, "Current pasted text")
        let wav = try XCTUnwrap(session.artifacts.first(where: { $0.filename == .sourceWAV }))
        XCTAssertEqual(try Data(contentsOf: wav.url), Fixture.backupWAV)
        let missing = try XCTUnwrap(session.unarchivedArtifacts.first(where: { $0.filename == .sourceWAV }))
        XCTAssertEqual(missing.byteCount, WisprFlowImportLimits.maximumArtifactBytes + 1)
        XCTAssertEqual(missing.sha256.count, 64)
        let source = try XCTUnwrap(session.artifacts.first(where: { $0.filename == .sourceJSON }))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.url)) as? [String: Any])
        let omissions = try XCTUnwrap(document["archiveOmissions"] as? [[String: Any]])
        XCTAssertEqual(omissions.first?["sourceName"] as? String, "live.sqlite")
        XCTAssertEqual(omissions.first?["observedSHA256"] as? String, missing.sha256)
        XCTAssertEqual(omissions.first?["observedByteCount"] as? Int, missing.byteCount)
        XCTAssertEqual(omissions.first?["reason"] as? String, "exceeds-upload-limit")
        XCTAssertEqual(omissions.first?["status"] as? String, "not-archived")

        let currentOnly = try WisprFlowSourceReader(sourceURLs: [fixture.urls[0]])
        let textOnly = try currentOnly.session(for: Fixture.sharedID)
        XCTAssertEqual(textOnly.artifacts.map(\.filename), [.sourceJSON])
        XCTAssertEqual(textOnly.unarchivedArtifacts.map(\.filename), [.sourceWAV])
        XCTAssertEqual(textOnly.displayText, "Current pasted text")
    }

    func testOversizedHistoryProvenanceKeepsTranscriptAndTypedFieldSummaries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addProvenanceFields(blobBytes: 9_000_000, textBytes: 9_000_000)
        let reader = try WisprFlowSourceReader(sourceURLs: [fixture.urls[0]])
        let session = try reader.session(for: Fixture.sharedID)
        XCTAssertEqual(session.displayText, "Current pasted text")
        XCTAssertNotNil(session.provenanceWarning)
        let source = try XCTUnwrap(session.artifacts.first(where: { $0.filename == .sourceJSON }))
        let data = try Data(contentsOf: source.url)
        XCTAssertLessThanOrEqual(data.count, WisprFlowImportLimits.maximumArtifactBytes)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["provenanceStatus"] as? String, "partial")
        XCTAssertEqual(document["provenanceOmittedFieldCount"] as? Int, 2)
        XCTAssertEqual(document["provenanceOmittedSourceCount"] as? Int, 0)
        XCTAssertEqual(document["provenanceOmittedMediaVersionCount"] as? Int, 0)
        let sources = try XCTUnwrap(document["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.count, 1)
        let values = try XCTUnwrap(sources[0]["values"] as? [String: [String: Any]])
        XCTAssertEqual(values["pastedText"]?["value"] as? String, "Current pasted text")
        XCTAssertEqual(values["extraPayload"]?["type"] as? String, "blob")
        XCTAssertEqual(values["extraPayload"]?["byteCount"] as? Int, 9_000_000)
        XCTAssertNil(values["extraPayload"]?["base64"])
        XCTAssertEqual(values["extraPayload"]?["sha256"] as? String,
                       Self.digest(Data(repeating: 0, count: 9_000_000)))
        XCTAssertEqual(values["longNote"]?["type"] as? String, "text")
        XCTAssertEqual(values["longNote"]?["byteCount"] as? Int, 9_000_000)
        XCTAssertNil(values["longNote"]?["value"])
        XCTAssertEqual(values["longNote"]?["sha256"] as? String,
                       Self.digest(Data(repeating: 0x6e, count: 9_000_000)))
        for name in ["extraPayload", "longNote"] {
            XCTAssertEqual(values[name]?["archiveStatus"] as? String, "not-archived")
            XCTAssertEqual(values[name]?["archiveReason"] as? String, "exceeds-source-json-limit")
        }
    }

    func testSourceArchiveCompactsLargeBlobBeforeSmallTextAndRetainsSourceColumns() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addProvenanceFields(blobBytes: 5_000_000, textBytes: 2_000_000)
        let reader = try WisprFlowSourceReader(sourceURLs: [fixture.urls[0]])
        let session = try reader.session(for: Fixture.sharedID)
        let source = try XCTUnwrap(session.artifacts.first(where: { $0.filename == .sourceJSON }))
        let data = try Data(contentsOf: source.url)
        XCTAssertLessThanOrEqual(data.count, WisprFlowImportLimits.maximumArtifactBytes)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["provenanceStatus"] as? String, "partial")
        XCTAssertEqual(document["provenanceOmittedFieldCount"] as? Int, 1)
        let sources = try XCTUnwrap(document["sources"] as? [[String: Any]])
        let values = try XCTUnwrap(sources[0]["values"] as? [String: [String: Any]])
        XCTAssertEqual(values["extraPayload"]?["byteCount"] as? Int, 5_000_000)
        XCTAssertEqual(values["extraPayload"]?["archiveReason"] as? String, "exceeds-source-json-limit")
        XCTAssertEqual((values["longNote"]?["value"] as? String)?.utf8.count, 2_000_000)
        XCTAssertEqual(session.displayText, "Current pasted text")
    }

    func testCanonicalSourceSummaryCountCoversAllOmittedValuesAndColumns() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v07-flow-wide-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("flow.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open(source.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "WisprFlowFixture", code: 18)
        }
        let columns = (0..<600).map { index in
            "\"wide-\(index)-\(String(repeating: "x", count: 12_500))\" TEXT"
        }.joined(separator: ",")
        let sql = """
            CREATE TABLE History (
                transcriptEntityId TEXT, timestamp TEXT, pastedText TEXT, \(columns)
            );
            INSERT INTO History (transcriptEntityId, timestamp, pastedText)
            VALUES ('\(Fixture.sharedID.uuidString)', '2026-01-03 12:00:00.000 +00:00', 'Recovered transcript');
            """
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        let message = String(cString: sqlite3_errmsg(database))
        sqlite3_close(database)
        guard result == SQLITE_OK else {
            throw NSError(domain: "WisprFlowFixture", code: 19,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }

        let reader = try WisprFlowSourceReader(sourceURLs: [source])
        let session = try reader.session(for: Fixture.sharedID)
        XCTAssertEqual(session.displayText, "Recovered transcript")
        let archive = try XCTUnwrap(session.artifacts.first(where: { $0.filename == .sourceJSON }))
        let bytes = try Data(contentsOf: archive.url)
        XCTAssertLessThanOrEqual(bytes.count, WisprFlowImportLimits.maximumArtifactBytes)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(document["provenanceStatus"] as? String, "partial")
        let versions = try XCTUnwrap(document["sources"] as? [[String: Any]])
        let canonical = try XCTUnwrap(versions.first)
        let omittedValues = try XCTUnwrap(canonical["omittedValueCount"] as? Int)
        let omittedColumns = canonical["omittedColumnCount"] as? Int ?? 0
        let fieldCount = try XCTUnwrap(document["provenanceOmittedFieldCount"] as? Int)
        XCTAssertGreaterThan(omittedValues, 600)
        XCTAssertGreaterThanOrEqual(fieldCount, omittedValues + omittedColumns)
        XCTAssertEqual((canonical["omittedValuesSHA256"] as? String)?.count, 64)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testDictionaryLargerThanOldLimitIsWholeAndAboveNewLimitFailsClearly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addDictionaryRows(count: 1_000, valueSize: 400)
        let reader = try WisprFlowSourceReader(sourceURLs: [fixture.urls[0]])
        XCTAssertEqual(reader.preview.dictionaryCount, 1_000)
        let url = try XCTUnwrap(reader.dictionaryArtifactURL())
        let archive = try Data(contentsOf: url)
        XCTAssertGreaterThan(archive.count, 262_144)
        XCTAssertLessThan(archive.count, WisprFlowImportLimits.maximumDictionaryBytes)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        let sources = try XCTUnwrap(document["sources"] as? [[String: Any]])
        let rows = try XCTUnwrap(sources.first?["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1_000)

        try fixture.addOversizedDictionaryBlob()
        let oversizedReader = try WisprFlowSourceReader(sourceURLs: [fixture.urls[0]])
        XCTAssertThrowsError(try oversizedReader.dictionaryArtifactURL()) { error in
            guard case WisprFlowSourceReaderError.dictionaryTooLarge(let bytes) = error else {
                return XCTFail("Expected a size-specific dictionary error, got \(error)")
            }
            XCTAssertGreaterThan(bytes, WisprFlowImportLimits.maximumDictionaryBytes)
        }
    }

    func testEscapedDictionaryTextIsRecoveredUntilArchiveLimit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addEscapedDictionaryText(id: "escaped-small", count: 1_024)
        let reader = try WisprFlowSourceReader(sourceURLs: [fixture.urls[0]])
        let archive = try Data(contentsOf: XCTUnwrap(reader.dictionaryArtifactURL()))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        let sources = try XCTUnwrap(document["sources"] as? [[String: Any]])
        let rows = try XCTUnwrap(sources.first?["rows"] as? [[String: [String: Any]]])
        XCTAssertEqual(rows.first?["phrase"]?["value"] as? String, String(repeating: "\n", count: 1_024))

        // The raw SQLite value fits in 8 MiB, but JSON escaping doubles it.
        try fixture.addEscapedDictionaryText(
            id: "escaped-large", count: WisprFlowImportLimits.maximumDictionaryBytes / 2 + 1_024
        )
        let oversizedReader = try WisprFlowSourceReader(sourceURLs: [fixture.urls[0]])
        XCTAssertThrowsError(try oversizedReader.dictionaryArtifactURL()) { error in
            guard case WisprFlowSourceReaderError.dictionaryTooLarge(let bytes) = error else {
                return XCTFail("Expected a size-specific dictionary error, got \(error)")
            }
            XCTAssertGreaterThan(bytes, WisprFlowImportLimits.maximumDictionaryBytes)
        }
    }

    func testDictionaryRowsWithoutUsableIDsRemainInPreviewAndArchive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addDictionaryRowsWithUnusableIDs()
        let reader = try WisprFlowSourceReader(sourceURLs: fixture.urls)
        XCTAssertEqual(reader.preview.dictionaryCount, 3)

        let archive = try Data(contentsOf: XCTUnwrap(reader.dictionaryArtifactURL()))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        let sources = try XCTUnwrap(document["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.count, 2)
        let currentRows = try XCTUnwrap(sources[0]["rows"] as? [[String: [String: Any]]])
        let backupRows = try XCTUnwrap(sources[1]["rows"] as? [[String: [String: Any]]])
        XCTAssertEqual(Set(currentRows.compactMap { $0["phrase"]?["value"] as? String }),
                       Set(["Null ID", "Invalid UTF-8 ID", "Current shared"]))
        XCTAssertEqual(backupRows.count, 1)
        XCTAssertEqual(backupRows.first?["phrase"]?["value"] as? String, "Backup shared")
    }

    func testMalformedSourceIDsAreSkippedAndCountedWithoutBlockingValidHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addMalformedSourceIDs()
        let reader = try WisprFlowSourceReader(sourceURLs: fixture.urls)
        XCTAssertEqual(reader.preview.sessionCount, 3)
        XCTAssertEqual(reader.sourceIDs, [Fixture.sharedID, Fixture.textOnlyID, Fixture.metadataOnlyID])
        XCTAssertTrue(reader.preview.warnings.contains { $0.contains("Skipped 3 History rows") })
        XCTAssertEqual(try reader.session(for: Fixture.sharedID).displayText, "Current pasted text")
    }

    func testUnknownBuiltInAudioIsRecordedAsUnarchivedMedia() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addBuiltInAudioBlob()
        let reader = try WisprFlowSourceReader(sourceURLs: [fixture.urls[0]])
        let session = try reader.session(for: Fixture.sharedID)
        XCTAssertEqual(session.artifacts.map(\.filename), [.sourceJSON])
        let omitted = try XCTUnwrap(session.unarchivedArtifacts.first(where: { $0.filename == .builtInAudio }))
        XCTAssertEqual(omitted.byteCount, 128)
        XCTAssertEqual(omitted.sha256.count, 64)
        let source = try XCTUnwrap(session.artifacts.first)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.url)) as? [String: Any])
        let omissions = try XCTUnwrap(document["archiveOmissions"] as? [[String: Any]])
        XCTAssertEqual(omissions.first?["sourceColumn"] as? String, "builtInAudio")
        XCTAssertEqual(omissions.first?["reason"] as? String, "unsupported-source-column")
        XCTAssertEqual(omissions.first?["observedSHA256"] as? String, omitted.sha256)
    }

    func testNumericValuesInMediaNamedColumnsPreserveTypedSourceAndDoNotBlockText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v07-flow-numeric-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("numeric.sqlite")
        let sourceID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        var database: OpaquePointer?
        guard sqlite3_open(source.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "WisprFlowFixture", code: 20)
        }
        let sql = """
            CREATE TABLE History (
                transcriptEntityId TEXT PRIMARY KEY, timestamp TEXT, pastedText TEXT,
                audio, opusChunks, screenshot, builtInAudio
            );
            INSERT INTO History VALUES (
                '\(sourceID.uuidString)', '2026-01-03 12:00:00.000 +00:00', 'Recovered text',
                42, 3.5, -7, 2.25
            );
            """
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        let sqliteMessage = String(cString: sqlite3_errmsg(database))
        sqlite3_close(database)
        guard result == SQLITE_OK else {
            throw NSError(domain: "WisprFlowFixture", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: sqliteMessage])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
        let before = try Data(contentsOf: source)
        let reader = try WisprFlowSourceReader(sourceURLs: [source])
        XCTAssertEqual(reader.preview.sessionCount, 1)
        XCTAssertEqual(reader.preview.wavCount, 0)
        XCTAssertEqual(reader.preview.opusCount, 0)
        XCTAssertEqual(reader.preview.screenshotCount, 0)
        let session = try reader.session(for: sourceID)
        XCTAssertEqual(session.displayText, "Recovered text")
        XCTAssertEqual(session.artifacts.map(\.filename), [.sourceJSON])
        XCTAssertTrue(session.unarchivedArtifacts.isEmpty)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(session.artifacts.first).url)) as? [String: Any])
        let sources = try XCTUnwrap(document["sources"] as? [[String: Any]])
        let values = try XCTUnwrap(sources.first?["values"] as? [String: [String: Any]])
        XCTAssertEqual(values["audio"]?["type"] as? String, "integer")
        XCTAssertEqual(values["audio"]?["value"] as? Int, 42)
        XCTAssertEqual(values["opusChunks"]?["type"] as? String, "real")
        XCTAssertEqual(values["opusChunks"]?["value"] as? Double, 3.5)
        XCTAssertEqual(values["screenshot"]?["type"] as? String, "integer")
        XCTAssertEqual(values["screenshot"]?["value"] as? Int, -7)
        XCTAssertEqual(values["builtInAudio"]?["type"] as? String, "real")
        XCTAssertEqual(values["builtInAudio"]?["value"] as? Double, 2.25)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testMultibyteOpusTextUsesByteExactLimitAndKeepsSmallerBackup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let byteCount = try fixture.addOversizedUTF8OpusText()
        XCTAssertGreaterThan(byteCount, WisprFlowImportLimits.maximumArtifactBytes)
        let reader = try WisprFlowSourceReader(sourceURLs: fixture.urls)
        let session = try reader.session(for: Fixture.sharedID)
        XCTAssertEqual(session.displayText, "Current pasted text")
        let opus = try XCTUnwrap(session.artifacts.first(where: { $0.filename == .opusJSON }))
        XCTAssertEqual(try Data(contentsOf: opus.url), Data(#"{"chunks":[]}"#.utf8))
        let missing = try XCTUnwrap(session.unarchivedArtifacts.first(where: { $0.filename == .opusJSON }))
        XCTAssertEqual(missing.byteCount, byteCount)
        let source = try XCTUnwrap(session.artifacts.first(where: { $0.filename == .sourceJSON }))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.url)) as? [String: Any])
        let omissions = try XCTUnwrap(document["archiveOmissions"] as? [[String: Any]])
        let current = try XCTUnwrap(omissions.first(where: { $0["sourceName"] as? String == "live.sqlite"
            && $0["artifact"] as? String == "opus.json" }))
        XCTAssertEqual(current["observedByteCount"] as? Int, byteCount)
        XCTAssertEqual(current["observedSHA256"] as? String, missing.sha256)
        XCTAssertEqual(current["reason"] as? String, "exceeds-upload-limit")

        let currentOnly = try WisprFlowSourceReader(sourceURLs: [fixture.urls[0]])
        let textOnly = try currentOnly.session(for: Fixture.sharedID)
        XCTAssertEqual(textOnly.artifacts.map(\.filename), [.sourceJSON])
        XCTAssertEqual(textOnly.unarchivedArtifacts.map(\.filename), [.opusJSON])
        XCTAssertEqual(textOnly.displayText, "Current pasted text")
    }

    private struct Fixture {
        static let sharedID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        static let textOnlyID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        static let metadataOnlyID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        static let backupWAV = Data([0x52, 0x49, 0x46, 0x46, 0x26, 0, 0, 0, 0x57, 0x41, 0x56, 0x45,
                                     0x66, 0x6d, 0x74, 0x20, 0x10, 0, 0, 0, 1, 0, 1, 0,
                                     0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0,
                                     0x64, 0x61, 0x74, 0x61, 2, 0, 0, 0, 0, 0])

        let directory: URL
        let urls: [URL]

        init(walMode: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("v07-flow-reader-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let live = directory.appendingPathComponent("live.sqlite")
            let backup = directory.appendingPathComponent("backup.sqlite")
            try Self.makeDatabase(at: live, walMode: walMode, rows: """
                INSERT INTO History VALUES ('\(Self.sharedID.uuidString)', '2026-01-03 12:00:00.000 +00:00', 'Current ASR text', 'Current formatted text', 'Current pasted text', 'Current finalized text', NULL, NULL, 'COMPLETED', 1.25);
                INSERT INTO History VALUES ('\(Self.textOnlyID.uuidString)', '2026-01-04 12:00:00.000 +00:00', 'Text-only ASR', NULL, NULL, 'Finalized text only', NULL, NULL, 'COMPLETED', 2.0);
                INSERT INTO History VALUES ('\(Self.metadataOnlyID.uuidString)', '2026-01-05 12:00:00.000 +00:00', NULL, NULL, NULL, NULL, NULL, NULL, 'FAILED', NULL);
                """)
            try Self.makeDatabase(at: backup, rows: """
                INSERT INTO History VALUES ('\(Self.sharedID.uuidString)', '2026-01-03 12:00:00.000 +00:00', 'Old ASR text', NULL, 'Old pasted text', NULL, x'\(Self.backupWAV.map { String(format: "%02x", $0) }.joined())', '{"chunks":[]}', 'COMPLETED', 1.25);
                """)
            if walMode {
                for suffix in ["-wal", "-shm"] {
                    try? FileManager.default.removeItem(atPath: live.path + suffix)
                }
            }
            for url in [live, backup] { try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path) }
            urls = [live, backup]
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func addOversizedCurrentWAV() throws {
            try withWritableLiveDatabase { database in
                let sql = "UPDATE History SET audio = zeroblob(\(WisprFlowImportLimits.maximumArtifactBytes + 1)) WHERE transcriptEntityId = '\(Self.sharedID.uuidString)'"
                guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
                }
                var blob: OpaquePointer?
                guard sqlite3_blob_open(database, "main", "History", "audio", 1, 1, &blob) == SQLITE_OK,
                      let blob else { throw NSError(domain: "WisprFlowFixture", code: 6) }
                defer { sqlite3_blob_close(blob) }
                let header: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45]
                guard header.withUnsafeBytes({ sqlite3_blob_write(blob, $0.baseAddress, Int32(header.count), 0) }) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 7)
                }
            }
        }

        func addOversizedUTF8OpusText() throws -> Int {
            let value = String(repeating: "é", count: WisprFlowImportLimits.maximumArtifactBytes / 2 + 1)
            let byteCount = value.utf8.count
            try withWritableLiveDatabase { database in
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database,
                    "UPDATE History SET opusChunks = ? WHERE transcriptEntityId = ?",
                    -1, &statement, nil) == SQLITE_OK, let statement else {
                    throw NSError(domain: "WisprFlowFixture", code: 22)
                }
                defer { sqlite3_finalize(statement) }
                try value.withCString { valuePointer in
                    try Self.sharedID.uuidString.withCString { idPointer in
                        sqlite3_bind_text(statement, 1, valuePointer, Int32(byteCount), nil)
                        sqlite3_bind_text(statement, 2, idPointer, -1, nil)
                        guard sqlite3_step(statement) == SQLITE_DONE else {
                            throw NSError(domain: "WisprFlowFixture", code: 23,
                                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
                        }
                    }
                }
            }
            return byteCount
        }

        func addProvenanceFields(blobBytes: Int, textBytes: Int) throws {
            try withWritableLiveDatabase { database in
                let schema = "ALTER TABLE History ADD COLUMN extraPayload BLOB; ALTER TABLE History ADD COLUMN longNote TEXT;"
                guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK,
                      sqlite3_exec(database,
                                   "UPDATE History SET extraPayload = zeroblob(\(blobBytes)) WHERE rowid = 1",
                                   nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 15,
                                  userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
                }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "UPDATE History SET longNote = ? WHERE rowid = 1",
                                         -1, &statement, nil) == SQLITE_OK,
                      let statement else { throw NSError(domain: "WisprFlowFixture", code: 16) }
                defer { sqlite3_finalize(statement) }
                let text = String(repeating: "n", count: textBytes)
                try text.withCString { pointer in
                    sqlite3_bind_text(statement, 1, pointer, Int32(textBytes), nil)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw NSError(domain: "WisprFlowFixture", code: 17,
                                      userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
                    }
                    sqlite3_reset(statement)
                }
            }
        }

        func addDictionaryRows(count: Int, valueSize: Int) throws {
            try withWritableLiveDatabase { database in
                guard sqlite3_exec(database, "CREATE TABLE IF NOT EXISTS Dictionary (id TEXT PRIMARY KEY, phrase TEXT)", nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 8)
                }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "INSERT INTO Dictionary VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK,
                      let statement else { throw NSError(domain: "WisprFlowFixture", code: 9) }
                defer { sqlite3_finalize(statement) }
                let phrase = String(repeating: "a", count: valueSize)
                for index in 0..<count {
                    let identifier = "entry-\(index)"
                    try identifier.withCString { idPointer in
                        try phrase.withCString { phrasePointer in
                            sqlite3_bind_text(statement, 1, idPointer, -1, nil)
                            sqlite3_bind_text(statement, 2, phrasePointer, -1, nil)
                            guard sqlite3_step(statement) == SQLITE_DONE else {
                                throw NSError(domain: "WisprFlowFixture", code: 10)
                            }
                        }
                    }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
            }
        }

        func addOversizedDictionaryBlob() throws {
            try withWritableLiveDatabase { database in
                guard sqlite3_exec(database, "ALTER TABLE Dictionary ADD COLUMN payload BLOB", nil, nil, nil) == SQLITE_OK,
                      sqlite3_exec(database, "INSERT INTO Dictionary (id, payload) VALUES ('huge', zeroblob(7000000))", nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 11)
                }
            }
        }

        func addEscapedDictionaryText(id: String, count: Int) throws {
            try withWritableLiveDatabase { database in
                guard sqlite3_exec(database, "CREATE TABLE IF NOT EXISTS Dictionary (id TEXT PRIMARY KEY, phrase TEXT)", nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 15)
                }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "INSERT INTO Dictionary VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK,
                      let statement else { throw NSError(domain: "WisprFlowFixture", code: 16) }
                defer { sqlite3_finalize(statement) }
                let phrase = String(repeating: "\n", count: count)
                try id.withCString { idPointer in
                    try phrase.withCString { phrasePointer in
                        sqlite3_bind_text(statement, 1, idPointer, -1, nil)
                        sqlite3_bind_text(statement, 2, phrasePointer, -1, nil)
                        guard sqlite3_step(statement) == SQLITE_DONE else {
                            throw NSError(domain: "WisprFlowFixture", code: 17)
                        }
                    }
                }
            }
        }

        func addDictionaryRowsWithUnusableIDs() throws {
            try withWritableDatabase(at: 0) { database in
                let sql = """
                    CREATE TABLE Dictionary (id BLOB, phrase TEXT);
                    INSERT INTO Dictionary VALUES (NULL, 'Null ID');
                    INSERT INTO Dictionary VALUES (x'ff', 'Invalid UTF-8 ID');
                    INSERT INTO Dictionary VALUES ('shared', 'Current shared');
                    """
                guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 18)
                }
            }
            try withWritableDatabase(at: 1) { database in
                let sql = """
                    CREATE TABLE Dictionary (id BLOB, phrase TEXT);
                    INSERT INTO Dictionary VALUES ('shared', 'Backup shared');
                    """
                guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 19)
                }
            }
        }

        func addMalformedSourceIDs() throws {
            try withWritableLiveDatabase { database in
                let sql = """
                    INSERT INTO History (transcriptEntityId, timestamp, pastedText)
                        VALUES (NULL, '2026-01-06 12:00:00.000 +00:00', 'Bad null ID');
                    INSERT INTO History (transcriptEntityId, timestamp, pastedText)
                        VALUES ('', '2026-01-07 12:00:00.000 +00:00', 'Bad empty ID');
                    INSERT INTO History (transcriptEntityId, timestamp, pastedText)
                        VALUES ('not-a-uuid', '2026-01-08 12:00:00.000 +00:00', 'Bad text ID');
                    """
                guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 13,
                                  userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
                }
            }
        }

        func addBuiltInAudioBlob() throws {
            try withWritableLiveDatabase { database in
                guard sqlite3_exec(database, "ALTER TABLE History ADD COLUMN builtInAudio BLOB", nil, nil, nil) == SQLITE_OK,
                      sqlite3_exec(database, "UPDATE History SET builtInAudio = zeroblob(128) WHERE rowid = 1", nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "WisprFlowFixture", code: 14)
                }
            }
        }

        private func withWritableLiveDatabase(_ operation: (OpaquePointer) throws -> Void) throws {
            try withWritableDatabase(at: 0, operation)
        }

        private func withWritableDatabase(at index: Int, _ operation: (OpaquePointer) throws -> Void) throws {
            let source = urls[index]
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path) }
            var database: OpaquePointer?
            guard sqlite3_open(source.path, &database) == SQLITE_OK, let database else {
                throw NSError(domain: "WisprFlowFixture", code: 12)
            }
            defer { sqlite3_close(database) }
            try operation(database)
        }

        private static func makeDatabase(at url: URL, walMode: Bool = false, rows: String) throws {
            var database: OpaquePointer?
            guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
                throw NSError(domain: "WisprFlowFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create SQLite fixture."])
            }
            defer { sqlite3_close(database) }
            let sql = """
                \(walMode ? "PRAGMA journal_mode=WAL;" : "")
                CREATE TABLE History (
                    transcriptEntityId TEXT PRIMARY KEY, timestamp TEXT,
                    asrText TEXT, formattedText TEXT, pastedText TEXT, serverFinalizedText TEXT,
                    audio BLOB, opusChunks TEXT, status TEXT, duration REAL
                );
                \(rows)
                \(walMode ? "PRAGMA wal_checkpoint(TRUNCATE);" : "")
                """
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "Unknown SQLite error."
                sqlite3_free(error)
                throw NSError(domain: "WisprFlowFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }
}
