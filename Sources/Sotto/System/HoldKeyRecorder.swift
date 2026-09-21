import AppKit

/// Lets the user choose a hold key by pressing it instead of picking from a
/// list. While recording, a local event monitor watches flagsChanged events;
/// Sotto is frontmost, so the pressed modifier belongs to the user's intent.
@MainActor
final class HoldKeyRecorder: ObservableObject {
    struct Environment {
        var listen: (@escaping (HoldKey) -> Void) -> HotkeyCancellation
        var delay: (@escaping @MainActor () -> Void) -> HotkeyCancellation

        static var live: Self {
            Self(
                listen: { handler in
                    let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                        if let key = HoldKey(keyCode: event.keyCode) { handler(key) }
                        return event
                    }
                    return HotkeyCancellation { if let monitor { NSEvent.removeMonitor(monitor) } }
                },
                delay: { action in
                    let task = Task { @MainActor in
                        do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                        catch { return }
                        guard !Task.isCancelled else { return }
                        action()
                    }
                    return HotkeyCancellation { task.cancel() }
                }
            )
        }
    }

    @Published private(set) var isRecording = false
    /// The captured key. Nil when recording stopped without a usable press.
    var onCapture: ((HoldKey) -> Void)?
    var onTimeout: (() -> Void)?

    private let environment: Environment
    private var listener: HotkeyCancellation?
    private var timeout: HotkeyCancellation?

    init(environment: Environment = .live) {
        self.environment = environment
    }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        listener = environment.listen { [weak self] in self?.receive($0) }
        timeout = environment.delay { [weak self] in self?.timeOut() }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        listener?.cancel()
        listener = nil
        timeout?.cancel()
        timeout = nil
    }

    func receive(_ key: HoldKey) {
        guard isRecording else { return }
        stop()
        onCapture?(key)
    }

    private func timeOut() {
        stop()
        onTimeout?()
    }
}

extension HoldKey {
    /// The flag-changed key codes monitored for dictation holds.
    init?(keyCode: CGKeyCode) {
        switch keyCode {
        case HoldKey.rightOption.keyCode: self = .rightOption
        case HoldKey.rightControl.keyCode: self = .rightControl
        case HoldKey.fn.keyCode: self = .fn
        default: return nil
        }
    }
}
