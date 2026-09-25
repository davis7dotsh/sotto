import Foundation
import Hummingbird
import HummingbirdTesting
import V07API
@testable import V07ServerKit
import XCTest

final class GenerationServiceTests: XCTestCase {
    func testOutOfOrderListSurvivesUnsupportedProofreadingName() async throws {
        let source = "I have a list of things to do. One is book the room Three is pick up the keys. Two is send the invitation. Four is I need to get God, what's it called? I need to get the meeting room sorted so I can go there and figure out whether I can get this meeting room."
        let formatted = "I have a list of things to do.\n\n1. book the room\n3. pick up the keys\n2. send the invitation\n4. I need to get God, what's it called? I need to get the meeting room sorted so I can go there and figure out whether I can get this meeting room."
        let proposal = formatted.replacingOccurrences(of: "God, what's it called? I need to get the meeting room", with: "Codex")
        try await withFixture(speechText: source, proofText: proposal) { service, _ in
            var preferences = await service.getPreferences()
            preferences.preferences.textCorrectionEnabled = true
            preferences.preferences.dictionary = PersonalDictionary(lists: [DictionaryList(name: "Terms", entries: [DictionaryEntry(term: "Codex")])])
            _ = try await service.updatePreferences(preferences)
            let record = try await service.create(Self.request())
            _ = try await service.appendAudio(record.id, kind: .inference, sequence: 0, format: Self.mono, data: Self.audio(frames: 8_000))
            _ = try await service.finish(record.id, request: .init(inferenceFrames: 8_000))
            for await _ in try await service.events(record.id) { }
            let completed = try await service.get(record.id)
            XCTAssertEqual(completed.status, .completed)
            XCTAssertEqual(completed.rawText, source)
            XCTAssertEqual(completed.textProcessing?.inputText, formatted)
            XCTAssertEqual(completed.textProcessing?.status, .rejected)
            XCTAssertEqual(completed.textProcessing?.reason, "The rewrite introduced an unsupported dictionary term.")
            XCTAssertEqual(completed.textProcessing?.proposedText, proposal)
            XCTAssertEqual(completed.finalText, formatted)
            XCTAssertEqual(completed.insertionText, formatted)
            XCTAssertEqual(completed.continuation?.list?.nextNumber, 5)
            let transcript = try await service.artifact(record.id, filename: "transcript.txt")
            XCTAssertEqual(try String(contentsOf: transcript, encoding: .utf8), formatted)
        }
    }

    func testFinishedRecordingsQueueInFinishOrderWhileHealthAndAdmissionStayReady() async throws {
        try await withFixture(blockSpeech: true) { service, fixture in
            let first = try await service.create(Self.request())
            let third = try await service.create(Self.request())
            let second = try await service.create(Self.request())
            for record in [first, second, third] {
                _ = try await service.appendAudio(record.id, kind: .inference, sequence: 0, format: Self.mono, data: Self.audio(frames: 8_000))
            }
            _ = try await service.finish(first.id, request: .init(inferenceFrames: 8_000))
            try await fixture.waitForRequest(first.id)
            let health = await service.health()
            XCTAssertTrue(health.ready, health.message ?? "")
            let receiving = try await service.create(Self.request())
            _ = try await service.finish(second.id, request: .init(inferenceFrames: 8_000))
            _ = try await service.finish(third.id, request: .init(inferenceFrames: 8_000))
            // An idempotent finish must not enqueue the same audio twice.
            _ = try await service.finish(second.id, request: .init(inferenceFrames: 8_000))
            let queued = try await service.get(second.id)
            XCTAssertEqual(queued.status, .queued)
            _ = try await service.cancel(receiving.id)
            try fixture.releaseSpeech()
            for record in [first, second, third] {
                for await _ in try await service.events(record.id) { }
                let completed = try await service.get(record.id)
                XCTAssertEqual(completed.status, .completed, completed.error ?? "")
            }
            let requests = try fixture.speechRequests()
            XCTAssertEqual(requests.count, 3)
            for (line, record) in zip(requests, [first, second, third]) {
                XCTAssertTrue(line.contains(record.id.uuidString))
            }
        }
    }

    func testCancellingQueuedAndActiveRecordingsPreservesRemainingQueue() async throws {
        try await withFixture(blockSpeech: true) { service, fixture in
            let first = try await service.create(Self.request())
            let cancelled = try await service.create(Self.request())
            let last = try await service.create(Self.request())
            for record in [first, cancelled, last] {
                _ = try await service.appendAudio(record.id, kind: .inference, sequence: 0, format: Self.mono, data: Self.audio(frames: 8_000))
                _ = try await service.finish(record.id, request: .init(inferenceFrames: 8_000))
            }
            try await fixture.waitForRequest(first.id)
            _ = try await service.cancel(cancelled.id)
            let stillActive = try await service.get(first.id)
            XCTAssertEqual(stillActive.status, .transcribing)
            _ = try await service.cancel(first.id)
            try fixture.releaseSpeech()
            for await _ in try await service.events(last.id) { }
            let completed = try await service.get(last.id)
            XCTAssertEqual(completed.status, .completed, completed.error ?? "")
            for record in [first, cancelled] {
                let result = try await service.get(record.id)
                XCTAssertEqual(result.status, .cancelled)
            }
            let requests = try fixture.speechRequests()
            XCTAssertEqual(requests.count, 2)
            XCTAssertFalse(requests.contains { $0.contains(cancelled.id.uuidString) })
        }
    }

    func testRecordingsAreAcceptedBeforeVerifiedHelpersFinishLoading() async throws {
        let fixture = try Fixture(speechText: "hello", proofText: "hello", blockSpeech: false)
        defer { fixture.remove() }
        let service = try GenerationService(configuration: fixture.configuration)
        do {
            let health = await service.health()
            XCTAssertTrue(health.ready, health.message ?? "")
            XCTAssertFalse(health.speech.ready)
            let record = try await service.create(Self.request())
            XCTAssertEqual(record.status, .receiving)
            _ = try await service.cancel(record.id)
        } catch {
            await service.shutdown()
            throw error
        }
        await service.shutdown()
    }

    func testShutdownTerminatesEveryReceivingQueuedAndProcessingRecording() async throws {
        try await withFixture(blockSpeech: true) { service, fixture in
            let first = try await service.create(Self.request())
            let queued = try await service.create(Self.request())
            let receiving = try await service.create(Self.request())
            for record in [first, queued] {
                _ = try await service.appendAudio(record.id, kind: .inference, sequence: 0, format: Self.mono, data: Self.audio(frames: 8_000))
                _ = try await service.finish(record.id, request: .init(inferenceFrames: 8_000))
            }
            try await fixture.waitForRequest(first.id)
            await service.shutdown()
            for record in [first, queued, receiving] {
                let result = try await service.get(record.id)
                XCTAssertEqual(result.status, .cancelled)
            }
            let health = await service.health()
            XCTAssertFalse(health.ready)
        }
    }

    func testChunkReplayGapAndExactFinishCounts() async throws {
        try await withFixture { service, _ in
            let record = try await service.create(Self.request())
            let chunk = Self.audio(frames: 8_000)
            let first = try await service.appendAudio(record.id, kind: .inference, sequence: 0, format: Self.mono, data: chunk)
            let replay = try await service.appendAudio(record.id, kind: .inference, sequence: 0, format: Self.mono, data: chunk)
            XCTAssertEqual(first.frameCount, 8_000)
            XCTAssertEqual(replay.frameCount, first.frameCount)
            XCTAssertEqual(replay.nextSequence, 1)
            do {
                _ = try await service.appendAudio(record.id, kind: .inference, sequence: 2, format: Self.mono, data: chunk)
                XCTFail("Gaps must be rejected")
            } catch let error as ServiceError { XCTAssertEqual(error.code, "missing_chunk") }
            var other = chunk; other[0] = 1
            do {
                _ = try await service.appendAudio(record.id, kind: .inference, sequence: 0, format: Self.mono, data: other)
                XCTFail("Conflicting repeated bytes must be rejected")
            } catch let error as ServiceError { XCTAssertEqual(error.code, "conflicting_chunk") }
            do {
                _ = try await service.finish(record.id, request: .init(inferenceFrames: 7_999))
                XCTFail("A partial upload must not run inference")
            } catch let error as ServiceError { XCTAssertEqual(error.code, "incomplete_audio") }
            let pending = try await service.get(record.id)
            XCTAssertEqual(pending.status, .receiving)
            _ = try await service.cancel(record.id)
        }
    }

    func testServerOwnsPipelineArtifactsSharedHistoryAndReceipts() async throws {
        try await withFixture { service, fixture in
            var preferences = await service.getPreferences()
            preferences.preferences.dictionary = PersonalDictionary(lists: [DictionaryList(name: "Work", entries: [DictionaryEntry(term: "Codex", aliases: ["code ex"])])])
            preferences.preferences.textCorrectionEnabled = true
            _ = try await service.updatePreferences(preferences)
            let record = try await service.create(Self.request())
            _ = try await service.appendAudio(record.id, kind: .inference, sequence: 0, format: Self.mono, data: Self.audio(frames: 8_000))
            _ = try await service.finish(record.id, request: .init(inferenceFrames: 8_000))
            var completed: GenerationRecord?
            for await event in try await service.events(record.id) {
                if event.status.isTerminal { completed = event }
            }
            let result = try XCTUnwrap(completed)
            XCTAssertEqual(result.status, .completed, result.error ?? "")
            XCTAssertEqual(result.rawText, "hello code ex.")
            XCTAssertEqual(result.finalText, "Hello Codex.")
            XCTAssertEqual(result.insertionText, "Hello Codex. ")
            XCTAssertEqual(result.device.name, "Test Mac")
            XCTAssertEqual(result.textProcessing?.status, .applied)
            XCTAssertEqual(result.textProcessing?.proposedText, "Hello Codex.")
            XCTAssertEqual(result.settings.preferences.proofreadingPrompt, ServerPreferences.defaultProofreadingPrompt)
            XCTAssertEqual(result.proofreadingHints?.includedTerms, ["Codex"])
            let wav = try await service.artifact(record.id, filename: "inference.wav")
            XCTAssertEqual(try Data(contentsOf: wav).count, 32_044)
            let transcript = try await service.artifact(record.id, filename: "transcript.txt")
            XCTAssertEqual(try String(contentsOf: transcript, encoding: .utf8), "Hello Codex.")
            let receipt = try await service.recordDelivery(record.id, receipt: .init(status: "inserted"))
            XCTAssertEqual(receipt.delivery?.status, "inserted")
            do {
                _ = try await service.recordDelivery(record.id, receipt: .init(status: "copied"))
                XCTFail("Conflicting delivery receipts must not overwrite the actual outcome")
            } catch let error as ServiceError { XCTAssertEqual(error.status, 409) }
            let reopened = try GenerationService(configuration: fixture.configuration)
            let page = try await reopened.history(limit: 50, before: nil)
            XCTAssertEqual(page.items.count, 1)
            XCTAssertEqual(page.items.first?.finalText, "Hello Codex.")
            XCTAssertEqual(page.items.first?.delivery?.status, "inserted")
            await reopened.shutdown()
        }
    }

    func testOriginalRetentionAndSettingsAreFrozenAtAdmission() async throws {
        try await withFixture(keepOriginal: true) { service, _ in
            let record = try await service.create(Self.request())
            var update = await service.getPreferences()
            update.preferences.keepOriginalAudio = false
            update.preferences.proofreadingPrompt = "Keep every word and return only the transcript."
            update.preferences.dictionary = PersonalDictionary(lists: [DictionaryList(name: "Terms", entries: [
                DictionaryEntry(term: "auth", isPriority: true),
            ])])
            let changed = try await service.updatePreferences(update)
            XCTAssertEqual(changed.revision, update.revision + 1)
            do { _ = try await service.updatePreferences(update); XCTFail("Stale preferences must not overwrite another device") }
            catch let error as ServiceError { XCTAssertEqual(error.code, "stale_preferences") }
            let audio = Self.audio(frames: 8_000)
            _ = try await service.appendAudio(record.id, kind: .inference, sequence: 0, format: Self.mono, data: audio)
            do { _ = try await service.finish(record.id, request: .init(inferenceFrames: 8_000)); XCTFail("Frozen retention requires original audio") }
            catch let error as ServiceError { XCTAssertEqual(error.code, "incomplete_original") }
            _ = try await service.appendAudio(record.id, kind: .original, sequence: 0, format: Self.mono, data: audio)
            _ = try await service.finish(record.id, request: .init(inferenceFrames: 8_000, originalFrames: 8_000))
            for await _ in try await service.events(record.id) { }
            let completed = try await service.get(record.id)
            XCTAssertEqual(completed.originalAudio?.frameCount, 8_000)
            XCTAssertTrue(completed.settings.preferences.keepOriginalAudio)
            XCTAssertEqual(completed.settings.preferences.proofreadingPrompt, ServerPreferences.defaultProofreadingPrompt)
            let next = try await service.create(Self.request())
            XCTAssertEqual(next.settings.preferences.proofreadingPrompt, changed.preferences.proofreadingPrompt)
            XCTAssertEqual(next.settings.preferences.dictionary.vocabularyTerms, ["auth"])
            _ = try await service.cancel(next.id)
        }
    }

    func testSharedPromptDefaultsValidationAndRestartPersistence() async throws {
        let old = Data(#"{"language":"en","cleanText":true,"vocabulary":"","dictionary":{"lists":[]},"textCorrectionEnabled":true,"keepOriginalAudio":true}"#.utf8)
        let decoded = try V07API.decoder().decode(ServerPreferences.self, from: old)
        XCTAssertEqual(decoded.proofreadingPrompt, ServerPreferences.defaultProofreadingPrompt)
        var vocabulary = decoded
        vocabulary.vocabulary = "auth\u{200B}"
        XCTAssertNotNil(vocabulary.validationError)
        vocabulary.vocabulary = "auth\tmiddleware\nV07"
        XCTAssertNil(vocabulary.validationError)
        XCTAssertEqual(vocabulary.dictionary.recognitionVocabularyTerms(vocabulary.vocabulary), ["auth middleware", "V07"])
        try await withFixture { service, fixture in
            var update = await service.getPreferences()
            for invalid in ["  \n", String(repeating: "x", count: 4097), "bad\0prompt"] {
                update.preferences.proofreadingPrompt = invalid
                do { _ = try await service.updatePreferences(update); XCTFail("Invalid prompt saved") }
                catch let error as ServiceError { XCTAssertEqual(error.status, 400) }
            }
            update.preferences.proofreadingPrompt = "Preserve intentional repetition. Return only the transcript."
            let saved = try await service.updatePreferences(update)
            let reopened = try GenerationService(configuration: fixture.configuration)
            let restored = await reopened.getPreferences()
            XCTAssertEqual(restored, saved)
            await reopened.shutdown()
        }
    }

    func testRestartFailsPartialRecordingAndRemovesTemporaryAudio() async throws {
        try await withFixture { service, fixture in
            let record = try await service.create(Self.request())
            _ = try await service.appendAudio(record.id, kind: .inference, sequence: 0, format: Self.mono, data: Self.audio(frames: 8_000))
            // Simulate a fresh process reading its own data directory after a crash.
            let restarted = try GenerationService(configuration: fixture.configuration)
            let recovered = try await restarted.get(record.id)
            XCTAssertEqual(recovered.status, .failed)
            XCTAssertTrue(recovered.error?.contains("restarted") == true)
            let raw = fixture.configuration.dataDirectory.appendingPathComponent("generations/\(record.id.uuidString)/inference.raw")
            XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
            await restarted.shutdown()
        }
    }

    func testDictionaryExpansionPreservesFullSourceAndReadableHistory() async throws {
        let source = Array(repeating: "alias", count: 300).joined(separator: " ")
        try await withFixture(speechText: source, proofText: source) { service, fixture in
            var preferences = await service.getPreferences()
            preferences.preferences.textCorrectionEnabled = true
            preferences.preferences.dictionary = PersonalDictionary(lists: [DictionaryList(name: "Terms", entries: [
                DictionaryEntry(term: "a" + String(repeating: "\u{0301}", count: 2_048), aliases: ["alias"]),
            ])])
            _ = try await service.updatePreferences(preferences)
            let record = try await service.create(Self.request())
            _ = try await service.appendAudio(record.id, kind: .inference, sequence: 0, format: Self.mono, data: Self.audio(frames: 8_000))
            _ = try await service.finish(record.id, request: .init(inferenceFrames: 8_000))
            for await _ in try await service.events(record.id) { }
            let completed = try await service.get(record.id)
            XCTAssertEqual(completed.status, .completed, completed.error ?? "")
            XCTAssertEqual(completed.rawText, source)
            XCTAssertEqual(completed.finalText, source)
            XCTAssertEqual(completed.textProcessing?.status, .unchanged)
            let restarted = try GenerationService(configuration: fixture.configuration)
            let restored = try await restarted.get(record.id)
            XCTAssertEqual(restored.finalText, source)
            await restarted.shutdown()
        }
    }

    func testOversizedMetadataFailsWithoutPoisoningRestartOrLosingAudio() async throws {
        try await withFixture(speechText: String(repeating: "a", count: 220_000)) { service, fixture in
            let record = try await service.create(Self.request())
            _ = try await service.appendAudio(record.id, kind: .inference, sequence: 0, format: Self.mono, data: Self.audio(frames: 8_000))
            _ = try await service.finish(record.id, request: .init(inferenceFrames: 8_000))
            for await _ in try await service.events(record.id) { }
            let failed = try await service.get(record.id)
            XCTAssertEqual(failed.status, .failed)
            XCTAssertTrue(failed.error?.contains("metadata") == true, failed.error ?? "")
            let metadata = try await service.artifact(record.id, filename: "metadata.json")
            XCTAssertLessThanOrEqual(try Data(contentsOf: metadata).count, 1_048_576)
            let restarted = try GenerationService(configuration: fixture.configuration)
            let restored = try await restarted.get(record.id)
            XCTAssertEqual(restored.status, .failed)
            let audio = try await restarted.artifact(record.id, filename: "inference.wav")
            XCTAssertEqual(try Data(contentsOf: audio).count, 32_044)
            await restarted.shutdown()
        }
    }

    func testOversizedPreferencesKeepPriorRevisionAndReadableStoredState() async throws {
        try await withFixture { service, fixture in
            let previous = await service.getPreferences()
            let url = fixture.configuration.dataDirectory.appendingPathComponent("preferences.json")
            let priorData = try Data(contentsOf: url)
            var update = previous
            let entries = (0..<20).map { index in
                DictionaryEntry(term: "term\(index)" + String(repeating: "\u{0301}", count: 8_000))
            }
            update.preferences.dictionary = PersonalDictionary(lists: [DictionaryList(name: "Terms", entries: entries)])
            XCTAssertNil(update.preferences.validationError)
            do { _ = try await service.updatePreferences(update); XCTFail("Oversized preferences must not be saved") }
            catch let error as ServiceError { XCTAssertEqual(error.code, "preferences_too_large") }
            let unchanged = await service.getPreferences()
            XCTAssertEqual(unchanged, previous)
            XCTAssertEqual(try Data(contentsOf: url), priorData)
            let restarted = try GenerationService(configuration: fixture.configuration)
            let restored = await restarted.getPreferences()
            XCTAssertEqual(restored, previous)
            await restarted.shutdown()
        }
    }

    func testSealingFailureTerminatesGenerationAndReleasesAdmission() async throws {
        try await withFixture(keepOriginal: true) { service, fixture in
            let record = try await service.create(Self.request())
            for kind in [AudioKind.inference, .original] {
                _ = try await service.appendAudio(record.id, kind: kind, sequence: 0, format: Self.mono, data: Self.audio(frames: 8_000))
            }
            let original = fixture.configuration.dataDirectory.appendingPathComponent("generations/\(record.id.uuidString)/original.raw")
            try FileManager.default.removeItem(at: original)
            do {
                _ = try await service.finish(record.id, request: .init(inferenceFrames: 8_000, originalFrames: 8_000))
                XCTFail("An audio storage failure must fail the take")
            } catch let error as ServiceError { XCTAssertEqual(error.code, "audio_storage_failed") }
            let failed = try await service.get(record.id)
            XCTAssertEqual(failed.status, .failed)
            let next = try await service.create(Self.request())
            XCTAssertNotEqual(next.id, record.id)
            _ = try await service.cancel(next.id)
        }
    }

    func testHTTPAuthenticationAndOriginBoundary() async throws {
        try await withFixture { service, _ in
            let token = String(repeating: "t", count: 32)
            let app = Application(router: V07HTTPServer.makeRouter(service: service, token: token))
            try await app.test(.router) { client in
                try await client.execute(uri: "/v1/health", method: .get) { response in XCTAssertEqual(response.status, .ok) }
                try await client.execute(uri: "/v1/preferences", method: .get) { response in
                    XCTAssertEqual(response.status, .unauthorized)
                    let error = try V07API.decoder().decode(APIErrorResponse.self, from: Data(response.body.readableBytesView))
                    XCTAssertEqual(error.code, "unauthorized")
                }
                try await client.execute(uri: "/v1/preferences", method: .get, headers: [.authorization: "Bearer \(token)"]) { response in
                    XCTAssertEqual(response.status, .ok)
                }
                try await client.execute(uri: "/v1/preferences", method: .get,
                                         headers: [.authorization: "Bearer \(token)", .origin: "https://example.com"]) { response in
                    XCTAssertEqual(response.status, .forbidden)
                }
                try await client.execute(uri: "/v1/generations/not-a-uuid", method: .get,
                                         headers: [.authorization: "Bearer \(token)"]) { response in XCTAssertEqual(response.status, .badRequest) }
                try await client.execute(uri: "/v1/preferences", method: .put,
                                         headers: [.authorization: "Bearer \(token)"], body: ByteBuffer(repeating: 0, count: 262_145)) { response in
                    XCTAssertEqual(response.status, .contentTooLarge)
                }
            }
        }
    }

    func testArtifactAllowlistRejectsPathsAndSymbolicLinks() async throws {
        try await withFixture { service, fixture in
            let record = try await service.create(Self.request())
            _ = try await service.cancel(record.id)
            do {
                _ = try await service.artifact(record.id, filename: "../../preferences.json")
                XCTFail("Caller paths must never select a server file")
            } catch let error as ServiceError { XCTAssertEqual(error.status, 404) }
            let metadata = fixture.configuration.dataDirectory.appendingPathComponent("generations/\(record.id.uuidString)/metadata.json")
            try FileManager.default.removeItem(at: metadata)
            try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: fixture.configuration.dataDirectory.appendingPathComponent("preferences.json"))
            do {
                _ = try await service.artifact(record.id, filename: "metadata.json")
                XCTFail("An artifact must not follow a symbolic link")
            } catch let error as ServiceError { XCTAssertEqual(error.status, 404) }
        }
    }

    func testDeletedContinuationDoesNotDiscardNewRecording() async throws {
        try await withFixture { service, _ in
            let previous = try await service.create(Self.request())
            _ = try await service.appendAudio(previous.id, kind: .inference, sequence: 0, format: Self.mono, data: Self.audio(frames: 8_000))
            _ = try await service.finish(previous.id, request: .init(inferenceFrames: 8_000))
            for await _ in try await service.events(previous.id) { }
            _ = try await service.recordDelivery(previous.id, receipt: .init(status: "inserted"))
            try await service.delete(previous.id)
            let current = try await service.create(Self.request())
            _ = try await service.appendAudio(current.id, kind: .inference, sequence: 0, format: Self.mono, data: Self.audio(frames: 8_000))
            _ = try await service.finish(current.id, request: .init(inferenceFrames: 8_000, continuationID: previous.id))
            for await _ in try await service.events(current.id) { }
            let result = try await service.get(current.id)
            XCTAssertEqual(result.status, .completed, result.error ?? "")
            XCTAssertEqual(result.finalText, "hello code ex.")
            XCTAssertEqual(result.insertionText, "hello code ex. ")
            let next = try await service.create(Self.request())
            _ = try await service.cancel(next.id)
        }
    }

    func testTokenlessHTTPRejectsForeignHostWithoutOrigin() async throws {
        try await withFixture { service, _ in
            let app = Application(router: V07HTTPServer.makeRouter(service: service))
            try await app.test(.router) { client in
                for host in ["localhost:8391", "127.0.0.1:8391", "[::1]:8391"] {
                    try await client.execute(uri: "/v1/preferences", method: .get, headers: [.init("Host")!: host]) { response in
                        XCTAssertEqual(response.status, .ok)
                    }
                }
                for host in ["rebind.example:8391", "localhost.evil.example", "evil@localhost:8391", "127.0.0.1:8391:9"] {
                    try await client.execute(uri: "/v1/preferences", method: .get, headers: [.init("Host")!: host]) { response in
                        XCTAssertEqual(response.status, .forbidden)
                        let error = try V07API.decoder().decode(APIErrorResponse.self, from: Data(response.body.readableBytesView))
                        XCTAssertEqual(error.code, "host_rejected")
                    }
                }
            }
        }
    }

    private static let mono = AudioStreamFormat(sampleRate: 16_000, channels: 1)
    private static func request() -> CreateGenerationRequest { CreateGenerationRequest(device: .init(id: "mac-test", name: "Test Mac")) }
    private static func audio(frames: Int) -> Data { Data(repeating: 0, count: frames * 4) }

    private func withFixture(keepOriginal: Bool = false, speechText: String = "hello code ex.", proofText: String = "Hello Codex.", blockSpeech: Bool = false,
                             _ work: (GenerationService, Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(speechText: speechText, proofText: proofText, blockSpeech: blockSpeech)
        let inference = NativeInference(configuration: fixture.configuration.inference)
        try await inference.warmUp()
        let service = try GenerationService(configuration: fixture.configuration, inference: inference)
        var preferences = await service.getPreferences()
        preferences.preferences.keepOriginalAudio = keepOriginal
        preferences.preferences.textCorrectionEnabled = false
        _ = try await service.updatePreferences(preferences)
        await service.start()
        do { try await work(service, fixture) }
        catch { await service.shutdown(); fixture.remove(); throw error }
        await service.shutdown()
        fixture.remove()
    }

    private struct Fixture {
        let directory: URL
        let configuration: ServerConfiguration
        init(speechText: String, proofText: String, blockSpeech: Bool) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("v07-service-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if blockSpeech { try Data().write(to: directory.appendingPathComponent("hold-speech")) }
            let helper = directory.appendingPathComponent("helper")
            let model = directory.appendingPathComponent("model")
            try Data("fixture model".utf8).write(to: model)
            try JSONEncoder().encode(speechText).write(to: directory.appendingPathComponent("speech.json"))
            try JSONEncoder().encode(proofText).write(to: directory.appendingPathComponent("proof.json"))
            let script = #"""
            #!/bin/sh
            printf '{"type":"ready","engineVersion":"fixture-1"}\n'
            while IFS= read -r line; do
                id=$(printf '%s' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                case "$line" in
                  *'"type":"correct"'*) text=$(cat "$(dirname "$0")/proof.json") ;;
                  *)
                    printf '%s\n' "$line" >> "$(dirname "$0")/requests.log"
                    while [ -f "$(dirname "$0")/hold-speech" ]; do sleep 0.01; done
                    text=$(cat "$(dirname "$0")/speech.json") ;;
                esac
                printf '{"type":"result","id":"%s","text":%s,"duration":0.5,"elapsed":0.01,"language":"en"}\n' "$id" "$text"
            done
            """#
            try Data(script.utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            var runtime = InferenceConfiguration(speechHelper: helper, speechModel: model, vadModel: model,
                                                  proofHelper: helper, proofModel: model)
            runtime.modelVerification = .fixture(speechSHA256: nil, proofSHA256: nil)
            configuration = try ServerConfiguration(dataDirectory: directory.appendingPathComponent("state"), development: true, inference: runtime)
        }
        func releaseSpeech() throws {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("hold-speech"))
        }
        func speechRequests() throws -> [String] {
            try String(contentsOf: directory.appendingPathComponent("requests.log"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }
        func waitForRequest(_ id: UUID) async throws {
            for _ in 0..<500 {
                if (try? speechRequests().contains { $0.contains(id.uuidString) }) == true { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ServiceError(500, "test_timeout", "The fixture never received generation \(id).")
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
