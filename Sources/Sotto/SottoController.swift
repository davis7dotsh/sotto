import AppKit
import Combine
import SottoAPI
import SottoCore
import ServiceManagement

private enum DictationDestination: Equatable {
    case test
    case field(InsertionTarget)
}

struct WisprFlowImportCounts {
    var processed = 0
    var total = 0
    var imported = 0
    var enriched = 0
    var skipped = 0
    var partial = 0
    var failed = 0
    var dictionaryArchived = false
    var warning: String?
    var unarchivedWarning: String?
}

enum WisprFlowImportState {
    case idle
    case preparing
    case preview(WisprFlowImportPreview, knownCount: Int?, destinationError: String?)
    case running(WisprFlowImportPreview, WisprFlowImportCounts)
    case finished(WisprFlowImportPreview, WisprFlowImportCounts, cancelled: Bool)
    case failed(String)
}

/// The snapshot worker is independent of the main actor. This gate lets quit
/// wait for it and close a reader that has not yet reached the controller.
private final class WisprFlowPreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let work = DispatchGroup()
    private var cancelled = false
    private var reader: WisprFlowSourceReader?

    init() { work.enter() }
    func finish() { work.leave() }

    func register(_ value: WisprFlowSourceReader) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        reader = value
        return true
    }

    func transfer(_ value: WisprFlowSourceReader) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, reader === value else { return false }
        reader = nil
        return true
    }

    func cancel(waitForWorker: Bool = false) {
        lock.lock()
        cancelled = true
        let value = reader
        reader = nil
        lock.unlock()
        if waitForWorker {
            value?.close()
            work.wait()
        } else if let value {
            Task.detached(priority: .utility) { value.close() }
        }
    }
}

/// Capture stays durable on this Mac until the server completes a session.
/// Live processing is independent of network availability and delivery happens once.
@MainActor
final class SottoController: ObservableObject {
    @Published var activity: DictationActivity = .idle
    let recordingFeedback = RecordingFeedback()
    @Published var recordingListHint: String?
    @Published private(set) var recordingInputName: String?
    @Published var lastTranscript = ""
    @Published var lastTranscriptionSeconds: Double?
    @Published var lastAudioSeconds: Double?
    @Published var lastDelivery = ""
    @Published private(set) var lastDeliveryStatus: DictationDeliveryStatus = .none
    @Published var errorMessage: String?
    @Published var permissions: PermissionSnapshot
    @Published var isHotkeyActive = false
    @Published private(set) var isCheckingShortcut = false
    @Published private(set) var shortcutCheckText = ""
    @Published var shortcut: HoldKey = .rightOption {
        didSet {
            if shortcut != oldValue { stopShortcutCheck() }
            if !applyingConfiguration { configuration.update { $0.holdKey = shortcut.rawValue } }
            hotkey.key = shortcut
        }
    }
    @Published var launchAtLogin = false {
        didSet {
            guard hasInitialized, !applyingConfiguration, !updatingLogin, launchAtLogin != oldValue else { return }
            configuration.update { $0.launchAtLogin = launchAtLogin }
            updateLoginItem()
        }
    }
    @Published private(set) var loginItemError: String?
    @Published var statusMessage = "Connecting to server…"
    @Published private(set) var serverHealth: ServerHealth?
    @Published private(set) var serverStatusMessage = "Connecting…"
    @Published private(set) var isCheckingServer = false
    @Published private(set) var isSavingPreferences = false
    @Published private(set) var sharedPreferences: PreferencesSnapshot?
    @Published private(set) var generations: [GenerationRecord] = []
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var hasMoreHistory = false
    @Published private(set) var historySourceFilter = "all"
    @Published private(set) var wisprFlowImportState: WisprFlowImportState = .idle
    private var historyCursor: String?
    private var recordingHistoryCursor: String?
    private var historyRevision = 0
    private var recordingHistoryIDs = Set<UUID>()
    private var recordingSnapshots: [UUID: RecordingSnapshot] = [:]
    private var selectedGenerationDetailID: UUID?
    @Published private(set) var generationDetails: [UUID: GenerationRecord] = [:]
    @Published private(set) var loadingGenerationDetails = Set<UUID>()
    @Published private(set) var pendingRecordingCount = 0
    @Published private(set) var pendingRecordings: [RecordingSnapshot] = []
    @Published private(set) var recoveryMessage: String?
    private var recoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingSpools: [UUID: RecordingSpool] = [:]
    private var recoveredSpoolIDs = Set<UUID>()
    private var wisprFlowReader: WisprFlowSourceReader?
    private var wisprFlowPrepareTask: Task<Void, Never>?
    private var wisprFlowPrepareGate: WisprFlowPreparationGate?
    private var wisprFlowPrepareRevision = 0
    private var wisprFlowImportTask: Task<Void, Never>?
    private var wisprFlowMaterializationTask: Task<WisprFlowSourceSession, Error>?
    private var wisprFlowImportRevision = 0
    private var wisprFlowActiveReaders: [Int: WisprFlowSourceReader] = [:]
    private var wisprFlowDestinationEndpoint: String?
    let configuration: ConfigurationStore
    let microphones: MicrophonePreferencesStore
    let preferences: ClientPreferencesStore

    var isRecording: Bool { activity == .recording }
    var isTestRecording: Bool { isTestSession && isCapturing }
    var isCapturing: Bool { activity.isCapturing }
    var recordingUsesClipboard: Bool { isCapturing && insertionDestination == .clipboard }
    var isBusy: Bool { activity.isBusy }
    var canCancelWithEscape: Bool { !hotkey.isHoldingFn }
    var isServerReady: Bool { serverHealth?.ready == true && serverHealth?.apiVersion == SottoAPI.version }
    var canTest: Bool { isServerReady && permissions.microphone && microphones.resolution.device != nil && !isBusy }
    var selectedInputName: String { microphones.resolution.device?.name ?? "No microphone available" }
    var allPermissionsGranted: Bool { permissions.microphone && permissions.accessibility }
    var onHUDVisibility: ((Bool) -> Void)?
    var onShowWindow: (() -> Void)?

    private let recorder = AudioRecorder()
    private let audioDevices = AudioDeviceStore()
    private let hotkey = HotkeyMonitor()
    private let inserter = TextInserter()
    private let serverSession: URLSession
    private var subscriptions: Set<AnyCancellable> = []
    private var applyingConfiguration = false
    private var recordingTimer: Timer?
    private var recordingStart: TimeInterval = 0
    private var recordingBaseSeconds: TimeInterval = 0
    private var capturePowerActivity: NSObjectProtocol?
    private var microphoneStartTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var recordingTask: Task<GenerationRecord, Error>?
    private var recordingContextTask: Task<Void, Never>?
    private var recordingTransport: RecordingClient?
    private var activeSpool: RecordingSpool?
    private var recordingConnected = false
    private var suppressDelivery = false
    private var isToggleSession = false
    private var isDiscarding = false
    private var isPreparingToQuit = false
    private var resumingRecordingID: UUID?
    private var refreshTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var shortcutCheckTask: Task<Void, Never>?
    private var shortcutCheckStarted: TimeInterval = 0
    private var shortcutCheckEntries: [String] = []
    private var sessionID = UUID()
    private var activeGenerationID: UUID?
    private var activeClient: ServerClient?
    @Published private var insertionDestination: InsertionDestination?
    private var destinationTask: InsertionDestinationCapture?
    private var recordingClipboardChangeCount = 0
    private struct ContinuationAnchor {
        let destination: DictationDestination
        let generationID: UUID
        let continuation: DictationContinuation
        let timestamp: TimeInterval
    }
    private var continuationAnchors: [ContinuationAnchor] = []
    private var isTestSession = false
    private var updatingLogin = false
    private var hasInitialized = false
    private var isShuttingDown = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?

    init(configuration: ConfigurationStore, startServices: Bool = true, serverSession: URLSession = .shared) {
        self.configuration = configuration
        self.serverSession = serverSession
        preferences = ClientPreferencesStore(root: configuration.url.deletingLastPathComponent())
        microphones = MicrophonePreferencesStore(configuration: configuration)
        permissions = startServices ? PermissionSnapshot.capture()
            : PermissionSnapshot(microphone: false, accessibility: false, inputMonitoring: false)
        applyConfiguration(configuration.configuration)
        hotkey.key = shortcut
        microphones.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        configuration.$configuration.removeDuplicates().sink { [weak self] in self?.applyConfiguration($0) }.store(in: &subscriptions)
        guard startServices else { return }
        bindServices()
        audioDevices.start()
        installLifecycleObservers()
        refreshPermissions()
        CapturedAudio.cleanupOrphans()
        recoverPendingRecordings()
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Sotto-remote-preview"))
        hasInitialized = true
        updateLoginItem()
        refreshServer()
        monitorTask = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, !isShuttingDown else { return }
                await checkServer(refreshData: count % 3 == 0 && !isBusy)
                count += 1
            }
        }
    }

    private func applyConfiguration(_ settings: SottoConfiguration) {
        guard !isBusy, !isShuttingDown else { return }
        applyingConfiguration = true
        if let key = HoldKey(rawValue: settings.holdKey), shortcut != key { shortcut = key }
        if launchAtLogin != settings.launchAtLogin { launchAtLogin = settings.launchAtLogin }
        applyingConfiguration = false
    }

    private func client() throws -> ServerClient {
        try ServerClient(endpoint: preferences.endpoint, token: preferences.token, session: serverSession)
    }

    func refreshServer() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.checkServer(refreshData: true) }
    }

    private func checkServer(refreshData: Bool) async {
        guard !isCheckingServer, !isShuttingDown else { return }
        isCheckingServer = true
        let endpoint = preferences.endpoint
        defer { isCheckingServer = false }
        do {
            let connection = try client()
            let health = try await connection.health()
            guard endpoint == preferences.endpoint, !Task.isCancelled else { return }
            serverHealth = health
            serverStatusMessage = health.apiVersion != SottoAPI.version ? "Server API version is incompatible"
                : (health.ready ? "Server online" : (health.message ?? "Server models are not ready"))
            if !isBusy, activity == .idle { statusMessage = isServerReady ? "Ready when you are" : serverStatusMessage }
            if refreshData {
                sharedPreferences = try await connection.preferences()
                guard endpoint == preferences.endpoint, !Task.isCancelled else { return }
                await updateHistory(connection: connection, append: false, preserveOlder: true)
            }
        } catch is CancellationError {
        } catch {
            guard endpoint == preferences.endpoint, !Task.isCancelled else { return }
            serverHealth = nil
            serverStatusMessage = Self.connectionMessage(error)
            if isCapturing {
                recordingFeedback.updateTransfer(connected: false)
            } else if !isBusy, activity == .idle { statusMessage = serverStatusMessage }
        }
    }

    func saveConnection(endpoint: String, token: String, deviceName: String) {
        guard !isBusy, wisprFlowImportTask == nil else { return }
        guard preferences.save(endpoint: endpoint, token: token, deviceName: deviceName) else {
            errorMessage = preferences.errorMessage
            return
        }
        continuationAnchors.removeAll()
        recoverPendingRecordings()
        serverHealth = nil
        sharedPreferences = nil
        generations = []
        historyCursor = nil
        recordingHistoryCursor = nil
        generationDetails = [:]
        selectedGenerationDetailID = nil
        recordingHistoryIDs = []
        recordingSnapshots = [:]
        historyRevision += 1
        isLoadingHistory = false
        hasMoreHistory = false
        serverStatusMessage = "Connecting…"
        refreshServer()
    }

    func refreshHistory() {
        Task { [weak self] in
            guard let self else { return }
            do { await updateHistory(connection: try client(), append: false) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func loadMoreHistory() {
        guard !isLoadingHistory, hasMoreHistory else { return }
        Task { [weak self] in
            guard let self else { return }
            do { await updateHistory(connection: try client(), append: true) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func recordingHistoryPage(_ connection: ServerClient, before: String?, enabled: Bool) async throws -> RecordingPage {
        guard enabled else { return .init(items: []) }
        do { return try await connection.recordingHistory(before: before) }
        catch ServerClientError.rejected(let status, _) where status == 404 { return .init(items: []) }
    }

    private func legacyHistoryPage(_ connection: ServerClient, before: String?, source: String?, enabled: Bool) async throws -> GenerationPage {
        guard enabled else { return .init(items: []) }
        return try await connection.history(before: before, source: source)
    }

    private func updateHistory(connection: ServerClient, append: Bool, preserveOlder: Bool = false) async {
        guard !isShuttingDown, !isLoadingHistory else { return }
        isLoadingHistory = true
        historyRevision += 1
        let revision = historyRevision
        let endpoint = preferences.endpoint
        let source = historySourceFilter
        let oldCursor = historyCursor
        let newCursor = recordingHistoryCursor
        defer { if historyRevision == revision { isLoadingHistory = false } }
        do {
            async let oldPage = legacyHistoryPage(connection, before: append ? oldCursor : nil,
                source: source == "all" ? nil : source, enabled: !append || oldCursor != nil)
            async let newPage = recordingHistoryPage(connection, before: append ? newCursor : nil,
                enabled: source != "wispr-flow" && (!append || newCursor != nil))
            let (legacy, recordings) = try await (oldPage, newPage)
            guard endpoint == preferences.endpoint, source == historySourceFilter,
                  historyRevision == revision, !Task.isCancelled else { return }
            let fetched = (legacy.items + recordings.items.map(ServerClient.generationSummary)).sorted { $0.createdAt > $1.createdAt }
            let fetchedIDs = Set(fetched.map(\.id))
            for snapshot in recordings.items { recordingSnapshots[snapshot.id] = snapshot }
            for item in fetched where generationDetails[item.id]?.status != item.status {
                generationDetails[item.id] = nil
            }
            let retainingLoadedPages = preserveOlder && generations.count > fetched.count
            if append || retainingLoadedPages {
                generations = fetched + generations.filter { !fetchedIDs.contains($0.id) }
                recordingHistoryIDs.formUnion(recordings.items.map(\.id))
            } else {
                generations = fetched
                recordingHistoryIDs = Set(recordings.items.map(\.id))
            }
            generations.sort { $0.createdAt > $1.createdAt }
            if append || !retainingLoadedPages {
                historyCursor = legacy.nextCursor
                recordingHistoryCursor = recordings.nextCursor
            }
            hasMoreHistory = historyCursor != nil || recordingHistoryCursor != nil
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
    }

    func generationDetail(_ id: UUID) -> GenerationRecord? {
        generationDetails[id] ?? generations.first { $0.id == id }
    }

    func loadGenerationDetail(_ id: UUID) {
        // Selection changes also fence older responses when this detail is already cached.
        selectedGenerationDetailID = id
        guard recordingHistoryIDs.contains(id), generationDetails[id] == nil,
              !loadingGenerationDetails.contains(id) else { return }
        let endpoint = preferences.endpoint
        let source = historySourceFilter
        loadingGenerationDetails.insert(id)
        Task { [weak self] in
            guard let self else { return }
            defer { loadingGenerationDetails.remove(id) }
            do {
                let value = try await client().materializedRecording(id)
                guard selectedGenerationDetailID == id, endpoint == preferences.endpoint,
                      source == historySourceFilter, !Task.isCancelled else { return }
                // Keep only the selected full transcript: long sessions must not
                // accumulate in memory while browsing the compact history list.
                if value.status == .completed { generationDetails = [id: value] }
            } catch {
                guard selectedGenerationDetailID == id, endpoint == preferences.endpoint,
                      source == historySourceFilter, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func retryPendingRecordings() { recoverPendingRecordings() }

    func setHistorySourceFilter(_ source: String) {
        guard ["all", "sotto", "wispr-flow"].contains(source), source != historySourceFilter else { return }
        historySourceFilter = source
        generations = []
        historyCursor = nil
        recordingHistoryCursor = nil
        generationDetails = [:]
        selectedGenerationDetailID = nil
        recordingHistoryIDs = []
        recordingSnapshots = [:]
        historyRevision += 1
        isLoadingHistory = false
        hasMoreHistory = false
        refreshHistory()
    }

    func prepareWisprFlowImport() {
        guard wisprFlowImportTask == nil else { return }
        wisprFlowPrepareRevision += 1
        let revision = wisprFlowPrepareRevision
        wisprFlowPrepareTask?.cancel()
        wisprFlowPrepareGate?.cancel()
        let gate = WisprFlowPreparationGate()
        wisprFlowPrepareGate = gate
        retireWisprFlowReader()
        wisprFlowImportState = .preparing
        wisprFlowDestinationEndpoint = preferences.endpoint
        // Schedule the worker before the main-actor continuation. Quit may
        // synchronously wait on the gate before that continuation starts.
        let snapshotTask = Task.detached(priority: .utility) {
            defer { gate.finish() }
            let reader = try WisprFlowSourceReader()
            guard gate.register(reader) else {
                reader.close()
                throw CancellationError()
            }
            return reader
        }
        wisprFlowPrepareTask = Task { [weak self] in
            guard let self else { gate.cancel(); return }
            defer {
                if revision == wisprFlowPrepareRevision { wisprFlowPrepareTask = nil }
            }
            do {
                let reader = try await snapshotTask.value
                var transferred = false
                defer {
                    if !transferred {
                        Task.detached(priority: .utility) { reader.close() }
                    }
                }
                try Task.checkCancellation()
                guard revision == wisprFlowPrepareRevision else { return }
                guard gate.transfer(reader) else { return }
                wisprFlowReader = reader
                transferred = true
                let knownCount: Int?
                let destinationError: String?
                do {
                    knownCount = try await client().knownWisprFlowSourceIDs(reader.sourceIDs).count
                    destinationError = nil
                } catch {
                    knownCount = nil
                    if let clientError = error as? ServerClientError,
                       case .rejected(let status, _) = clientError, status == 404 {
                        destinationError = "This server does not support Wispr Flow imports. Connect the new Sotto Dev server."
                    } else {
                        destinationError = "Cannot check the destination server: \(error.localizedDescription)"
                    }
                }
                try Task.checkCancellation()
                guard revision == wisprFlowPrepareRevision else { return }
                wisprFlowImportState = .preview(reader.preview, knownCount: knownCount,
                                               destinationError: destinationError)
            } catch is CancellationError {
            } catch {
                guard revision == wisprFlowPrepareRevision, !Task.isCancelled else { return }
                wisprFlowImportState = .failed(error.localizedDescription)
            }
        }
    }

    func startWisprFlowImport() {
        guard case .preview(let preview, _, let destinationError) = wisprFlowImportState,
              destinationError == nil,
              let reader = wisprFlowReader,
              wisprFlowImportTask == nil, !isBusy else { return }
        guard wisprFlowDestinationEndpoint == preferences.endpoint else {
            wisprFlowImportState = .failed("The server connection changed. Preview the import again.")
            return
        }
        let connection: ServerClient
        do { connection = try client() }
        catch { wisprFlowImportState = .failed(error.localizedDescription); return }
        let counts = WisprFlowImportCounts(total: reader.sourceIDs.count)
        wisprFlowImportRevision += 1
        let revision = wisprFlowImportRevision
        // The import task owns this reader until its detached work and artifact
        // cleanup finish. A new preview may start immediately after cancellation.
        wisprFlowActiveReaders[revision] = reader
        wisprFlowReader = nil
        wisprFlowImportState = .running(preview, counts)
        wisprFlowImportTask = Task { [weak self] in
            await self?.runWisprFlowImport(reader: reader, preview: preview, connection: connection,
                                           counts: counts, revision: revision)
        }
    }

    func cancelWisprFlowImport() {
        if case .running(let preview, let counts) = wisprFlowImportState {
            // Awaiting an unstructured reader task does not wake when its parent
            // is cancelled. Release the sheet now; the old task retains and
            // cleans its reader when materialization actually stops.
            wisprFlowImportRevision += 1
            wisprFlowMaterializationTask?.cancel()
            wisprFlowMaterializationTask = nil
            wisprFlowImportTask?.cancel()
            wisprFlowImportTask = nil
            wisprFlowDestinationEndpoint = nil
            wisprFlowImportState = .finished(preview, counts, cancelled: true)
        }
        wisprFlowPrepareTask?.cancel()
    }

    func closeWisprFlowImportSheet() {
        guard wisprFlowImportTask == nil else { return }
        wisprFlowPrepareRevision += 1
        wisprFlowPrepareTask?.cancel()
        wisprFlowPrepareGate?.cancel()
        retireWisprFlowReader()
        wisprFlowDestinationEndpoint = nil
        wisprFlowImportState = .idle
    }

    private func runWisprFlowImport(reader: WisprFlowSourceReader, preview: WisprFlowImportPreview,
                                    connection: ServerClient, counts initialCounts: WisprFlowImportCounts,
                                    revision: Int) async {
        var counts = initialCounts
        var cancelled = false
        var stoppedEarly = false
        var completionAttempted = false
        for sourceID in reader.sourceIDs {
            if Task.isCancelled { cancelled = true; break }
            var materializedSession: WisprFlowSourceSession?
            var activeTransferID: UUID?
            do {
                let session = try await materializeWisprFlowSession(reader: reader, sourceID: sourceID,
                                                                     revision: revision)
                materializedSession = session
                try Task.checkCancellation()
                let manifests = try await Task.detached(priority: .utility) {
                    try session.artifacts.map {
                        try ServerClient.wisprFlowArtifactManifest(filename: $0.filename, url: $0.url)
                    }
                }.value
                try Task.checkCancellation()
                let input = WisprFlowImportRequest(sourceID: session.sourceID, createdAt: session.createdAt,
                                                   sourceStatus: session.sourceStatus, finalText: session.displayText,
                                                   rawText: session.rawText, durationSeconds: session.durationSeconds,
                                                   variantNames: session.availableVariants, artifacts: manifests,
                                                   unarchivedArtifacts: session.unarchivedArtifacts.isEmpty
                                                       ? nil : session.unarchivedArtifacts)
                let transfer = try await connection.beginWisprFlowImport(input)
                activeTransferID = transfer.id
                for (artifact, manifest) in zip(session.artifacts, manifests) {
                    try Task.checkCancellation()
                    let receipt = try await connection.uploadWisprFlowArtifact(artifact.url, filename: artifact.filename,
                                                                               contentType: artifact.contentType, to: transfer.id)
                    guard receipt.filename == manifest.filename, receipt.byteCount == manifest.byteCount else {
                        throw ServerClientError.invalidResponse
                    }
                }
                try Task.checkCancellation()
                // A cancelled/lost response can hide a durable server commit.
                completionAttempted = true
                let result = try await connection.completeWisprFlowImport(transfer.id)
                activeTransferID = nil
                switch result.outcome {
                case .imported: counts.imported += 1
                case .enriched: counts.enriched += 1
                case .skipped: counts.skipped += 1
                case .partial:
                    counts.partial += 1
                    if counts.unarchivedWarning == nil {
                        let sourceReported = session.unarchivedArtifacts.map { omitted in
                            "\(omitted.filename.rawValue) (\(ByteCountFormatter.string(fromByteCount: Int64(omitted.byteCount), countStyle: .file)), SHA-256 \(omitted.sha256))"
                        }
                        let mediaNames = sourceReported.isEmpty
                            ? result.unarchivedArtifactNames.map(\.rawValue).joined(separator: ", ")
                            : sourceReported.joined(separator: ", ")
                        let mediaWarning = mediaNames.isEmpty ? nil
                            : "Session \(sourceID.uuidString) has unarchived media: \(mediaNames). Source version details are in source.json."
                        let warnings = [mediaWarning, session.provenanceWarning].compactMap { $0 }
                        if !warnings.isEmpty { counts.unarchivedWarning = warnings.joined(separator: "\n") }
                    }
                }
            } catch is CancellationError {
                cancelled = true
            } catch {
                if Task.isCancelled {
                    cancelled = true
                } else {
                    counts.failed += 1
                    if counts.warning == nil {
                        counts.warning = "Session \(sourceID.uuidString): \(error.localizedDescription)"
                    }
                    if error is URLError { stoppedEarly = true }
                    if let clientError = error as? ServerClientError,
                       case .rejected(let status, _) = clientError, [401, 403].contains(status) {
                        stoppedEarly = true
                    }
                }
            }
            if let activeTransferID {
                Task.detached(priority: .utility) {
                    try? await connection.cancelWisprFlowImport(activeTransferID)
                }
            }
            if let materializedSession {
                Task.detached(priority: .utility) {
                    reader.discardArtifacts(for: materializedSession)
                }
            }
            if Task.isCancelled { cancelled = true }
            if cancelled { break }
            counts.processed += 1
            if revision == wisprFlowImportRevision { wisprFlowImportState = .running(preview, counts) }
            if stoppedEarly { break }
        }
        if !cancelled, !stoppedEarly, preview.dictionaryCount > 0 {
            do {
                let dictionary = try await Task.detached(priority: .utility) {
                    try reader.dictionaryArtifactURL()
                }.value
                try Task.checkCancellation()
                guard let dictionary else { throw ServerClientError.invalidResponse }
                _ = try await connection.archiveWisprFlowDictionary(dictionary)
                counts.dictionaryArchived = true
            } catch is CancellationError {
                cancelled = true
            } catch {
                let dictionaryWarning = "Dictionary archive failed: \(error.localizedDescription)"
                counts.warning = [counts.warning, dictionaryWarning].compactMap { $0 }.joined(separator: "\n")
            }
        }
        cancelled = cancelled || Task.isCancelled
        await Task.detached(priority: .utility) { reader.close() }.value
        wisprFlowActiveReaders.removeValue(forKey: revision)
        if completionAttempted || counts.imported + counts.enriched + counts.skipped + counts.partial > 0 {
            if revision == wisprFlowImportRevision, historySourceFilter != "wispr-flow" {
                setHistorySourceFilter("wispr-flow")
            } else {
                // A cancelled run can still have committed on the server.
                // Refresh the user's current view without changing its filter.
                refreshHistory()
            }
        }
        guard revision == wisprFlowImportRevision else { return }
        wisprFlowImportTask = nil
        wisprFlowDestinationEndpoint = nil
        wisprFlowImportState = .finished(preview, counts, cancelled: cancelled)
    }

    private func materializeWisprFlowSession(reader: WisprFlowSourceReader, sourceID: UUID,
                                              revision: Int) async throws -> WisprFlowSourceSession {
        let task = Task.detached(priority: .utility) {
            try reader.session(for: sourceID)
        }
        if revision == wisprFlowImportRevision { wisprFlowMaterializationTask = task }
        defer {
            if revision == wisprFlowImportRevision { wisprFlowMaterializationTask = nil }
        }
        return try await task.value
    }

    private func retireWisprFlowReader() {
        guard let reader = wisprFlowReader else { return }
        wisprFlowReader = nil
        Task.detached(priority: .utility) { reader.close() }
    }

    func updateSharedPreferences(_ value: ServerPreferences, expectedRevision: Int? = nil) {
        guard !isSavingPreferences, let snapshot = sharedPreferences else { return }
        isSavingPreferences = true
        Task { [weak self] in
            guard let self else { return }
            defer { isSavingPreferences = false }
            do {
                let endpoint = preferences.endpoint
                let saved = try await client().updatePreferences(.init(revision: expectedRevision ?? snapshot.revision, preferences: value))
                guard endpoint == preferences.endpoint else { return }
                sharedPreferences = saved
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription; refreshServer() }
        }
    }

    func deleteGeneration(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try client()
                if recordingHistoryIDs.contains(id) { try await connection.discardRecording(id) }
                else { try await connection.delete(id) }
                generationDetails[id] = nil
                recordingHistoryIDs.remove(id)
                generations.removeAll { $0.id == id }
                continuationAnchors.removeAll { $0.generationID == id }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func openGenerationAudio(_ generation: GenerationRecord, kind: AudioKind, runID: UUID? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try client()
                let audio: URL
                if recordingHistoryIDs.contains(generation.id) { audio = try await connection.recordingAudio(generation.id, kind: kind, runID: runID) }
                else { audio = try await connection.audio(generation.id, kind: kind) }
                NSWorkspace.shared.open(audio)
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func recordingGapSeconds(_ id: UUID) -> TimeInterval {
        recordingSnapshots[id]?.runTimings?.reduce(0) { $0 + Double($1.gapBeforeMilliseconds ?? 0) / 1000 } ?? 0
    }

    func originalRecordingRuns(_ id: UUID) -> [RecordingStreamCheckpoint] {
        recordingSnapshots[id]?.streams.filter { $0.kind == .original && $0.frameCount > 0 } ?? []
    }

    func openWisprFlowArtifact(_ generation: GenerationRecord, filename: WisprFlowArtifactName) {
        guard generation.importedSource?.artifactNames.contains(filename) == true else { return }
        Task { [weak self] in
            guard let self else { return }
            do { NSWorkspace.shared.open(try await client().wisprFlowArtifact(generation.id, filename: filename)) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private static func connectionMessage(_ error: Error) -> String {
        if error is URLError { return "Server offline · Recording unavailable" }
        return error.localizedDescription
    }

    func toggleTestRecording() {
        guard !hotkey.isHoldingFn else { return }
        if isCapturing { finishDictation() }
        else if !isBusy { beginDictation(isTest: true) }
    }

    func cancelDictation() {
        guard isBusy, !isDiscarding, !isPreparingToQuit else { return }
        isDiscarding = true
        let current = sessionID
        let generation = activeGenerationID
        let connection = activeClient
        let spool = activeSpool
        if spool != nil {
            // Explicit discard waits for the writer to close before removing
            // files. Interruption and quit take a separate preservation path.
            recorder.stopAcceptingAudio()
            suppressDelivery = true
            activity = .transcribing
            transcriptionTask?.cancel()
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                await recorder.preserve()
                guard sessionID == current else { return }
                transcriptionTask = nil
                resetSession()
                try? spool?.discard()
                activity = .idle
                statusMessage = "Discarded"
                errorMessage = nil
                onHUDVisibility?(false)
                if let generation, let connection { try? await connection.discardRecording(generation) }
                refreshServer()
            }
        } else {
            resetSession()
            activity = .idle
            statusMessage = "Cancelled"
            errorMessage = nil
            onHUDVisibility?(false)
            if let generation, let connection { Task { try? await connection.discardRecording(generation) } }
        }
    }

    private func resetSession() {
        resumingRecordingID = nil
        isDiscarding = false
        sessionID = UUID()
        microphoneStartTask?.cancel(); microphoneStartTask = nil
        transcriptionTask?.cancel(); transcriptionTask = nil
        recordingTask?.cancel(); recordingTask = nil
        recordingContextTask?.cancel(); recordingContextTask = nil
        if let transport = recordingTransport { Task { await transport.cancel() } }
        recordingTransport = nil
        activeSpool = nil
        destinationTask?.cancel(); destinationTask = nil
        stopRecordingTimer()
        endCapturePowerActivity()
        recorder.cancel()
        recorder.onChunk = nil
        insertionDestination = nil
        recordingListHint = nil
        recordingInputName = nil
        activeGenerationID = nil
        activeClient = nil
        recordingFeedback.reset()
    }

    private func failSession(_ message: String, cancelServer: Bool) {
        let generation = activeGenerationID
        let connection = activeClient
        let spool = activeSpool
        let current = sessionID
        Task { [weak self] in
            guard let self else { return }
            await recorder.preserve()
            guard sessionID == current else { return }
            let hasSavedAudio = spool?.checkpoints.contains { $0.kind == .inference && $0.frameCount > 0 } == true
            resetSession()
            showError(message)
            // A refused microphone/open failure can leave an admitted server
            // session with zero audio. There is no prefix to recover in that case.
            if let spool, !hasSavedAudio {
                try? spool.discard()
                if let generation, let connection { Task { try? await connection.discardRecording(generation) } }
            }
            if cancelServer, spool == nil, let generation, let connection {
                Task { try? await connection.discardRecording(generation) }
            }
            if hasSavedAudio { recoverPendingRecordings() }
            refreshHistory()
        }
    }

    private func recoverPendingRecordings() {
        guard !isShuttingDown, !isBusy else { return }
        for spool in RecordingSpool.recover(in: recordingRoot, excluding: Set(pendingSpools.keys)) {
            guard !spool.finalManifest.isEmpty else {
                // A process can close after admission but before hardware opens.
                // Such an empty session has no audio to recover.
                try? spool.discard()
                if let connection = try? client(), connection.endpoint == spool.endpoint {
                    Task { try? await connection.discardRecording(spool.snapshot.id) }
                }
                continue
            }
            pendingSpools[spool.snapshot.id] = spool
            recoveredSpoolIDs.insert(spool.snapshot.id)
        }
        updatePendingRecordingSummary()
        resumePendingTransfers()
    }

    private func resumePendingTransfers() {
        guard !isShuttingDown, let connection = try? client() else { return }
        for (id, spool) in pendingSpools {
            guard recoveryTasks[id] == nil, spool.endpoint == connection.endpoint,
                  spool.deviceIdentity == preferences.deviceID else { continue }
            let transport = RecordingClient(client: connection, spool: spool)
            recoveryTasks[id] = Task { [weak self] in
                guard let self else { return }
                defer { recoveryTasks[id] = nil }
                do {
                    _ = try await transport.run()
                    guard !Task.isCancelled else { return }
                    // Launch/background recovery only archives. It must never
                    // use a stale destination or change the clipboard.
                    try spool.discard()
                    pendingSpools[id] = nil
                    recoveredSpoolIDs.remove(id)
                    updatePendingRecordingSummary()
                    recoveryMessage = "Recovered recording saved in history. Nothing was pasted."
                    refreshHistory()
                } catch is CancellationError {
                } catch {
                    recoveryMessage = "Recording saved locally. " + error.localizedDescription
                }
            }
        }
        if pendingRecordingCount > 0 && recoveryMessage == nil {
            recoveryMessage = "\(pendingRecordingCount) saved recording\(pendingRecordingCount == 1 ? "" : "s") pending recovery"
        }
    }

    private func updatePendingRecordingSummary() {
        pendingRecordings = pendingSpools.values.map(\.snapshot).sorted { $0.createdAt > $1.createdAt }
        pendingRecordingCount = pendingRecordings.count
        if pendingRecordingCount == 0 { recoveryMessage = nil }
    }

    func discardPendingRecording(_ id: UUID) {
        guard let spool = pendingSpools[id] else { return }
        recoveryTasks[id]?.cancel()
        recoveryTasks[id] = nil
        do { try spool.discard() }
        catch { errorMessage = error.localizedDescription; return }
        pendingSpools[id] = nil
        recoveredSpoolIDs.remove(id)
        updatePendingRecordingSummary()
        if let connection = try? client(), connection.endpoint == spool.endpoint {
            Task { try? await connection.discardRecording(id) }
        }
    }

    /// The application waits for this before accepting Quit so the converter,
    /// PCM writer, and recovery manifest all finish while the process is alive.
    func prepareToQuit() async {
        isPreparingToQuit = true
        suppressDelivery = true
        recorder.stopAcceptingAudio()
        transcriptionTask?.cancel()
        microphoneStartTask?.cancel()
        await recorder.preserve()
        shutdown()
    }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty, !isBusy else { return }
        switch DictationClipboard.copy(lastTranscript, to: .general) {
        case .success: lastDelivery = "Copied to clipboard"; lastDeliveryStatus = .copied
        case .failure(let error): lastDelivery = error.localizedDescription; lastDeliveryStatus = .failed
        }
    }

    func clearLastTranscript() {
        guard !isBusy else { return }
        continuationAnchors.removeAll()
        lastTranscript = ""; lastTranscriptionSeconds = nil; lastAudioSeconds = nil
        lastDelivery = ""; lastDeliveryStatus = .none; errorMessage = nil; activity = .idle
        recordingFeedback.reset()
    }

    func dismissFeedback() {
        guard !isBusy else { return }
        hudTask?.cancel()
        recordingFeedback.reset()
        onHUDVisibility?(false)
        if activity == .success { activity = .idle }
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        wisprFlowPrepareTask?.cancel(); wisprFlowImportTask?.cancel()
        wisprFlowMaterializationTask?.cancel()
        wisprFlowPrepareGate?.cancel(waitForWorker: true)
        wisprFlowPrepareGate = nil
        for reader in wisprFlowActiveReaders.values { reader.close() }
        wisprFlowActiveReaders.removeAll()
        wisprFlowReader?.close()
        wisprFlowReader = nil
        stopShortcutCheck()
        // Quit closes capture locally. Pending processing resumes on launch;
        // it never discards a session or repeats delivery.
        resetSession()
        for task in recoveryTasks.values { task.cancel() }
        recoveryTasks.removeAll()
        monitorTask?.cancel(); refreshTask?.cancel(); hudTask?.cancel(); permissionTask?.cancel()
        configuration.stopWatching()
        subscriptions.removeAll()
        audioDevices.stop(); hotkey.stop(); continuationAnchors.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Sotto-remote-preview"))
    }

    private func bindServices() {
        audioDevices.onChange = { [weak self] devices, defaultUID in self?.microphones.update(devices: devices, systemDefaultUID: defaultUID) }
        recorder.onLevel = { [weak self] level in guard let self, isCapturing else { return }; recordingFeedback.append(level) }
        recorder.onInterruption = { [weak self] message in
            self?.preserveInterruptedRecording(message)
        }
        hotkey.onStatusChange = { [weak self] in self?.isHotkeyActive = $0 }
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            if isCheckingShortcut { appendShortcutCheck("Shortcut recognized. Recording was intentionally skipped.") }
            else { beginDictation(isTest: false) }
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            if isCheckingShortcut { appendShortcutCheck("Hold released."); return }
            if !isTestSession && !isToggleSession { finishDictation() }
        }
        hotkey.onInterruption = { [weak self] in
            guard let self, !isShuttingDown else { return }
            if isCheckingShortcut { appendShortcutCheck("Shortcut interrupted; microphone stayed off.") }
            else if isCapturing { preserveInterruptedRecording("Shortcut interrupted. Recording saved locally.") }
        }
        hotkey.onCancel = { [weak self] in
            guard let self else { return }
            if isCheckingShortcut { appendShortcutCheck("Hold cancelled; microphone stayed off.") }
            else if isBusy { cancelDictation() }
            else { dismissFeedback() }
        }
    }

    func toggleDictation() {
        guard !hotkey.isHoldingFn else { return }
        if isCapturing { finishDictation() }
        else if !isBusy { beginDictation(isTest: false, isToggle: true) }
    }

    func stopDictation() { finishDictation() }

    private var recordingRoot: URL {
        configuration.url.deletingLastPathComponent().appendingPathComponent("Recordings", isDirectory: true)
    }

    private func beginDictation(isTest: Bool, isToggle: Bool = false) {
        guard !isBusy, !isShuttingDown, !isPreparingToQuit else { return }
        stopShortcutCheck()
        guard isServerReady else { showError(serverStatusMessage); refreshServer(); onShowWindow?(); return }
        guard permissions.microphone else { showError("Allow microphone access, then try again."); onShowWindow?(); return }
        guard let input = microphones.resolution.device, let deviceID = audioDevices.deviceID(for: input.uid) else {
            showError("No microphone is available. Connect an input and try again."); onShowWindow?(); return
        }
        hudTask?.cancel(); errorMessage = nil
        sessionID = UUID()
        let current = sessionID
        isTestSession = isTest
        isToggleSession = isToggle
        suppressDelivery = false
        recordingConnected = false
        recordingBaseSeconds = 0
        recordingClipboardChangeCount = NSPasteboard.general.changeCount
        insertionDestination = nil
        recordingInputName = input.name
        recordingFeedback.reset()
        activity = .starting
        statusMessage = "Connecting recording…"
        onHUDVisibility?(true)
        if !isTest {
            let capture = TextInserter.beginDestinationCapture()
            destinationTask = capture
            Task { [weak self] in
                let destination = await capture.value
                guard let self, sessionID == current, isCapturing else { return }
                insertionDestination = destination
                prepareContinuation(for: destination.target.map(DictationDestination.field))
            }
        } else { prepareContinuation(for: .test) }
        microphoneStartTask = Task { [weak self] in
            guard let self else { return }
            defer { if sessionID == current { microphoneStartTask = nil } }
            do {
                let connection = try client()
                // An older/reference server must reject admission before the
                // microphone starts; offline starts are intentionally unsupported.
                let capability: RecordingCapabilities
                do { capability = try await connection.recordingCapabilities() }
                catch ServerClientError.rejected(let status, _) where status == 404 {
                    throw ServerClientError.rejected(404, "Update the server to support long recordings.")
                }
                guard capability.protocolName == RecordingWire.webSocketProtocol,
                      capability.maximumPCMBytes == RecordingWire.maximumPCMBytes else {
                    throw ServerClientError.rejected(409, "This server does not support compatible long recordings. Update the server, then try again.")
                }
                let created = try await connection.createRecording(.init(requestID: current,
                    device: .init(id: preferences.deviceID, name: preferences.deviceName), mode: isTest ? .test : .dictation))
                guard sessionID == current, activity == .starting, !Task.isCancelled else {
                    Task { try? await connection.discardRecording(created.id) }; return
                }
                activeGenerationID = created.id
                activeClient = connection
                let spool = try RecordingSpool(directory: recordingRoot.appendingPathComponent(created.id.uuidString),
                    snapshot: created, endpoint: connection.endpoint, deviceIdentity: preferences.deviceID)
                activeSpool = spool
                sharedPreferences = created.settings
                let destinationCapture = destinationTask
                recordingContextTask = Task { [weak self] in
                    guard let self else { return }
                    let destination: InsertionDestination
                    if isTest { destination = .clipboard }
                    else { destination = await destinationCapture?.value ?? .clipboard }
                    guard sessionID == current, !Task.isCancelled else { return }
                    let anchor: DictationDestination? = isTest ? .test
                        : destination.target.flatMap { $0.selection == nil ? nil : .field($0) }
                    do { try spool.setContinuationID(anchor.flatMap { self.continuation(for: $0)?.generationID }) }
                    catch { failSession(error.localizedDescription, cancelServer: false) }
                }
                let transport = RecordingClient(client: connection, spool: spool)
                recordingTransport = transport
                recordingTask = Task { [weak self] in
                    try await transport.run(onUpdate: { [weak self] snapshot in
                        await self?.applyRecordingProgress(snapshot, session: current)
                    }, onConnectionChange: { [weak self] connected in
                        await self?.setRecordingConnection(connected, session: current)
                    })
                }
                recordingStart = ProcessInfo.processInfo.systemUptime
                statusMessage = "Starting microphone…"
                try await recorder.start(deviceID: deviceID, preserveOriginalAudio: created.settings.preferences.keepOriginalAudio, spool: spool)
                guard sessionID == current, activity == .starting, !Task.isCancelled else { return }
                capturePowerActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled], reason: "Sotto is recording dictation"
                )
                activity = .recording
                statusMessage = "Listening"
                startRecordingTimer()
            } catch is CancellationError {
            } catch AudioRecordingError.cancelled {
            } catch {
                guard sessionID == current, !Task.isCancelled else { return }
                serverHealth = nil
                serverStatusMessage = Self.connectionMessage(error)
                failSession(serverStatusMessage, cancelServer: true)
                refreshServer()
            }
        }
    }

    private func finishDictation(interrupted: String? = nil) {
        guard isCapturing, !isPreparingToQuit else { return }
        recorder.stopAcceptingAudio()
        guard activity == .recording else {
            if resumingRecordingID != nil {
                if activeSpool != nil { preserveInterruptedRecording("Recording paused before the microphone became ready.") }
                else {
                    resetSession()
                    activity = .idle
                    statusMessage = "Recording remains paused"
                    recoverPendingRecordings()
                }
            } else { cancelDictation() }
            return
        }
        let releasedAt = ProcessInfo.processInfo.systemUptime
        destinationTask?.finish()
        guard releasedAt - recordingStart >= 0.25 || recordingBaseSeconds > 0 || interrupted != nil else { cancelDictation(); return }
        guard let id = activeGenerationID, let connection = activeClient,
              let recordingTask, let spool = activeSpool else {
            failSession("This recording has no saved session.", cancelServer: false); return
        }
        stopRecordingTimer(); endCapturePowerActivity(); resetLevels()
        activity = .transcribing
        statusMessage = interrupted == nil ? "Finishing dictation…" : "Recording saved · Finishing processing…"
        let current = sessionID
        let test = isTestSession
        let capturedDestination = insertionDestination
        let pendingDestination = destinationTask
        let clipboardCount = recordingClipboardChangeCount
        if interrupted != nil { suppressDelivery = true }
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                // stop() flushes the converter and seals the durable run. Never
                // cleanup() this audio before the transport confirms completion.
                _ = try await recorder.stop()
                if let interrupted { try spool.seal(interrupted: interrupted) }
                let result = try await recordingTask.value
                guard sessionID == current, !Task.isCancelled else { return }
                guard result.status == .completed else {
                    throw ServerClientError.rejected(422, result.error ?? "The server could not process this recording.")
                }
                let destination: InsertionDestination
                if test { destination = .clipboard }
                else if let capturedDestination { destination = capturedDestination }
                else { destination = await pendingDestination?.value ?? .clipboard }
                let resolved: InsertionDestination
                if let target = destination.target, !InsertionCapturePolicy.permitsInsertion(capturedAt: target.capturedAt, releasedAt: releasedAt) {
                    resolved = .clipboard
                } else { resolved = destination }
                let anchor: DictationDestination? = test ? .test : resolved.target.flatMap { $0.selection == nil ? nil : .field($0) }
                guard sessionID == current, !Task.isCancelled else { return }
                // Checkpoint before any delivery side effect. A crash or lost
                // receipt can never cause launch recovery to repeat a paste.
                try spool.markDeliveryAttempted()
                if suppressDelivery {
                    lastTranscript = result.finalText
                    lastAudioSeconds = result.audioSeconds
                    lastDelivery = "Saved in history. Nothing was pasted."
                    lastDeliveryStatus = .saved
                    statusMessage = "Recording saved"
                } else {
                    await deliver(result, to: resolved, anchor: anchor, isTest: test, clipboardCount: clipboardCount, session: current)
                }
                guard sessionID == current, !Task.isCancelled else { return }
                let receipt = DeliveryReceipt(status: lastDeliveryStatus == .saved ? "none" : lastDeliveryStatus.rawValue, message: lastDelivery)
                do { try await connection.recordingDelivery(id, receipt: receipt) }
                catch { continuationAnchors.removeAll { $0.generationID == id } }
                guard sessionID == current, !Task.isCancelled else { return }
                // The assembled text and audio now belong to durable server
                // history; even uncertain insertion must never be retried.
                try? spool.discard()
                activeSpool = nil; activeGenerationID = nil; activeClient = nil
                self.recordingTask = nil; recordingTransport = nil
                recordingContextTask = nil; resumingRecordingID = nil
                recoveredSpoolIDs.remove(id)
                destinationTask = nil; insertionDestination = nil; recordingListHint = nil; recordingInputName = nil
                activity = lastDeliveryStatus == .failed ? .failed : .success
                dismissHUDAfter(seconds: lastDeliveryStatus == .failed || lastDeliveryStatus == .unconfirmed ? 4 : 1.7)
                refreshServer()
                applyConfiguration(configuration.configuration)
            } catch is CancellationError {
            } catch AudioRecordingError.cancelled {
            } catch {
                guard sessionID == current, !Task.isCancelled else { return }
                let hasAudio = spool.checkpoints.contains { $0.kind == .inference && $0.frameCount > 0 }
                failSession((hasAudio ? "Recording saved locally. " : "") + error.localizedDescription, cancelServer: false)
            }
        }
    }

    private func setRecordingConnection(_ connected: Bool, session: UUID) {
        guard sessionID == session, isBusy else { return }
        recordingConnected = connected
        recordingFeedback.updateTransfer(connected: connected)
    }

    private func applyRecordingProgress(_ snapshot: RecordingSnapshot, session: UUID) {
        guard sessionID == session, isBusy else { return }
        if isCapturing {
            let capturedFrames = Int64(min(recordingFeedback.elapsedSeconds, Int(Int64.max / 16_000))) * 16_000
            recordingFeedback.updateTransfer(connected: recordingConnected,
                catchingUp: capturedFrames - snapshot.uploadedFrames > 5 * 16_000)
            statusMessage = "Listening"
        } else {
            switch snapshot.processingState {
            case .queued: statusMessage = "Waiting for server…"
            case .processing: statusMessage = "Finishing dictation…"
            case .completed: statusMessage = "Preparing result…"
            case .failed: statusMessage = snapshot.error ?? "Processing stopped · Audio saved"
            }
        }
    }

    private func preserveInterruptedRecording(_ message: String) {
        guard isCapturing, !isPreparingToQuit, let spool = activeSpool else { return }
        recorder.stopAcceptingAudio()
        destinationTask?.finish()
        suppressDelivery = true
        stopRecordingTimer(); endCapturePowerActivity(); resetLevels()
        activity = .transcribing
        statusMessage = "Saving interrupted recording…"
        let current = sessionID
        let id = spool.snapshot.id
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try? await recorder.stop(pausing: true, interruption: message)
                try spool.pauseCapture(interrupted: message)
                guard sessionID == current, !Task.isCancelled else { return }
                await recordingContextTask?.value
                guard sessionID == current, !Task.isCancelled else { return }
                if !spool.contextReady { try spool.setContinuationID(nil) }
                pendingSpools[id] = spool
                resetSession()
                activity = .success
                lastDeliveryStatus = .saved
                lastDelivery = "Recording paused. Resume or finish it in history."
                statusMessage = "Recording paused"
                recoveryMessage = message
                updatePendingRecordingSummary()
                recoverPendingRecordings()
                dismissHUDAfter(seconds: 3)
            } catch is CancellationError {
            } catch {
                guard sessionID == current, !Task.isCancelled else { return }
                failSession("Recording saved locally. " + error.localizedDescription, cancelServer: false)
            }
        }
    }

    func pendingRecordingAudioSeconds(_ id: UUID) -> TimeInterval {
        pendingSpools[id]?.checkpoints.filter { $0.kind == .inference }
            .reduce(0) { $0 + Double($1.frameCount) / 16_000 } ?? 0
    }

    func pendingRecordingIsPaused(_ id: UUID) -> Bool { pendingSpools[id]?.isPaused == true }

    func canResumePendingRecording(_ id: UUID) -> Bool {
        !isBusy && !isPreparingToQuit && isServerReady && pendingSpools[id]?.isPaused == true
            && pendingSpools[id]?.isSealed == false
    }

    func canFinishPendingRecording(_ id: UUID) -> Bool {
        !isBusy && !isPreparingToQuit && pendingSpools[id]?.isSealed == false
    }

    func finishPendingRecording(_ id: UUID) {
        guard canFinishPendingRecording(id), let spool = pendingSpools[id] else { return }
        do {
            try spool.seal(interrupted: spool.interruption)
            updatePendingRecordingSummary()
            recoveryMessage = "Finishing saved recording. Nothing will be pasted."
            // A settled paused socket may be awaiting its next server message.
            // Reconnect from durable checkpoints to send the stop immediately.
            let recovery = recoveryTasks[id]
            recovery?.cancel()
            Task { [weak self] in
                await recovery?.value
                guard let self, !isShuttingDown else { return }
                recoveryTasks[id] = nil
                resumePendingTransfers()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func resumePendingRecording(_ id: UUID) {
        guard canResumePendingRecording(id), let spool = pendingSpools[id] else { return }
        guard permissions.microphone, let input = microphones.resolution.device,
              let deviceID = audioDevices.deviceID(for: input.uid) else {
            showError("Connect an available microphone and allow access before resuming.")
            return
        }
        let connection: ServerClient
        do { connection = try client() }
        catch { showError(error.localizedDescription); return }
        guard connection.endpoint == spool.endpoint, spool.deviceIdentity == preferences.deviceID else {
            showError("Connect to this recording’s original server before resuming.")
            return
        }
        let recovered = recoveredSpoolIDs.contains(id)
        resumingRecordingID = id
        recordingBaseSeconds = spool.checkpoints.filter { $0.kind == .inference }
            .reduce(0) { $0 + Double($1.frameCount) / 16_000 }
        stopShortcutCheck()
        hudTask?.cancel()
        sessionID = UUID()
        let current = sessionID
        activity = .starting
        statusMessage = "Resuming saved recording…"
        errorMessage = nil
        isToggleSession = true
        isTestSession = spool.snapshot.mode == .test
        suppressDelivery = recovered
        recordingConnected = false
        recordingClipboardChangeCount = NSPasteboard.general.changeCount
        insertionDestination = nil
        recordingInputName = input.name
        recordingFeedback.reset()
        onHUDVisibility?(true)
        let destinationCapture = isTestSession ? nil : TextInserter.beginDestinationCapture()
        destinationTask = destinationCapture
        if let destinationCapture {
            Task { [weak self] in
                let destination = await destinationCapture.value
                guard let self, sessionID == current, isCapturing else { return }
                insertionDestination = destination
            }
        }
        microphoneStartTask = Task { [weak self] in
            guard let self else { return }
            defer { if sessionID == current { microphoneStartTask = nil } }
            do {
                let health = try await connection.health()
                let capability = try await connection.recordingCapabilities()
                guard health.ready, health.apiVersion == SottoAPI.version,
                      capability.protocolName == RecordingWire.webSocketProtocol,
                      capability.maximumPCMBytes == RecordingWire.maximumPCMBytes else {
                    throw ServerClientError.rejected(503, "The original server must be ready before resuming.")
                }
                let snapshot = try await connection.recording(id)
                guard snapshot.captureState != .discarded, snapshot.stopRuns == nil,
                      snapshot.processingState != .completed else {
                    throw ServerClientError.rejected(409, "This recording is already finalized. Start a new dictation.")
                }
                guard sessionID == current, !Task.isCancelled else { return }
                // Close the prior synchronization socket before admitting a new
                // run. Server epochs fence any delayed work from that socket.
                let recovery = recoveryTasks[id]
                recovery?.cancel()
                await recovery?.value
                guard sessionID == current, !Task.isCancelled else { return }
                recoveryTasks[id] = nil
                try spool.markSnapshot(snapshot)
                try spool.prepareToResume()
                activeSpool = spool
                activeGenerationID = id
                activeClient = connection
                sharedPreferences = snapshot.settings
                pendingSpools[id] = nil
                updatePendingRecordingSummary()
                recordingBaseSeconds = spool.checkpoints.filter { $0.kind == .inference }
                    .reduce(0) { $0 + Double($1.frameCount) / 16_000 }
                recordingFeedback.updateElapsed(recordingBaseSeconds)
                let transport = RecordingClient(client: connection, spool: spool)
                recordingTransport = transport
                recordingTask = Task { [weak self] in
                    try await transport.run(onUpdate: { [weak self] progress in
                        await self?.applyRecordingProgress(progress, session: current)
                    }, onConnectionChange: { [weak self] connected in
                        await self?.setRecordingConnection(connected, session: current)
                    })
                }
                recordingStart = ProcessInfo.processInfo.systemUptime
                try await recorder.start(deviceID: deviceID,
                    preserveOriginalAudio: snapshot.settings.preferences.keepOriginalAudio, spool: spool)
                guard sessionID == current, !Task.isCancelled else { return }
                capturePowerActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled], reason: "Sotto is recording dictation"
                )
                activity = .recording
                statusMessage = "Listening"
                startRecordingTimer()
            } catch is CancellationError {
            } catch {
                guard sessionID == current, !Task.isCancelled else { return }
                // Resume failure never destroys the earlier run or silently
                // finalizes it; the same prefix remains available in history.
                if activeSpool == nil {
                    resetSession()
                    showError(error.localizedDescription)
                    recoverPendingRecordings()
                } else { preserveInterruptedRecording(error.localizedDescription) }
            }
        }
    }

    private func deliver(_ record: GenerationRecord, to destination: InsertionDestination,
                         anchor: DictationDestination?, isTest: Bool, clipboardCount: Int, session: UUID) async {
        lastTranscript = record.previewText.isEmpty ? record.finalText : record.previewText
        lastAudioSeconds = record.audioSeconds
        lastTranscriptionSeconds = (record.speech?.processingSeconds ?? 0) + (record.proofreading?.processingSeconds ?? 0)
        if isTest {
            rememberContinuation(record, at: .test)
            lastDelivery = "Test complete. Nothing was pasted."
            lastDeliveryStatus = .tested
            statusMessage = record.finalText.isEmpty ? "No speech detected" : "Ready to copy"
            return
        }
        if record.insertionText.isEmpty {
            if record.continuation == nil && record.previewText.isEmpty {
                lastDelivery = "No speech detected"; lastDeliveryStatus = .none
            } else if let confirmed = TextInserter.unchangedAnchor(destination.target) {
                rememberContinuation(record, at: .field(confirmed))
                lastDelivery = "List updated. Nothing was pasted."; lastDeliveryStatus = .listUpdated
            } else {
                lastDelivery = "List state unchanged: the original cursor could not be confirmed."
                lastDeliveryStatus = .unconfirmed
            }
            statusMessage = lastDelivery
            return
        }
        activity = .delivering
        statusMessage = "Inserting at your cursor…"
        let outcome = await inserter.deliver(record.insertionText, copying: record.finalText,
                                              to: destination, clipboardUnchangedSince: clipboardCount)
        guard sessionID == session, !Task.isCancelled else { return }
        if let anchor { continuationAnchors.removeAll { $0.destination == anchor } }
        switch outcome {
        case .inserted:
            if let target = inserter.confirmedAnchor { rememberContinuation(record, at: .field(target)) }
            lastDelivery = "Inserted at your cursor"; lastDeliveryStatus = .inserted; statusMessage = "Inserted"
        case .copied(let reason):
            lastTranscript = record.finalText; lastDelivery = reason; lastDeliveryStatus = .copied; statusMessage = "Copied"
        case .unconfirmed(let backup):
            lastTranscript = record.finalText
            lastDelivery = backup ? "Insertion unconfirmed. Copied to clipboard if needed." : "Insertion unconfirmed. Your words are here to copy."
            lastDeliveryStatus = .unconfirmed; statusMessage = "Check insertion"
        case .failed(let reason):
            lastTranscript = record.finalText; lastDelivery = reason; lastDeliveryStatus = .failed; statusMessage = "Ready to copy"
        }
    }

    private func continuation(for destination: DictationDestination) -> ContinuationAnchor? {
        let now = ProcessInfo.processInfo.systemUptime
        continuationAnchors.removeAll { now < $0.timestamp || now - $0.timestamp >= 15 * 60 }
        return continuationAnchors.last { $0.destination == destination }
    }

    private func prepareContinuation(for destination: DictationDestination?) {
        if let destination, let list = continuation(for: destination)?.continuation.list {
            recordingListHint = list.style == .numbered ? "Continuing at item \(list.nextNumber)" : "Continuing your list"
        } else { recordingListHint = nil }
    }

    private func rememberContinuation(_ record: GenerationRecord, at destination: DictationDestination) {
        continuationAnchors.removeAll { $0.destination == destination }
        guard let continuation = record.continuation else { return }
        continuationAnchors.append(.init(destination: destination, generationID: record.id, continuation: continuation,
                                         timestamp: ProcessInfo.processInfo.systemUptime))
        continuationAnchors = Array(continuationAnchors.suffix(8))
    }

    private func showError(_ message: String) {
        recordingFeedback.reset()
        activity = .failed; errorMessage = message; statusMessage = message
        onHUDVisibility?(true)
        dismissHUDAfter(seconds: 4)
    }

    private func dismissHUDAfter(seconds: Double) {
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, !isBusy else { return }
            onHUDVisibility?(false)
            recordingFeedback.reset()
            if activity == .success { activity = .idle; statusMessage = isServerReady ? "Ready when you are" : serverStatusMessage }
        }
    }

    private func installLifecycleObservers() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.refreshPermissions(); self?.refreshServer() }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.restForSystem() }
            })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.suppressDelivery = true } })
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated {
                // Lock can leave the microphone running. Once locked, this
                // take stays archive-only even if processing finishes later.
                self?.suppressDelivery = true
                self?.continuationAnchors.removeAll()
            }
        }
    }

    private func restForSystem() {
        stopShortcutCheck()
        suppressDelivery = true
        if isCapturing { preserveInterruptedRecording("Recording stopped because your Mac is going to sleep.") }
        continuationAnchors.removeAll()
    }
    func refreshPermissions() {
        let current = PermissionSnapshot.capture()
        if current != permissions { permissions = current }
        audioDevices.refresh()
        if permissions.canListenForHotkey {
            isHotkeyActive = hotkey.start()
        } else {
            hotkey.stop()
            isHotkeyActive = false
        }
    }

    func requestMicrophone() {
        if permissions.microphone {
            PermissionManager.openMicrophoneSettings()
            return
        }
        Task {
            _ = await PermissionManager.requestMicrophone()
            refreshPermissions()
        }
    }

    func requestAccessibility() {
        if permissions.accessibility { PermissionManager.openAccessibilitySettings() }
        else { PermissionManager.requestAccessibility() }
        retryPermissions()
    }

    func requestInputMonitoring() {
        if permissions.inputMonitoring { PermissionManager.openInputMonitoringSettings() }
        else { PermissionManager.requestInputMonitoring() }
        retryPermissions()
    }

    func startShortcutCheck() {
        guard !isBusy, !isCheckingShortcut else { return }
        refreshPermissions()
        shortcutCheckStarted = ProcessInfo.processInfo.systemUptime
        shortcutCheckEntries = []
        isCheckingShortcut = true
        hotkey.onDiagnostic = { [weak self] message in self?.appendShortcutCheck(message) }
        hotkey.requireFreshHold()
        appendShortcutCheck("Checking \(shortcut.title) for 60 seconds. The microphone stays off.")
        appendShortcutCheck("Listener: \(isHotkeyActive ? "enabled" : "unavailable"); Accessibility: \(permissions.accessibility); Input Monitoring: \(permissions.inputMonitoring).")
        shortcutCheckTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.stopShortcutCheck()
        }
    }

    func stopShortcutCheck() {
        guard isCheckingShortcut else { return }
        // Reset before leaving check mode: a delayed callback must never start
        // the microphone just because this check timed out during a held key.
        hotkey.requireFreshHold()
        appendShortcutCheck("Check ended. No audio was recorded.")
        hotkey.onDiagnostic = nil
        isCheckingShortcut = false
        shortcutCheckTask?.cancel()
        shortcutCheckTask = nil
    }

    private func appendShortcutCheck(_ message: String) {
        guard isCheckingShortcut else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - shortcutCheckStarted
        let context = NSApp.isActive ? "Sotto" : "background"
        shortcutCheckEntries.append(String(format: "%.2fs", elapsed) + " [\(context)] " + message)
        shortcutCheckEntries = Array(shortcutCheckEntries.suffix(16))
        shortcutCheckText = shortcutCheckEntries.joined(separator: "\n")
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCapturing else { return }
                let elapsed = self.recordingBaseSeconds + ProcessInfo.processInfo.systemUptime - self.recordingStart
                self.recordingFeedback.updateElapsed(elapsed)
            }
        }
        timer.tolerance = 0.025
        recordingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func endCapturePowerActivity() {
        if let capturePowerActivity { ProcessInfo.processInfo.endActivity(capturePowerActivity) }
        capturePowerActivity = nil
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func resetLevels() {
        recordingFeedback.clearLevels()
    }

    private func retryPermissions() {
        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            for _ in 0..<30 {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                guard let self else { return }
                refreshPermissions()
                if allPermissionsGranted { return }
            }
        }
    }

    private func updateLoginItem() {
        guard !updatingLogin else { return }
        updatingLogin = true
        defer { updatingLogin = false }
        loginItemError = nil
        let status = SMAppService.mainApp.status
        if launchAtLogin, status == .enabled { return }
        if launchAtLogin, status == .requiresApproval {
            loginItemError = "Allow Sotto in System Settings → General → Login Items to finish enabling this preference."
            return
        }
        // A rebuilt accessory app may report .notFound even though login is
        // already off. Do not attempt to unregister an absent service.
        if !launchAtLogin, status != .enabled, status != .requiresApproval { return }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if launchAtLogin, SMAppService.mainApp.status == .requiresApproval {
                loginItemError = "Allow Sotto in System Settings → General → Login Items to finish enabling this preference."
            }
        } catch {
            // Keep the desired setting consistent between UI and JSON. A denied
            // OS operation must not trigger file rollback/retry feedback loops.
            loginItemError = "Couldn’t update launch at login: \(error.localizedDescription)"
        }
    }


}
