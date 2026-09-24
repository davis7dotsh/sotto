import Foundation
import V07API
import V07APIWire
import XCTest

final class APIWireTests: XCTestCase {
    func testHistoricalPreferencesDefaultsSurviveGeneratedTransport() throws {
        let json = Data("""
            {"revision":7,"preferences":{"language":"en","vocabulary":"",
             "dictionary":{"lists":[{"id":"personal","name":"Personal","entries":[{"id":"codex","term":"Codex"}]},
                                    {"id":"empty","name":"Empty"}]},
             "textCorrectionEnabled":true,"keepOriginalAudio":true}}
            """.utf8)
        let snapshot = try V07API.decodeWire(PreferencesSnapshot.self, from: json)
        XCTAssertEqual(snapshot.revision, 7)
        XCTAssertEqual(snapshot.preferences.proofreadingPrompt, ServerPreferences.defaultProofreadingPrompt)
        XCTAssertEqual(snapshot.preferences.dictionary.lists[0].entries[0].aliases, [])
        XCTAssertFalse(snapshot.preferences.dictionary.lists[0].entries[0].isPriority)
        XCTAssertEqual(snapshot.preferences.dictionary.lists[1].entries, [])
        XCTAssertNil(snapshot.preferences.validationError)
        let encoded = try V07API.encodeWire(snapshot)
        XCTAssertEqual(try V07API.decodeWire(PreferencesSnapshot.self, from: encoded), snapshot)
    }

    func testCompleteGenerationRoundTripsThroughGeneratedTypes() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var record = GenerationRecord(requestID: UUID(), device: .init(id: "test", name: "Test Mac"),
            status: .completed, createdAt: timestamp, settings: .init(revision: 3))
        record.rawText = "codex, sorry, MiniMax"
        record.finalText = "MiniMax."
        record.insertionText = "MiniMax."
        record.previewText = "MiniMax."
        record.inferenceAudio = .init(filename: "inference.wav", sampleRate: 16_000, channels: 1,
            frameCount: 32_000, byteCount: 128_044)
        record.originalAudio = .init(filename: "original.wav", sampleRate: 48_000, channels: 2,
            frameCount: 96_000, byteCount: 768_044)
        record.detectedLanguage = "en"
        record.speech = .init(modelID: "whisper", modelSHA256: "abc", backend: "whisper.cpp",
            engineVersion: "test", processingSeconds: 0.25)
        record.proofreading = .init(modelID: "qwen", backend: "mlx", processingSeconds: 0.1)
        record.textProcessing = try V07API.decoder().decode(TextProcessingRecord.self, from: Data("""
            {"dictionaryTerms":["Codex","MiniMax"],"dictionaryChangedText":true,
             "inputText":"Codex, sorry, MiniMax","outputText":"MiniMax.","enabled":true,
             "status":"applied","reason":"verified","modelID":"qwen","modelSHA256":"abc",
             "engineVersion":"test","processingSeconds":0.1,"wallSeconds":0.2,"proposedText":"MiniMax.",
             "verifiedRepairs":[{"abandoned":{"locationUTF16":0,"lengthUTF16":5,"text":"Codex"},
                                 "cue":{"locationUTF16":7,"lengthUTF16":5,"text":"sorry"},
                                 "replacement":{"locationUTF16":14,"lengthUTF16":7,"text":"MiniMax"}}]}
            """.utf8))
        record.recognitionHints = .init(includedTerms: ["Codex"], omittedTerms: ["MiniMax"], tokenCount: 3, tokenBudget: 48)
        record.proofreadingHints = .init(includedTerms: ["MiniMax"], omittedTerms: [], tokenCount: 2, tokenBudget: 96)
        record.formattingRejectionReason = "retained source formatting"
        record.consumedListControls = [try V07API.decodeWire(ListControlSpan.self,
            from: Data("{\"location\":0,\"length\":4}".utf8))]
        record.continuation = .init(list: .init(style: .numbered, nextNumber: 3), preview: "1. MiniMax", boundary: .line)
        record.delivery = .init(status: "inserted", message: "ok", reportedAt: timestamp)
        record.progress = 1
        record.importedSource = .init(sourceID: UUID(), sourceStatus: "completed", importedAt: timestamp,
            variantNames: ["final"], artifactNames: [.sourceJSON, .sourceWAV], durationSeconds: 2,
            sourceSHA256: "abc", artifactSHA256: ["source.json": "abc"])

        let data = try V07API.encodeWire(record)
        let generated = try V07API.decoder().decode(Components.Schemas.GenerationRecord.self, from: data)
        XCTAssertEqual(generated.id, record.id)
        XCTAssertEqual(generated.createdAt, timestamp)
        XCTAssertEqual(generated.inferenceAudio?.frameCount, 32_000)
        XCTAssertEqual(try V07API.decodeWire(GenerationRecord.self, from: data), record)
        XCTAssertEqual(record.audioSeconds, 2)
        XCTAssertTrue(record.status.isTerminal)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["error"])
        XCTAssertFalse(object.values.contains { $0 is NSNull })
    }

    func testGeneratedTransportEnforcesRequiredFieldsAndKnownEnums() throws {
        XCTAssertThrowsError(try V07API.decodeWire(ServerHealth.self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try V07API.decodeWire(GenerationStatus.self, from: Data("\"unknown\"".utf8)))
    }

    func testDomainDictionaryValidationRemainsActive() throws {
        let json = Data("""
            {"lists":[{"id":"personal","name":"Personal","entries":[
                {"id":"duplicate","term":"Codex"},{"id":"duplicate","term":"MiniMax"}]}]}
            """.utf8)
        XCTAssertThrowsError(try V07API.decodeWire(PersonalDictionary.self, from: json))
        let nullAliases = Data("{\"id\":\"codex\",\"term\":\"Codex\",\"aliases\":null}".utf8)
        XCTAssertThrowsError(try V07API.decodeWire(DictionaryEntry.self, from: nullAliases))
        let nullEntries = Data("{\"id\":\"personal\",\"name\":\"Personal\",\"entries\":null}".utf8)
        XCTAssertThrowsError(try V07API.decodeWire(DictionaryList.self, from: nullEntries))
    }

    func testFrameCountersAndImportsRetainTheirWireShapes() throws {
        let frames: Int64 = 4_294_967_296
        let receipt = AudioChunkReceipt(nextSequence: 3, frameCount: frames)
        let decoded = try V07API.decodeWire(AudioChunkReceipt.self, from: V07API.encodeWire(receipt))
        XCTAssertEqual(decoded.frameCount, frames)
        let request = FinishGenerationRequest(inferenceFrames: frames, originalFrames: frames, continuationID: UUID())
        let finish = try V07API.decodeWire(FinishGenerationRequest.self, from: V07API.encodeWire(request))
        XCTAssertEqual(finish.continuationID, request.continuationID)

        let sourceID = UUID()
        let manifest = WisprFlowArtifactManifest(filename: .sourceJSON, byteCount: 128,
            sha256: String(repeating: "a", count: 64))
        let imported = WisprFlowImportRequest(sourceID: sourceID, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            finalText: "Hello.", rawText: "hello", artifacts: [manifest], unarchivedArtifacts: [])
        XCTAssertEqual(try V07API.decodeWire(WisprFlowImportRequest.self, from: V07API.encodeWire(imported)), imported)
        let known = WisprFlowKnownIDsRequest(sourceIDs: [sourceID])
        XCTAssertEqual(try V07API.decodeWire(WisprFlowKnownIDsRequest.self, from: V07API.encodeWire(known)).sourceIDs, [sourceID])
    }
}
