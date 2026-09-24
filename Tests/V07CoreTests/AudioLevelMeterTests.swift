import XCTest
@testable import V07Core

final class AudioLevelMeterTests: XCTestCase {
    func testQuietSpeechHasAUsefulPerceptualRange() {
        for (decibels, expected) in [(-60.0, 0.16), (-50.0, 0.36), (-40.0, 0.56)] {
            var meter = AudioLevelMeter()
            let level = meter.update(rms: pow(10, decibels / 20), frameCount: 16_000, sampleRate: 16_000)
            XCTAssertEqual(Double(level), expected, accuracy: 0.0001)
        }
        var faint = AudioLevelMeter()
        XCTAssertGreaterThan(faint.update(rms: pow(10, -67.0 / 20), frameCount: 800, sampleRate: 16_000), 0)
    }

    func testAttackUsesAudioDurationRatherThanBufferCount() {
        func measure(_ chunks: [Int]) -> Float {
            var meter = AudioLevelMeter()
            for frames in chunks { meter.update(rms: 0.01, frameCount: frames, sampleRate: 16_000) }
            return meter.level
        }
        let single = measure([1_600])
        XCTAssertEqual(single, measure(Array(repeating: 160, count: 10)), accuracy: 0.000001)
        XCTAssertEqual(single, measure([37, 281, 102, 519, 661]), accuracy: 0.000001)
        XCTAssertGreaterThan(single, 0.55)

        var meter = AudioLevelMeter()
        let firstAttack = meter.update(rms: 1, frameCount: 320, sampleRate: 16_000)
        XCTAssertEqual(firstAttack, 0.63212, accuracy: 0.0001)
        meter.update(rms: 1, frameCount: 16_000, sampleRate: 16_000)
        XCTAssertEqual(meter.update(rms: 0, frameCount: 2_080, sampleRate: 16_000), 0.367879, accuracy: 0.0001)
    }

    func testSilenceSettlesExactlyToZeroAndBelowFloorNoiseStaysStill() {
        var meter = AudioLevelMeter()
        XCTAssertEqual(meter.update(rms: 0, frameCount: 800, sampleRate: 16_000), 0)
        meter.update(rms: 1, frameCount: 16_000, sampleRate: 16_000)
        var previous = meter.level
        for _ in 0..<12 {
            let next = meter.update(rms: 0, frameCount: 800, sampleRate: 16_000)
            XCTAssertLessThanOrEqual(next, previous)
            previous = next
        }
        XCTAssertEqual(meter.level, 0)
        XCTAssertEqual(meter.update(rms: 0.0001, frameCount: 800, sampleRate: 16_000), 0)
    }

    func testInvalidMeasurementsAndTimingCannotPoisonTheMeter() {
        var meter = AudioLevelMeter()
        for rms in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(meter.update(rms: rms, frameCount: 800, sampleRate: 16_000), 0)
        }
        meter.update(rms: 0.01, frameCount: 1_600, sampleRate: 16_000)
        let previous = meter.level
        for rate in [Double.nan, .infinity, 0, -16_000] {
            XCTAssertEqual(meter.update(rms: 1, frameCount: 800, sampleRate: rate), previous)
        }
        for frames in [0, -1] {
            XCTAssertEqual(meter.update(rms: 1, frameCount: frames, sampleRate: 16_000), previous)
        }
        XCTAssertEqual(meter.update(rms: .greatestFiniteMagnitude, frameCount: 16_000, sampleRate: 16_000), 1)
        XCTAssertEqual(meter.update(rms: .nan, frameCount: 16_000, sampleRate: 16_000), 0)
        let recovered = meter.update(rms: 0.001, frameCount: 800, sampleRate: 16_000)
        XCTAssertTrue(recovered.isFinite)
        XCTAssertGreaterThan(recovered, 0.1)
        XCTAssertLessThanOrEqual(recovered, 1)
    }
}
