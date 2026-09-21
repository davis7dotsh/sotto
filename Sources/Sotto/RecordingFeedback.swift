import Combine
import Foundation

/// High-frequency feedback is observed only by the waveform and clock leaves.
@MainActor
final class RecordingFeedback: ObservableObject {
    @Published private(set) var levels = Array(repeating: Float(0), count: 9)
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var transferNotice: RecordingTransferNotice?

    func append(_ level: Float) {
        let sample = level.isFinite ? min(1, max(0, level)) : 0
        let next = Array(levels.dropFirst()) + [sample]
        if next != levels { levels = next }
    }

    func updateElapsed(_ elapsed: TimeInterval) {
        // Bound the conversion, rather than capture duration. Large/non-finite
        // clock values must never trap or make a long take wrap its timer.
        let bounded = elapsed.isFinite ? min(Double(Int.max / 2), max(0, elapsed)) : 0
        let seconds = Int(bounded)
        if seconds != elapsedSeconds { elapsedSeconds = seconds }
    }

    func updateTransfer(connected: Bool, catchingUp: Bool = false) {
        let notice: RecordingTransferNotice? = !connected ? .savedLocally : catchingUp ? .transferring : nil
        if transferNotice != notice { transferNotice = notice }
    }

    func clearLevels() {
        let silence = Array(repeating: Float(0), count: 9)
        if levels != silence { levels = silence }
    }

    func reset() {
        clearLevels()
        if elapsedSeconds != 0 { elapsedSeconds = 0 }
        if transferNotice != nil { transferNotice = nil }
    }
}

enum RecordingTransferNotice: Equatable {
    case savedLocally
    case transferring

    var text: String {
        switch self {
        case .savedLocally: "Saved locally"
        case .transferring: "Transferring saved audio"
        }
    }

    var accessibilityLabel: String { text }
}
