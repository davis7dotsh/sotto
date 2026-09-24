import Foundation
@testable import V07ServerKit
import XCTest

final class ServerConfigurationTests: XCTestCase {
    private func inference() -> InferenceConfiguration {
        let url = URL(fileURLWithPath: "/tmp/unused-v07-test-model")
        return InferenceConfiguration(speechHelper: url, speechModel: url, vadModel: url, proofHelper: url, proofModel: url)
    }

    func testPublicBindingRequiresStrongToken() throws {
        let directory = URL(fileURLWithPath: "/tmp/unused-v07-test-data")
        XCTAssertThrowsError(try ServerConfiguration(host: "0.0.0.0", dataDirectory: directory, inference: inference()))
        XCTAssertThrowsError(try ServerConfiguration(host: "100.90.80.70", dataDirectory: directory, token: "short", inference: inference()))
        XCTAssertNoThrow(try ServerConfiguration(host: "0.0.0.0", dataDirectory: directory,
                                                token: String(repeating: "x", count: 32), inference: inference()))
        XCTAssertNoThrow(try ServerConfiguration(dataDirectory: directory, inference: inference()))
    }

    func testWaveHeaderPreservesSampleBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("test.pcm")
        let wave = directory.appendingPathComponent("test.wav")
        let samples = Data([0, 0, 255, 127, 0, 128])
        try samples.write(to: raw)
        try WaveFile.write(rawURL: raw, outputURL: wave, sampleRate: 16000, channels: 1, float: false)
        let result = try Data(contentsOf: wave)
        XCTAssertEqual(result.count, 44 + samples.count)
        XCTAssertEqual(String(data: result.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(result.suffix(samples.count), samples)
        XCTAssertEqual(Array(result[20..<24]), [1, 0, 1, 0])
        XCTAssertEqual(Array(result[24..<28]), [128, 62, 0, 0])
    }
}
