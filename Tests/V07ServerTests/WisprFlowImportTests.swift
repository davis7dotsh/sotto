import Crypto
import Foundation
import V07API
@testable import V07ServerKit
import XCTest

final class WisprFlowImportTests: XCTestCase {
    func testRerunBackfillsAudioIntoTheSameDurableHistoryRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let source = Self.sourceJSON(for: sourceID)
        let wav = Self.smallWAV
        let service = try GenerationService(configuration: fixture.configuration)

        let first = try await service.beginWisprFlowImport(Self.request(sourceID: sourceID, text: "Recovered text", artifacts: [(.sourceJSON, source)]))
        _ = try await service.uploadWisprFlowArtifact(first.id, filename: .sourceJSON, data: source)
        let imported = try await service.completeWisprFlowImport(first.id)
        XCTAssertEqual(imported.outcome, .imported)
        XCTAssertEqual(imported.record.finalText, "Recovered text")
        XCTAssertEqual(imported.record.importedSource?.sourceID, sourceID)
        await service.shutdown()

        let restarted = try GenerationService(configuration: fixture.configuration)
        let second = try await restarted.beginWisprFlowImport(Self.request(sourceID: sourceID, text: "Recovered text", artifacts: [(.sourceJSON, source), (.sourceWAV, wav)]))
        _ = try await restarted.uploadWisprFlowArtifact(second.id, filename: .sourceJSON, data: source)
        _ = try await restarted.uploadWisprFlowArtifact(second.id, filename: .sourceWAV, data: wav)
        let enriched = try await restarted.completeWisprFlowImport(second.id)
        XCTAssertEqual(enriched.outcome, .enriched)
        XCTAssertEqual(enriched.record.id, imported.record.id)
        XCTAssertEqual(enriched.record.importedSource?.artifactNames.contains(.sourceWAV), true)
        let archivedWAV = try await restarted.artifact(imported.record.id, filename: "source.wav")
        XCTAssertEqual(try Data(contentsOf: archivedWAV), wav)
        let history = try await restarted.history(limit: 50, before: nil, source: "wispr-flow")
        XCTAssertEqual(history.items.map(\.id), [imported.record.id])
        let known = try await restarted.knownWisprFlowIDs(.init(sourceIDs: [sourceID, UUID()]))
        XCTAssertEqual(known.knownSourceIDs, [sourceID])
        await restarted.shutdown()

        let afterBackfill = try GenerationService(configuration: fixture.configuration)
        let durable = try await afterBackfill.get(imported.record.id)
        XCTAssertEqual(durable.importedSource?.sourceID, sourceID)
        XCTAssertEqual(durable.finalText, "Recovered text")
        XCTAssertEqual(durable.importedSource?.artifactSHA256["source.wav"], Self.sha256(wav))
        let durableWAV = try await afterBackfill.artifact(imported.record.id, filename: "source.wav")
        XCTAssertEqual(try Data(contentsOf: durableWAV), wav)
        await afterBackfill.shutdown()
    }

    func testMetadataOnlyAttemptIsArchivedWithoutInventingATranscript() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let source = Self.sourceJSON(for: sourceID)
        let service = try GenerationService(configuration: fixture.configuration)
        let request = Self.request(sourceID: sourceID, text: "", status: "FAILED", artifacts: [(.sourceJSON, source)])
        let session = try await service.beginWisprFlowImport(request)
        _ = try await service.uploadWisprFlowArtifact(session.id, filename: .sourceJSON, data: source)
        let result = try await service.completeWisprFlowImport(session.id)
        XCTAssertEqual(result.outcome, .imported)
        XCTAssertTrue(result.record.finalText.isEmpty)
        XCTAssertTrue(result.record.rawText.isEmpty)
        XCTAssertEqual(result.record.importedSource?.sourceStatus, "FAILED")
        XCTAssertNil(result.record.inferenceAudio)
        XCTAssertNil(result.record.originalAudio)
        await service.shutdown()
    }

    func testConflictingNewMediaKeepsEarlierBytesWhileEnrichingText() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let originalSource = Self.sourceJSON(for: sourceID)
        let newerSource = Self.sourceJSON(for: sourceID, version: 2)
        let originalWAV = Self.smallWAV
        var conflictingWAV = originalWAV
        conflictingWAV[conflictingWAV.count - 1] = 1
        let service = try GenerationService(configuration: fixture.configuration)

        let first = try await service.beginWisprFlowImport(Self.request(sourceID: sourceID, text: "First text", artifacts: [(.sourceJSON, originalSource), (.sourceWAV, originalWAV)]))
        _ = try await service.uploadWisprFlowArtifact(first.id, filename: .sourceJSON, data: originalSource)
        _ = try await service.uploadWisprFlowArtifact(first.id, filename: .sourceWAV, data: originalWAV)
        let imported = try await service.completeWisprFlowImport(first.id)

        let second = try await service.beginWisprFlowImport(Self.request(sourceID: sourceID, text: "Corrected text", artifacts: [(.sourceJSON, newerSource), (.sourceWAV, conflictingWAV)]))
        _ = try await service.uploadWisprFlowArtifact(second.id, filename: .sourceJSON, data: newerSource)
        _ = try await service.uploadWisprFlowArtifact(second.id, filename: .sourceWAV, data: conflictingWAV)
        let enriched = try await service.completeWisprFlowImport(second.id)
        XCTAssertEqual(enriched.outcome, .partial)
        XCTAssertEqual(enriched.unarchivedArtifactNames, [.sourceWAV])
        XCTAssertEqual(enriched.record.id, imported.record.id)
        XCTAssertEqual(enriched.record.finalText, "Corrected text")
        XCTAssertEqual(enriched.record.importedSource?.artifactSHA256["source.wav"], Self.sha256(originalWAV))
        XCTAssertEqual(enriched.record.importedSource?.unarchivedArtifactSHA256?["source.wav"], Self.sha256(conflictingWAV))
        let archivedWAV = try await service.artifact(imported.record.id, filename: "source.wav")
        XCTAssertEqual(try Data(contentsOf: archivedWAV), originalWAV)
        let sourceArtifact = try await service.artifact(imported.record.id, filename: "source.json")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sourceArtifact)) as? [String: Any])
        let conflicts = try XCTUnwrap(document["archiveConflicts"] as? [[String: Any]])
        XCTAssertEqual(conflicts.first?["status"] as? String, "not-archived")
        XCTAssertEqual(conflicts.first?["observedSHA256"] as? String, Self.sha256(conflictingWAV))
        await service.shutdown()
    }

    func testMalformedArtifactCannotCreateAnImportedRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let source = Self.sourceJSON(for: sourceID)
        let malformedWAV = Data("not a WAV file".utf8)
        let service = try GenerationService(configuration: fixture.configuration)
        let request = Self.request(sourceID: sourceID, text: "Test", artifacts: [(.sourceJSON, source), (.sourceWAV, malformedWAV)])
        let session = try await service.beginWisprFlowImport(request)
        _ = try await service.uploadWisprFlowArtifact(session.id, filename: .sourceJSON, data: source)
        do {
            _ = try await service.uploadWisprFlowArtifact(session.id, filename: .sourceWAV, data: malformedWAV)
            _ = try await service.completeWisprFlowImport(session.id)
            XCTFail("An invalid WAV must be rejected before it enters history.")
        } catch let error as ServiceError {
            XCTAssertEqual(error.status, 400)
        }
        let known = try await service.knownWisprFlowIDs(.init(sourceIDs: [sourceID]))
        XCTAssertTrue(known.knownSourceIDs.isEmpty)
        await service.shutdown()
    }

    func testOversizedMediaOmissionArchivesTextAsPartialAndStaysPartialOnRerun() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let omitted = WisprFlowArtifactManifest(filename: .sourceWAV,
            byteCount: WisprFlowImportLimits.maximumArtifactBytes + 1,
            sha256: String(repeating: "a", count: 64))
        let document: [String: Any] = [
            "schemaVersion": 1, "provider": "wispr-flow", "sourceID": sourceID.uuidString,
            "sources": [["name": "flow.sqlite", "role": "current", "rowID": 1,
                         "values": ["audio": ["type": "blob", "byteCount": omitted.byteCount,
                                              "sha256": omitted.sha256, "archiveStatus": "not-archived",
                                              "archiveReason": "exceeds-upload-limit"]]]],
            "archiveOmissions": [["artifact": "source.wav", "sourceName": "flow.sqlite",
                                  "sourceRowID": 1, "observedByteCount": omitted.byteCount,
                                  "observedSHA256": omitted.sha256,
                                  "reason": "exceeds-upload-limit", "status": "not-archived"]],
        ]
        let source = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let service = try GenerationService(configuration: fixture.configuration)
        var request = Self.request(sourceID: sourceID, text: "Recovered words",
                                   artifacts: [(.sourceJSON, source)])
        request.unarchivedArtifacts = [omitted]
        let first = try await service.beginWisprFlowImport(request)
        _ = try await service.uploadWisprFlowArtifact(first.id, filename: .sourceJSON, data: source)
        let imported = try await service.completeWisprFlowImport(first.id)
        XCTAssertEqual(imported.outcome, .partial)
        XCTAssertEqual(imported.unarchivedArtifactNames, [.sourceWAV])
        XCTAssertEqual(imported.record.finalText, "Recovered words")
        XCTAssertEqual(imported.record.importedSource?.artifactNames, [.sourceJSON])
        XCTAssertEqual(imported.record.importedSource?.unarchivedArtifactSHA256?["source.wav"], omitted.sha256)
        let archived = try await service.artifact(imported.record.id, filename: "source.json")
        let archivedDocument = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archived)) as? [String: Any])
        let omissions = try XCTUnwrap(archivedDocument["archiveOmissions"] as? [[String: Any]])
        XCTAssertEqual(omissions.first?["observedByteCount"] as? Int, omitted.byteCount)
        XCTAssertEqual(omissions.first?["observedSHA256"] as? String, omitted.sha256)
        XCTAssertEqual(omissions.first?["status"] as? String, "not-archived")

        let again = try await service.beginWisprFlowImport(request)
        _ = try await service.uploadWisprFlowArtifact(again.id, filename: .sourceJSON, data: source)
        let rerun = try await service.completeWisprFlowImport(again.id)
        XCTAssertEqual(rerun.outcome, .partial)
        XCTAssertEqual(rerun.record.id, imported.record.id)
        XCTAssertEqual(rerun.unarchivedArtifactNames, [.sourceWAV])
        await service.shutdown()
    }

    func testCompactedProvenanceKeepsTextButRemainsPartialOnRerun() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let source = try Self.provenanceSourceJSON(for: sourceID, omitted: true)
        let request = Self.request(sourceID: sourceID, text: "Recovered words", artifacts: [(.sourceJSON, source)])
        let service = try GenerationService(configuration: fixture.configuration)

        let first = try await service.beginWisprFlowImport(request)
        _ = try await service.uploadWisprFlowArtifact(first.id, filename: .sourceJSON, data: source)
        let imported = try await service.completeWisprFlowImport(first.id)
        XCTAssertEqual(imported.outcome, .partial)
        XCTAssertTrue(imported.unarchivedArtifactNames.isEmpty)
        XCTAssertEqual(imported.record.finalText, "Recovered words")
        let archived = try await service.artifact(imported.record.id, filename: "source.json")
        let archivedDocument = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archived)) as? [String: Any])
        XCTAssertEqual(archivedDocument["provenanceStatus"] as? String, "partial")
        XCTAssertEqual(archivedDocument["provenanceOmittedFieldCount"] as? Int, 1)
        let archivedSources = try XCTUnwrap(archivedDocument["sources"] as? [[String: Any]])
        let values = try XCTUnwrap(archivedSources.first?["values"] as? [String: Any])
        let field = try XCTUnwrap(values["largeMetadata"] as? [String: Any])
        XCTAssertNil(field["value"])
        XCTAssertEqual(field["archiveStatus"] as? String, "not-archived")
        XCTAssertEqual(field["sha256"] as? String, String(repeating: "c", count: 64))

        let again = try await service.beginWisprFlowImport(request)
        _ = try await service.uploadWisprFlowArtifact(again.id, filename: .sourceJSON, data: source)
        let rerun = try await service.completeWisprFlowImport(again.id)
        XCTAssertEqual(rerun.outcome, .partial)
        XCTAssertTrue(rerun.unarchivedArtifactNames.isEmpty)
        XCTAssertEqual(rerun.record.id, imported.record.id)
        await service.shutdown()
    }

    func testLaterMediaAndFullRowVersionDoNotEraseCompactedProvenance() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
        let compacted = try Self.provenanceSourceJSON(for: sourceID, omitted: true)
        let complete = try Self.provenanceSourceJSON(for: sourceID, omitted: false)
        let wav = Self.smallWAV
        let service = try GenerationService(configuration: fixture.configuration)

        let first = try await service.beginWisprFlowImport(Self.request(sourceID: sourceID, text: "Words",
                                                            artifacts: [(.sourceJSON, compacted)]))
        _ = try await service.uploadWisprFlowArtifact(first.id, filename: .sourceJSON, data: compacted)
        let imported = try await service.completeWisprFlowImport(first.id)
        XCTAssertEqual(imported.outcome, .partial)

        let second = try await service.beginWisprFlowImport(Self.request(sourceID: sourceID, text: "Words",
                                                             artifacts: [(.sourceJSON, complete), (.sourceWAV, wav)]))
        _ = try await service.uploadWisprFlowArtifact(second.id, filename: .sourceJSON, data: complete)
        _ = try await service.uploadWisprFlowArtifact(second.id, filename: .sourceWAV, data: wav)
        let enriched = try await service.completeWisprFlowImport(second.id)
        XCTAssertEqual(enriched.outcome, .partial)
        XCTAssertTrue(enriched.unarchivedArtifactNames.isEmpty)
        XCTAssertEqual(enriched.record.id, imported.record.id)
        let archivedWAV = try await service.artifact(imported.record.id, filename: "source.wav")
        XCTAssertEqual(try Data(contentsOf: archivedWAV), wav)
        let archivedSource = try await service.artifact(imported.record.id, filename: "source.json")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archivedSource)) as? [String: Any])
        XCTAssertEqual(document["provenanceStatus"] as? String, "partial")
        XCTAssertEqual(document["provenanceOmittedFieldCount"] as? Int, 1)
        XCTAssertEqual((document["sources"] as? [[String: Any]])?.count, 2)
        await service.shutdown()
    }

    func testIncompleteProvenanceStatusIsRejectedBeforeHistoryChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        var document = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Self.provenanceSourceJSON(for: sourceID, omitted: true)) as? [String: Any])
        document.removeValue(forKey: "provenanceOmittedFieldCount")
        let invalid = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let service = try GenerationService(configuration: fixture.configuration)
        let session = try await service.beginWisprFlowImport(Self.request(sourceID: sourceID, text: "Words",
                                                                artifacts: [(.sourceJSON, invalid)]))
        do {
            _ = try await service.uploadWisprFlowArtifact(session.id, filename: .sourceJSON, data: invalid)
            XCTFail("A partial provenance status needs counts for omitted source values.")
        } catch let error as ServiceError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.code, "invalid_source_json")
        }
        let known = try await service.knownWisprFlowIDs(.init(sourceIDs: [sourceID]))
        XCTAssertTrue(known.knownSourceIDs.isEmpty)
        await service.shutdown()
    }

    func testDictionaryOverFormerLimitArchivesAllRowsWithoutChangingActiveDictionary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try GenerationService(configuration: fixture.configuration)
        let preferencesBefore = await service.getPreferences()
        let rows: [[String: Any]] = (0..<1_000).map { index in
            ["id": ["type": "text", "value": "entry-\(index)"],
             "phrase": ["type": "text", "value": String(repeating: "a", count: 400)]]
        }
        let document: [String: Any] = ["schemaVersion": 1, "provider": "wispr-flow",
                                       "table": "Dictionary",
                                       "sources": [["name": "flow.sqlite", "role": "current", "rows": rows]]]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        XCTAssertGreaterThan(data.count, 262_144)
        XCTAssertLessThan(data.count, WisprFlowImportLimits.maximumDictionaryBytes)
        let receipt = try await service.archiveWisprFlowDictionary(data)
        XCTAssertEqual(receipt.byteCount, data.count)
        let destination = fixture.configuration.dataDirectory.appendingPathComponent("imports/wispr-flow/dictionary.json")
        let archived = try Data(contentsOf: destination)
        XCTAssertEqual(archived, data)
        let archivedDocument = try XCTUnwrap(JSONSerialization.jsonObject(with: archived) as? [String: Any])
        let archivedSources = try XCTUnwrap(archivedDocument["sources"] as? [[String: Any]])
        XCTAssertEqual((archivedSources.first?["rows"] as? [[String: Any]])?.count, 1_000)
        let preferencesAfter = await service.getPreferences()
        XCTAssertEqual(preferencesAfter, preferencesBefore)
        await service.shutdown()
    }

    func testLaterMediaBackfillClearsEarlierOmissionAndKeepsOneRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let wav = Self.smallWAV
        let digest = Self.sha256(wav)
        let omission = WisprFlowArtifactManifest(filename: .sourceWAV, byteCount: wav.count, sha256: digest)
        let document: [String: Any] = [
            "schemaVersion": 1, "provider": "wispr-flow", "sourceID": sourceID.uuidString,
            "sources": [["name": "flow.sqlite", "role": "current", "rowID": 1,
                         "values": ["audio": ["type": "blob", "byteCount": wav.count,
                                              "sha256": digest, "archiveStatus": "not-archived",
                                              "archiveReason": "invalid-or-unavailable"]]]],
            "archiveOmissions": [["artifact": "source.wav", "sourceName": "flow.sqlite",
                                  "sourceRowID": 1, "observedByteCount": wav.count,
                                  "observedSHA256": digest,
                                  "reason": "invalid-or-unavailable", "status": "not-archived"]],
        ]
        let source = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let service = try GenerationService(configuration: fixture.configuration)
        var firstRequest = Self.request(sourceID: sourceID, text: "Words", artifacts: [(.sourceJSON, source)])
        firstRequest.unarchivedArtifacts = [omission]
        let first = try await service.beginWisprFlowImport(firstRequest)
        _ = try await service.uploadWisprFlowArtifact(first.id, filename: .sourceJSON, data: source)
        let partial = try await service.completeWisprFlowImport(first.id)
        XCTAssertEqual(partial.outcome, .partial)

        let secondRequest = Self.request(sourceID: sourceID, text: "Words",
                                         artifacts: [(.sourceJSON, source), (.sourceWAV, wav)])
        let second = try await service.beginWisprFlowImport(secondRequest)
        _ = try await service.uploadWisprFlowArtifact(second.id, filename: .sourceJSON, data: source)
        _ = try await service.uploadWisprFlowArtifact(second.id, filename: .sourceWAV, data: wav)
        let completed = try await service.completeWisprFlowImport(second.id)
        XCTAssertEqual(completed.outcome, .enriched)
        XCTAssertEqual(completed.record.id, partial.record.id)
        XCTAssertTrue((completed.record.importedSource?.unarchivedArtifactSHA256 ?? [:]).isEmpty)
        XCTAssertEqual(completed.record.importedSource?.artifactSHA256["source.wav"], digest)
        let archivedWAV = try await service.artifact(completed.record.id, filename: "source.wav")
        XCTAssertEqual(try Data(contentsOf: archivedWAV), wav)
        let archivedSource = try await service.artifact(completed.record.id, filename: "source.json")
        let archivedDocument = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archivedSource)) as? [String: Any])
        let omissions = try XCTUnwrap(archivedDocument["archiveOmissions"] as? [[String: Any]])
        XCTAssertEqual(omissions.first?["status"] as? String, "archived")
        await service.shutdown()
    }

    func testUnknownBuiltInAudioMakesImportPartialWithoutAcceptingUnknownBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        let omitted = WisprFlowArtifactManifest(filename: .builtInAudio, byteCount: 128,
                                                sha256: String(repeating: "b", count: 64))
        let document: [String: Any] = [
            "schemaVersion": 1, "provider": "wispr-flow", "sourceID": sourceID.uuidString,
            "sources": [["name": "flow.sqlite", "rowID": 1,
                         "values": ["builtInAudio": ["type": "blob", "byteCount": 128,
                                                     "sha256": omitted.sha256,
                                                     "archiveStatus": "not-archived",
                                                     "archiveReason": "unsupported-source-column"]]]],
            "archiveOmissions": [["artifact": omitted.filename.rawValue,
                                  "sourceColumn": "builtInAudio", "sourceName": "flow.sqlite",
                                  "sourceRowID": 1, "observedByteCount": 128,
                                  "observedSHA256": omitted.sha256,
                                  "reason": "unsupported-source-column", "status": "not-archived"]],
        ]
        let source = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let service = try GenerationService(configuration: fixture.configuration)
        var request = Self.request(sourceID: sourceID, text: "Recovered words", artifacts: [(.sourceJSON, source)])
        request.unarchivedArtifacts = [omitted]
        let transfer = try await service.beginWisprFlowImport(request)
        _ = try await service.uploadWisprFlowArtifact(transfer.id, filename: .sourceJSON, data: source)
        let result = try await service.completeWisprFlowImport(transfer.id)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.unarchivedArtifactNames, [.builtInAudio])
        XCTAssertEqual(result.record.importedSource?.unarchivedArtifactSHA256?[omitted.filename.rawValue], omitted.sha256)
        XCTAssertFalse(result.record.importedSource?.artifactNames.contains(.builtInAudio) ?? true)
        var invalidRequest = request
        invalidRequest.artifacts.append(omitted)
        do {
            _ = try await service.beginWisprFlowImport(invalidRequest)
            XCTFail("Unknown built-in audio must not be accepted as an upload artifact.")
        } catch let error as ServiceError {
            XCTAssertEqual(error.status, 400)
        }
        await service.shutdown()
    }

    private static func request(sourceID: UUID, text: String, status: String? = "COMPLETED",
                                artifacts: [(WisprFlowArtifactName, Data)]) -> WisprFlowImportRequest {
        WisprFlowImportRequest(sourceID: sourceID, createdAt: Date(timeIntervalSince1970: 1_767_441_600),
            sourceStatus: status, finalText: text, rawText: text, durationSeconds: text.isEmpty ? nil : 1.25,
            variantNames: text.isEmpty ? [] : ["pastedText"],
            artifacts: artifacts.map { name, data in
                WisprFlowArtifactManifest(filename: name, byteCount: data.count, sha256: sha256(data))
            })
    }

    private static func sourceJSON(for id: UUID, version: Int = 0) -> Data {
        let sources = version == 0 ? "[]" : "[{\"syntheticVersion\":\(version)}]"
        return Data(#"{"schemaVersion":1,"provider":"wispr-flow","sourceID":"\#(id.uuidString.lowercased())","sources":\#(sources)}"#.utf8)
    }

    private static func provenanceSourceJSON(for id: UUID, omitted: Bool) throws -> Data {
        let field: [String: Any] = omitted
            ? ["type": "text", "byteCount": 4_000_000, "sha256": String(repeating: "c", count: 64),
               "archiveStatus": "not-archived", "archiveReason": "exceeds-source-json-limit"]
            : ["type": "text", "value": "Restored metadata"]
        var document: [String: Any] = [
            "schemaVersion": 1, "provider": "wispr-flow", "sourceID": id.uuidString,
            "sources": [["name": "flow.sqlite", "role": "current", "rowID": 1,
                         "values": ["largeMetadata": field]]],
            "archiveOmissions": [],
        ]
        if omitted {
            document["provenanceStatus"] = "partial"
            document["provenanceOmittedFieldCount"] = 1
            document["provenanceOmittedSourceCount"] = 0
            document["provenanceOmittedMediaVersionCount"] = 0
        }
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let smallWAV = Data([0x52, 0x49, 0x46, 0x46, 0x26, 0, 0, 0, 0x57, 0x41, 0x56, 0x45,
                                        0x66, 0x6d, 0x74, 0x20, 0x10, 0, 0, 0, 1, 0, 1, 0,
                                        0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0,
                                        0x64, 0x61, 0x74, 0x61, 2, 0, 0, 0, 0, 0])

    private struct Fixture {
        let directory: URL
        let configuration: ServerConfiguration

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("v07-flow-import-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let unused = directory.appendingPathComponent("unused-model")
            let inference = InferenceConfiguration(speechHelper: unused, speechModel: unused, vadModel: unused,
                                                   proofHelper: unused, proofModel: unused)
            configuration = try ServerConfiguration(dataDirectory: directory.appendingPathComponent("state"),
                                                    development: true, inference: inference)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
