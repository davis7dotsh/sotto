import SottoCore
import SwiftUI

private enum SottoPage: String, CaseIterable, Identifiable {
    case dictation = "Dictation"
    case history = "History"
    case microphone = "Microphone"
    case server = "Server preferences"
    case device = "This Mac"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .dictation: "waveform"
        case .history: "clock.arrow.circlepath"
        case .microphone: "mic"
        case .server: "server.rack"
        case .device: "laptopcomputer"
        }
    }
}

struct SottoWindowView: View {
    @ObservedObject var controller: SottoController
    @State private var page: SottoPage = .dictation

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    SottoAppIcon(size: 36)
                    Text("Sotto").font(.system(size: 27, weight: .regular, design: .serif))
                    DevBadge()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.top, 22)

                List(SottoPage.allCases) { destination in
                    Button { page = destination } label: {
                        Label(destination.rawValue, systemImage: destination.symbol)
                            .font(.system(size: 13, weight: page == destination ? .medium : .regular))
                            .foregroundStyle(page == destination ? SottoPalette.ink : SottoPalette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 37)
                            .background(page == destination ? SottoPalette.tint : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("navigation.\(destination.id)")
                    .accessibilityAddTraits(page == destination ? .isSelected : [])
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                ServerConnectionStatus(controller: controller, compact: true)
                    .padding(18)
            }
            .background { SottoSidebarSurface() }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
        } detail: {
            Group {
                switch page {
                case .dictation:
                    DictationPage(controller: controller, showPreferences: { page = .device }, showHistory: { page = .history })
                case .history: HistoryPage(controller: controller)
                case .microphone: MicrophonePage(controller: controller)
                case .server: ServerPreferencesPage(controller: controller)
                case .device: DevicePreferencesPage(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SottoPalette.canvas)
            .navigationTitle("\(SottoBuild.current.displayName) · \(page.rawValue)")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 580)
        .tint(SottoPalette.accent)
        .onExitCommand {
            if controller.isBusy && controller.canCancelWithEscape { controller.cancelDictation() }
        }
    }
}

struct DevBadge: View {
    var body: some View {
        if SottoBuild.current.isDevelopment {
            Text("Dev")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SottoPalette.accentInk)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(SottoPalette.tint, in: Capsule())
                .accessibilityLabel("Development build")
        }
    }
}

struct ServerConnectionStatus: View {
    @ObservedObject var controller: SottoController
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: controller.isServerReady ? SottoPalette.success : SottoPalette.warning)
            Text(controller.serverStatusMessage)
                .font(compact ? .caption : .callout)
                .foregroundStyle(SottoPalette.ink)
                .lineLimit(compact ? 2 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text(controller.preferences.endpoint)
                    .font(.caption)
                    .foregroundStyle(SottoPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .trailing)
            }
            if controller.isCheckingServer {
                ProgressView().controlSize(.mini).frame(width: 18)
            }
        }
        .frame(minHeight: compact ? 30 : 22)
        .help(controller.serverStatusMessage)
        .accessibilityIdentifier("server.status")
    }
}

struct DictationPage: View {
    @ObservedObject var controller: SottoController
    var showPreferences: () -> Void
    var showHistory: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 20) {
                    SottoHoldKeyCap(key: controller.shortcut, isPressed: controller.isRecording)
                    Text("Hold to dictate.")
                        .font(.system(size: 28, weight: .medium))
                        .tracking(-0.7)
                    Spacer()
                }
                .padding(.top, 8)

                HStack {
                    ServerConnectionStatus(controller: controller)
                    Button("Check connection") { controller.refreshServer() }
                        .disabled(controller.isCheckingServer)
                        .accessibilityIdentifier("dictation.refresh-server")
                }
                .frame(height: 32)

                if !controller.allPermissionsGranted {
                    VStack(spacing: 10) {
                        PermissionRow(title: "Microphone", detail: "Capture your voice while dictating.",
                                      granted: controller.permissions.microphone, action: controller.requestMicrophone)
                        PermissionRow(title: "Accessibility", detail: "Use the hold key and insert text.",
                                      granted: controller.permissions.accessibility, action: controller.requestAccessibility)
                        HStack { PermissionHelpButton(); Spacer() }
                    }
                }

                HStack(spacing: 10) {
                    Text(controller.recoveryMessage ?? "")
                        .font(.caption)
                        .foregroundStyle(SottoPalette.muted)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry synchronization", action: controller.retryPendingRecordings)
                        .disabled(controller.pendingRecordingCount == 0 || controller.isBusy)
                        .opacity(controller.pendingRecordingCount == 0 ? 0 : 1)
                }
                .frame(height: 34)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(controller.isBusy ? "Current dictation" : "Last dictation").font(.headline)
                        Spacer()
                        Button { controller.copyLastTranscript() } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .disabled(controller.lastTranscript.isEmpty || controller.isBusy)
                    }
                    .frame(height: 28)
                    Divider()
                    transcript
                        .frame(height: 205)
                        .accessibilityIdentifier("dictation.transcript")
                    Divider()
                    HStack {
                        Text(controller.errorMessage ?? controller.lastDelivery)
                            .foregroundStyle(controller.errorMessage == nil ? SottoPalette.muted : SottoPalette.warning)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !controller.isBusy, let seconds = controller.lastAudioSeconds {
                            Text("\(seconds, specifier: "%.1f") s audio").monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .frame(height: 34, alignment: .top)
                }

                HStack(spacing: 12) {
                    SottoDictationButton(controller: controller, identifier: "dictation.toggle")
                    SottoMicrophoneTestButton(controller: controller, identifier: "dictation.test")
                    Button("History", action: showHistory)
                    Button { showPreferences() } label: { Image(systemName: "gearshape") }
                        .help("This Mac preferences")
                        .accessibilityLabel("This Mac preferences")
                }
            }
            .padding(30)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    @ViewBuilder private var transcript: some View {
        if controller.isBusy {
            HStack(spacing: 20) {
                if controller.isRecording {
                    RecordingWaveform(feedback: controller.recordingFeedback, height: 34)
                } else {
                    ProgressView().controlSize(.small).frame(width: 51)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(controller.statusMessage).font(.headline)
                    if controller.isRecording {
                        HStack {
                            RecordingElapsedTime(feedback: controller.recordingFeedback)
                            Text(controller.recordingInputName ?? controller.selectedInputName)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(SottoPalette.muted)
                    }
                }
                Spacer()
                Button { controller.cancelDictation() } label: { Image(systemName: "xmark") }
                    .help("Cancel dictation")
                    .accessibilityLabel("Cancel dictation")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(controller.lastTranscript.isEmpty ? "Your next thought will appear here." : controller.lastTranscript)
                    .font(.body)
                    .lineSpacing(4)
                    .foregroundStyle(controller.lastTranscript.isEmpty ? SottoPalette.muted : SottoPalette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        }
    }
}

struct SottoPageHeading: View {
    var title: String
    var body: some View {
        Text(title)
            .font(.system(size: 26, weight: .semibold))
            .tracking(-0.7)
            .foregroundStyle(SottoPalette.ink)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SottoMicrophoneTestButton: View {
    @ObservedObject var controller: SottoController
    var identifier: String
    var idleTitle = "Test microphone"
    private var isHeldFn: Bool { controller.isTestRecording && !controller.canCancelWithEscape }

    var body: some View {
        Button(action: controller.toggleTestRecording) {
            Label(isHeldFn ? "Release fn to finish" : (controller.isTestRecording ? "Finish test" : idleTitle),
                  systemImage: controller.isTestRecording ? "stop.fill" : "mic")
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(SottoPrimaryButtonStyle())
        .disabled(isHeldFn || (!controller.canTest && !controller.isTestRecording))
        .help("Test \(controller.selectedInputName) without pasting text")
        .accessibilityIdentifier(identifier)
    }
}

struct SottoDictationButton: View {
    @ObservedObject var controller: SottoController
    var identifier: String
    private var isHeldFn: Bool { controller.isCapturing && !controller.canCancelWithEscape }

    var body: some View {
        Button(action: controller.toggleDictation) {
            Label(isHeldFn ? "Release fn to finish" : controller.isCapturing ? "Finish dictation" : "Start dictation",
                  systemImage: controller.isCapturing ? "stop.fill" : "mic.fill")
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(SottoPrimaryButtonStyle())
        .disabled(isHeldFn || (!controller.canTest && !controller.isCapturing))
        .accessibilityIdentifier(identifier)
    }
}
