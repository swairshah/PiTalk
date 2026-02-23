import SwiftUI
import AppKit
import ServiceManagement
import Carbon.HIToolbox
import Network
import Darwin
import CoreAudio

// Notification for mic activity changes
extension Notification.Name {
    static let micActivityChanged = Notification.Name("PiTalkMicActivityChanged")
}

// Debug logging - only prints when PITALK_DEBUG=1
fileprivate let debugEnabled = ProcessInfo.processInfo.environment["PITALK_DEBUG"] == "1"
fileprivate func debugLog(_ message: String) {
    if debugEnabled {
        print(message)
    }
}

@main
struct PiTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = VoiceMonitor()
    
    var body: some Scene {
        // MenuBarExtra with window style (like pi-statusbar)
        MenuBarExtra {
            StatusBarContentView(monitor: monitor)
        } label: {
            StatusBarIcon(summary: monitor.summary, serverOnline: monitor.serverOnline, serverEnabled: monitor.serverEnabled)
        }
        .menuBarExtraStyle(.window)
        
        // Settings scene
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // Shared instance for access from SwiftUI views
    static var shared: AppDelegate?
    
    // Menu bar UI is handled by SwiftUI MenuBarExtra
    // TTS is handled by ElevenLabs API (no local server needed)
    var settingsWindow: NSWindow?
    var hotKeyRef: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var speechCoordinator: SpeechPlaybackCoordinator?
    var localBroker: LocalSpeechBroker?
    var micMonitor: MicrophoneActivityMonitor?
    let brokerPort = 18081
    
    // Dock icon visibility (defaults to true so window is accessible)
    var showDockIcon: Bool {
        get { 
            if UserDefaults.standard.object(forKey: "showDockIcon") == nil {
                return true  // Default to showing dock icon
            }
            return UserDefaults.standard.bool(forKey: "showDockIcon") 
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "showDockIcon")
            updateDockIconVisibility()
        }
    }
    
    var selectedVoice: String {
        UserDefaults.standard.string(forKey: "ttsVoice") ?? "ally"
    }
    
    // Server enabled state - persisted (inverted storage as "serverDisabled")
    var serverEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "serverDisabled") }
        set {
            UserDefaults.standard.set(!newValue, forKey: "serverDisabled")
            speechCoordinator?.isMuted = !newValue
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set shared instance for access from SwiftUI
        AppDelegate.shared = self

        switch ElevenLabsApiKeyManager.bootstrapPersistedKeyIfNeeded() {
        case .importedFromEnvironment:
            debugLog("PiTalk: Imported ElevenLabs API key from process environment")
        case .importedFromDotEnv:
            debugLog("PiTalk: Imported ElevenLabs API key from ~/.env")
        case .alreadyConfigured, .notFound:
            break
        }
        
        switch GoogleApiKeyManager.bootstrapPersistedKeyIfNeeded() {
        case .importedFromEnvironment:
            debugLog("PiTalk: Imported Google TTS API key from process environment")
        case .importedFromDotEnv:
            debugLog("PiTalk: Imported Google TTS API key from ~/.env")
        case .alreadyConfigured, .notFound:
            break
        }
        
        // Menu bar is now handled by SwiftUI MenuBarExtra
        setupGlobalShortcut()
        updateDockIconVisibility()

        speechCoordinator = SpeechPlaybackCoordinator(
            defaultVoiceProvider: { [weak self] in self?.selectedVoice ?? "ally" }
        )
        
        // Restore server enabled state from preferences
        speechCoordinator?.isMuted = !serverEnabled

        micMonitor = MicrophoneActivityMonitor { [weak self] isActive in
            debugLog("PiTalk: Mic callback triggered, isActive=\(isActive)")
            self?.speechCoordinator?.setMicrophoneActive(isActive)
            // Notify VoiceMonitor of mic state change
            NotificationCenter.default.post(name: .micActivityChanged, object: nil, userInfo: ["isActive": isActive])
        }
        micMonitor?.start()
        debugLog("PiTalk: Mic monitor started")

        // Only start broker if server is enabled
        if serverEnabled {
            startLocalBroker()
        } else {
            debugLog("PiTalk: Server disabled, broker not started")
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When dock icon is clicked, open settings
        openSettings()
        return true
    }
    
    func updateDockIconVisibility() {
        if showDockIcon {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        micMonitor?.stop()
        localBroker?.stop()
        speechCoordinator?.stopAll()
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
    
    // MARK: - Global Shortcut (Cmd+.)
    
    func setupGlobalShortcut() {
        // Use Carbon API for true global hotkey that works everywhere
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            appDelegate.stopCurrentSpeech()
            return noErr
        }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &eventHandler)
        
        // Register Cmd+. hotkey
        // Key code 47 = period (.)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4F5149), id: 1) // "LOQI"
        let modifiers: UInt32 = UInt32(cmdKey)
        RegisterEventHotKey(47, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    var healthServer: HealthHTTPServer?
    
    func startLocalBroker() {
        debugLog("PiTalk: startLocalBroker called, coordinator=\(speechCoordinator != nil), localBroker=\(localBroker != nil)")
        guard let coordinator = speechCoordinator else {
            debugLog("PiTalk: No coordinator, cannot start broker")
            return
        }
        
        // Don't start if already running
        if localBroker != nil {
            debugLog("PiTalk: Broker already running, skipping start")
            return
        }
        
        do {
            let broker = try LocalSpeechBroker(port: brokerPort, coordinator: coordinator)
            broker.start()
            localBroker = broker
            debugLog("PiTalk: Local broker listening on 127.0.0.1:\(brokerPort)")
        } catch {
            print("PiTalk: Failed to start local broker: \(error)")
            return
        }

        // Also start HTTP health server on 18080 (pi-tts extension expects this)
        if healthServer == nil {
            do {
                let server = try HealthHTTPServer(port: 18080)
                server.start()
                healthServer = server
                debugLog("PiTalk: Health server listening on 127.0.0.1:18080")
            } catch {
                print("PiTalk: Failed to start health server: \(error)")
            }
        }
    }
    
    func stopLocalBroker() {
        debugLog("PiTalk: stopLocalBroker called, localBroker=\(localBroker != nil)")
        localBroker?.stop()
        localBroker = nil
        healthServer?.stop()
        healthServer = nil
        debugLog("PiTalk: Broker and health server stopped")
    }
    
    @objc func stopCurrentSpeech() {
        // Centralized stop: clear broker queue, stop active PiTalk playback, stop current synth request.
        speechCoordinator?.stopAll()
    }
    
    @objc func toggleDockIcon() {
        showDockIcon = !showDockIcon
    }
    
    // MARK: - Actions
    
    @objc func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)
            
            let window = NSWindow(contentViewController: hostingController)
            window.title = "PiTalk"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: 520, height: 680))
            window.minSize = NSSize(width: 420, height: 480)
            window.center()
            
            settingsWindow = window
        }
        
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
    
    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Local Broker & Playback

private struct SpeechJob {
    let historyEntryId: UUID
    let text: String
    let voice: String
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
}

private struct BrokerRequest: Decodable {
    let type: String
    let text: String?
    let voice: String?
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
}

private struct BrokerResponse: Encodable {
    let ok: Bool
    let error: String?
    let queued: Int?
    let pending: Int?
    let playing: Bool?
    let currentQueue: String?

    static func success(
        queued: Int? = nil,
        pending: Int? = nil,
        playing: Bool? = nil,
        currentQueue: String? = nil
    ) -> BrokerResponse {
        BrokerResponse(
            ok: true,
            error: nil,
            queued: queued,
            pending: pending,
            playing: playing,
            currentQueue: currentQueue
        )
    }

    static func failure(_ message: String) -> BrokerResponse {
        BrokerResponse(ok: false, error: message, queued: nil, pending: nil, playing: nil, currentQueue: nil)
    }
}

enum RequestPlaybackStatus: String, Codable {
    case queued
    case playing
    case played
    case interrupted
    case cancelled
    case failed

    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .playing: return "Playing"
        case .played: return "Played"
        case .interrupted: return "Interrupted"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    var isInQueue: Bool {
        self == .queued || self == .playing
    }

    var tintColor: Color {
        switch self {
        case .queued: return .secondary
        case .playing: return .blue
        case .played: return .green
        case .interrupted: return .orange
        case .cancelled: return .orange
        case .failed: return .red
        }
    }
}

struct RequestHistoryEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let text: String
    let voice: String?
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
    var status: RequestPlaybackStatus

    init(
        id: UUID = UUID(),
        timestamp: Date,
        text: String,
        voice: String?,
        sourceApp: String?,
        sessionId: String?,
        pid: Int?,
        status: RequestPlaybackStatus
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.voice = voice
        self.sourceApp = sourceApp
        self.sessionId = sessionId
        self.pid = pid
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, text, voice, sourceApp, sessionId, pid, status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        text = try container.decode(String.self, forKey: .text)
        voice = try container.decodeIfPresent(String.self, forKey: .voice)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        // Backward compatibility: old entries had no status, treat as already played
        status = try container.decodeIfPresent(RequestPlaybackStatus.self, forKey: .status) ?? .played
    }
}

final class RequestHistoryStore: ObservableObject {
    static let shared = RequestHistoryStore()

    @Published private(set) var entries: [RequestHistoryEntry] = []

    private let maxEntries = 250
    private let historyFileURL: URL
    private let storageQueue = DispatchQueue(label: "pitalk.request-history.store")
    private var storageEntries: [RequestHistoryEntry] = []
    private var pendingPersistWorkItem: DispatchWorkItem?
    private let persistDebounceSeconds: TimeInterval = 0.08

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let loquiDir = appSupport.appendingPathComponent("PiTalk", isDirectory: true)
        historyFileURL = loquiDir.appendingPathComponent("request-history.json")

        let initial = loadFromDisk()
        storageEntries = initial
        publishSnapshot(initial)
    }

    @discardableResult
    func add(text: String, voice: String?, sourceApp: String?, sessionId: String?, pid: Int?) -> UUID {
        let entry = RequestHistoryEntry(
            timestamp: Date(),
            text: text,
            voice: voice,
            sourceApp: sourceApp,
            sessionId: sessionId,
            pid: pid,
            status: .queued
        )

        let snapshot = storageQueue.sync { () -> [RequestHistoryEntry] in
            storageEntries.insert(entry, at: 0)
            if storageEntries.count > maxEntries {
                storageEntries.removeLast(storageEntries.count - maxEntries)
            }
            schedulePersistLocked()
            return storageEntries
        }

        publishSnapshot(snapshot)
        return entry.id
    }

    func updateStatus(
        id: UUID,
        to newStatus: RequestPlaybackStatus,
        unlessCurrentIn blockedStatuses: Set<RequestPlaybackStatus> = []
    ) {
        let snapshot = storageQueue.sync { () -> [RequestHistoryEntry]? in
            guard let index = storageEntries.firstIndex(where: { $0.id == id }) else {
                return nil
            }

            let current = storageEntries[index].status
            if blockedStatuses.contains(current) {
                return nil
            }

            guard current != newStatus else {
                return nil
            }

            storageEntries[index].status = newStatus
            schedulePersistLocked()
            return storageEntries
        }

        if let snapshot {
            publishSnapshot(snapshot)
        }
    }

    func clear() {
        let snapshot = storageQueue.sync { () -> [RequestHistoryEntry] in
            storageEntries.removeAll()
            schedulePersistLocked()
            return storageEntries
        }

        publishSnapshot(snapshot)
    }

    /// Cancel all entries that are currently queued or playing (stale entries)
    func cancelAllPending() {
        let snapshot = storageQueue.sync { () -> [RequestHistoryEntry]? in
            var changed = false
            for i in storageEntries.indices {
                if storageEntries[i].status == .queued || storageEntries[i].status == .playing {
                    storageEntries[i].status = .cancelled
                    changed = true
                }
            }

            guard changed else { return nil }
            schedulePersistLocked()
            return storageEntries
        }

        if let snapshot {
            publishSnapshot(snapshot)
        }
    }

    private func schedulePersistLocked() {
        dispatchPrecondition(condition: .onQueue(storageQueue))

        pendingPersistWorkItem?.cancel()
        let snapshot = storageEntries
        let work = DispatchWorkItem { [weak self] in
            self?.persist(snapshot)
        }
        pendingPersistWorkItem = work
        storageQueue.asyncAfter(deadline: .now() + persistDebounceSeconds, execute: work)
    }

    private func publishSnapshot(_ snapshot: [RequestHistoryEntry]) {
        if Thread.isMainThread {
            entries = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.entries = snapshot
            }
        }
    }

    private func loadFromDisk() -> [RequestHistoryEntry] {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: historyFileURL)
            let decoded = try JSONDecoder().decode([RequestHistoryEntry].self, from: data)

            // Clean up stale "playing" and "queued" entries (from crashes or bugs)
            let staleCutoff = Date().addingTimeInterval(-120)  // 2 minutes
            return decoded.prefix(maxEntries).map { entry -> RequestHistoryEntry in
                if (entry.status == .playing || entry.status == .queued) && entry.timestamp < staleCutoff {
                    var fixed = entry
                    fixed.status = entry.status == .playing ? .interrupted : .cancelled
                    return fixed
                }
                return entry
            }
        } catch {
            print("PiTalk: Failed to load request history: \(error)")
            return []
        }
    }

    private func persist(_ entries: [RequestHistoryEntry]) {
        do {
            let directory = historyFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: historyFileURL, options: [.atomic])
        } catch {
            print("PiTalk: Failed to persist request history: \(error)")
        }
    }
}

final class MicrophoneActivityMonitor {
    private let pollQueue = DispatchQueue(label: "loqui.mic.monitor")
    private var timer: DispatchSourceTimer?

    private let pollInterval: TimeInterval
    private let releaseDelay: TimeInterval
    private let onActivityChanged: (Bool) -> Void

    private var isActive = false
    private var keepActiveUntil = Date.distantPast

    init(
        pollInterval: TimeInterval = 0.25,
        releaseDelay: TimeInterval = 0.8,
        onActivityChanged: @escaping (Bool) -> Void
    ) {
        self.pollInterval = pollInterval
        self.releaseDelay = releaseDelay
        self.onActivityChanged = onActivityChanged
    }

    func start() {
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.pollMicrophoneUsage()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        setActive(false)
    }

    private func pollMicrophoneUsage() {
        // Detect whether the default input device is currently running.
        // This does not open the microphone from PiTalk itself.
        let inUse = isDefaultInputDeviceRunning()
        let now = Date()

        if inUse {
            keepActiveUntil = now.addingTimeInterval(releaseDelay)
            if !isActive {
                setActive(true)
            }
        } else if isActive, now >= keepActiveUntil {
            setActive(false)
        }
    }

    private func isDefaultInputDeviceRunning() -> Bool {
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let getDeviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0,
            nil,
            &size,
            &deviceID
        )

        guard getDeviceStatus == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return false
        }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)

        let getRunningStatus = AudioObjectGetPropertyData(
            deviceID,
            &runningAddress,
            0,
            nil,
            &size,
            &running
        )

        guard getRunningStatus == noErr else {
            return false
        }

        return running != 0
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        
        if ProcessInfo.processInfo.environment["PITALK_DEBUG"] == "1" {
            print("PiTalk: Microphone activity changed: \(active ? "ACTIVE" : "INACTIVE")")
        }

        DispatchQueue.main.async {
            self.onActivityChanged(active)
        }
    }
}


final class SpeechPlaybackCoordinator {
    private let queue = DispatchQueue(label: "pitalk.playback.coordinator")

    // Per-source queue buckets keyed by app + session
    private var queuesByKey: [String: [SpeechJob]] = [:]
    private var queueOrder: [String] = []

    private var isPlaying = false
    private var currentProcess: Process?
    private var currentJobHistoryId: UUID?
    private var currentQueueKey: String?
    private var currentRunNonce: UUID?

    private var isMicrophoneActive = false
    
    // Mute toggle - when true, requests are tracked but not spoken
    private var _isMuted = false
    var isMuted: Bool {
        get { queue.sync { _isMuted } }
        set {
            queue.async {
                let wasMuted = self._isMuted
                self._isMuted = newValue
                // If unmuting, resume queue processing
                if wasMuted && !newValue {
                    self.startNextIfNeededLocked()
                }
            }
        }
    }

    // Auto voice assignment for queues that don't specify voice.
    // Uses the voice pool for the current TTS provider
    private var autoVoicePool: [String] {
        switch SpeechPlaybackCoordinator.currentProvider {
        case .elevenlabs:
            return SpeechPlaybackCoordinator.elevenLabsVoicePool
        case .google:
            return SpeechPlaybackCoordinator.googleVoicePool
        }
    }
    private var autoVoiceByQueueKey: [String: String] = [:]
    private var autoVoiceCycleIndex = 0

    private let defaultVoiceProvider: () -> String

    init(defaultVoiceProvider: @escaping () -> String) {
        self.defaultVoiceProvider = defaultVoiceProvider
    }

    func enqueue(text: String,
                 voice: String?,
                 sourceApp: String?,
                 sessionId: String?,
                 pid: Int?) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return state().pending
        }

        let key = queueKey(sourceApp: sourceApp, sessionId: sessionId)

        return queue.sync {
            let resolvedVoice = resolveVoiceForQueueLocked(requestedVoice: voice, queueKey: key)

            let historyEntryId = RequestHistoryStore.shared.add(
                text: trimmed,
                voice: resolvedVoice,
                sourceApp: sourceApp,
                sessionId: sessionId,
                pid: pid
            )

            let job = SpeechJob(
                historyEntryId: historyEntryId,
                text: trimmed,
                voice: resolvedVoice,
                sourceApp: sourceApp,
                sessionId: sessionId,
                pid: pid
            )

            if queuesByKey[key] == nil {
                queuesByKey[key] = []
                queueOrder.append(key)
            }
            queuesByKey[key]?.append(job)

            startNextIfNeededLocked()
            return pendingCountLocked() + (isPlaying ? 1 : 0)
        }
    }

    func state() -> (pending: Int, playing: Bool, currentQueue: String?) {
        queue.sync {
            (pendingCountLocked() + (isPlaying ? 1 : 0), isPlaying, currentQueueKey)
        }
    }

    func stopAll() {
        debugLog("PiTalk: stopAll() called")
        let state = queue.sync { () -> (pending: [UUID], active: UUID?) in
            let pendingIds = allPendingHistoryIdsLocked()
            let activeId = currentJobHistoryId
            
            debugLog("PiTalk: stopAll - pending=\(pendingIds.count), hasActive=\(activeId != nil), currentProcess=\(currentProcess != nil)")

            queuesByKey.removeAll()
            queueOrder.removeAll()
            // Keep voice assignments so continued sessions retain their prior auto-voice.
            terminateCurrentProcessLocked()
            currentJobHistoryId = nil
            currentQueueKey = nil
            currentRunNonce = nil
            isPlaying = false

            return (pending: pendingIds, active: activeId)
        }

        for id in state.pending {
            RequestHistoryStore.shared.updateStatus(id: id, to: .cancelled)
        }

        if let activeId = state.active {
            RequestHistoryStore.shared.updateStatus(id: activeId, to: .interrupted)
        }
    }

    func setMicrophoneActive(_ active: Bool) {
        queue.async {
            self.handleMicrophoneStateChangeLocked(active)
        }
    }

    private func handleMicrophoneStateChangeLocked(_ active: Bool) {
        guard active != isMicrophoneActive else { return }
        isMicrophoneActive = active
        
        let hasProcess = currentProcess != nil
        let isRunning = currentProcess?.isRunning == true
        debugLog("PiTalk: Coordinator mic state: \(active ? "ACTIVE" : "INACTIVE"), hasProcess=\(hasProcess), isRunning=\(isRunning), isPlaying=\(isPlaying)")

        if active {
            // Check if we're actively playing OR in the middle of synthesizing (isPlaying but process not yet started)
            let activelyPlaying = currentProcess?.isRunning == true
            let synthesizing = isPlaying && currentProcess == nil
            
            // Requirement: if mic starts while voice is playing/synthesizing, cancel all queued work at that moment.
            guard activelyPlaying || synthesizing else { 
                debugLog("PiTalk: Mic active but no playback/synthesis running, skipping stop")
                return 
            }
            debugLog("PiTalk: Mic active, stopping playback! (activelyPlaying=\(activelyPlaying), synthesizing=\(synthesizing))")

            let activeId = currentJobHistoryId
            let interruptedQueueKey = currentQueueKey
            
            // Only cancel messages from the currently playing app/session, pause others
            var cancelledIds: [UUID] = []
            if let key = interruptedQueueKey {
                // Get pending IDs from the interrupted queue only
                cancelledIds = queuesByKey[key]?.map(\.historyEntryId) ?? []
                // Remove only this queue
                queuesByKey.removeValue(forKey: key)
                queueOrder.removeAll { $0 == key }
                debugLog("PiTalk: Cancelled queue '\(key)' with \(cancelledIds.count) pending, \(queuesByKey.count) other queues paused")
            }
            
            // Keep voice assignments so this queue key keeps the same voice after interruption.
            terminateCurrentProcessLocked()
            currentJobHistoryId = nil
            currentQueueKey = nil
            currentRunNonce = nil
            isPlaying = false

            for id in cancelledIds {
                RequestHistoryStore.shared.updateStatus(id: id, to: .cancelled)
            }
            if let activeId {
                RequestHistoryStore.shared.updateStatus(id: activeId, to: .interrupted)
            }
        } else {
            // Mic inactive again, resume queued playback.
            startNextIfNeededLocked()
        }
    }

    private func startNextIfNeededLocked() {
        guard !isPlaying, !isMicrophoneActive, !_isMuted else { return }
        guard let (queueKey, job) = dequeueNextJobLocked() else { return }

        isPlaying = true
        currentJobHistoryId = job.historyEntryId
        currentQueueKey = queueKey

        let runNonce = UUID()
        currentRunNonce = runNonce

        RequestHistoryStore.shared.updateStatus(
            id: job.historyEntryId,
            to: .playing,
            unlessCurrentIn: [.cancelled, .interrupted]
        )

        Task { [weak self] in
            await self?.process(job: job, runNonce: runNonce)
        }
    }

    private func process(job: SpeechJob, runNonce: UUID) async {
        var finalStatus: RequestPlaybackStatus = .played

        // If muted, skip playback but mark as played
        if isMuted {
            RequestHistoryStore.shared.updateStatus(
                id: job.historyEntryId,
                to: .played,
                unlessCurrentIn: [.cancelled, .interrupted]
            )
            finishCurrent(runNonce: runNonce)
            return
        }

        do {
            guard await waitUntilMicrophoneInactive(runNonce: runNonce) else {
                // Interrupted by mic activity
                finalStatus = .interrupted
                RequestHistoryStore.shared.updateStatus(id: job.historyEntryId, to: finalStatus)
                finishCurrent(runNonce: runNonce)
                return
            }
            guard shouldContinue(runNonce: runNonce) else {
                // Cancelled
                finalStatus = .cancelled
                RequestHistoryStore.shared.updateStatus(id: job.historyEntryId, to: finalStatus)
                finishCurrent(runNonce: runNonce)
                return
            }

            // Use streaming API for lower latency
            try await synthesizeAndPlayStreaming(job: job, runNonce: runNonce)
        } catch {
            finalStatus = .failed
            print("PiTalk: Playback error: \(error.localizedDescription)")
        }

        RequestHistoryStore.shared.updateStatus(
            id: job.historyEntryId,
            to: finalStatus,
            unlessCurrentIn: [.cancelled, .interrupted]
        )

        finishCurrent(runNonce: runNonce)
    }

    private func finishCurrent(runNonce: UUID) {
        queue.async {
            guard self.currentRunNonce == runNonce else { return }

            self.currentProcess = nil
            self.currentJobHistoryId = nil
            self.currentQueueKey = nil
            self.currentRunNonce = nil
            self.isPlaying = false
            self.startNextIfNeededLocked()
        }
    }

    private func shouldContinue(runNonce: UUID) -> Bool {
        queue.sync {
            currentRunNonce == runNonce
        }
    }

    private func waitUntilMicrophoneInactive(runNonce: UUID) async -> Bool {
        while true {
            let snapshot = queue.sync { (isMicrophoneActive, currentRunNonce == runNonce) }
            let micActive = snapshot.0
            let runStillValid = snapshot.1

            if !runStillValid {
                return false
            }
            if !micActive {
                return true
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    // TTS Provider selection
    enum TTSProvider: String, CaseIterable {
        case elevenlabs = "elevenlabs"
        case google = "google"
        
        var displayName: String {
            switch self {
            case .elevenlabs: return "ElevenLabs"
            case .google: return "Google Cloud"
            }
        }
    }
    
    static var currentProvider: TTSProvider {
        TTSProvider(rawValue: UserDefaults.standard.string(forKey: "ttsProvider") ?? "elevenlabs") ?? .elevenlabs
    }
    
    // ElevenLabs voice ID mapping - British & Scottish voices only
    private static let elevenLabsVoices: [String: String] = [
        // Preferred voices (first in pool)
        "ally": "v2zbX16tJNtRIx8rSHDM",        // Ally - Scottish Glaswegian, relaxed male
        "dorothy": "ThT5KcBeYPX3keUQqHPh",     // Dorothy - British, pleasant young female
        "lily": "pFZP5JQG7iQjIQuC4Bku",        // Lily - British, middle-aged raspy female
        
        // Other British voices
        "alice": "Xb7hH8MSUJpSbSDYk0k2",       // Alice - British, confident female, news style
        "dave": "CYw3kZ02Hs0563khs1Fj",        // Dave - British Essex, conversational male
        "joseph": "Zlb1dXrM653N07WRdFW3",      // Joseph - British, middle-aged news reporter
    ]
    
    // Google Cloud TTS voices - British & Australian
    // Format: display name -> (voice name, language code)
    private static let googleVoices: [String: (voiceName: String, languageCode: String)] = [
        // British - Studio (highest quality)
        "george": ("en-GB-Studio-B", "en-GB"),      // British male, studio quality
        "emma": ("en-GB-Studio-C", "en-GB"),        // British female, studio quality
        
        // British - Neural2 (high quality)
        "oliver": ("en-GB-Neural2-B", "en-GB"),     // British male
        "sophia": ("en-GB-Neural2-A", "en-GB"),     // British female
        "charlotte": ("en-GB-Neural2-C", "en-GB"),  // British female
        "william": ("en-GB-Neural2-D", "en-GB"),    // British male
        
        // Australian - Neural2
        "jack": ("en-AU-Neural2-B", "en-AU"),       // Australian male
        "olivia": ("en-AU-Neural2-A", "en-AU"),     // Australian female
        "isla": ("en-AU-Neural2-C", "en-AU"),       // Australian female
        "liam": ("en-AU-Neural2-D", "en-AU"),       // Australian male
    ]
    
    static let googleVoicePool = ["george", "emma", "oliver", "sophia", "jack", "olivia"]
    static let elevenLabsVoicePool = ["ally", "dorothy", "lily", "alice", "dave", "joseph"]
    
    private func synthesize(job: SpeechJob) async throws -> Data {
        switch Self.currentProvider {
        case .elevenlabs:
            return try await synthesizeWithElevenLabs(job: job)
        case .google:
            return try await synthesizeWithGoogle(job: job)
        }
    }
    
    private func synthesizeWithElevenLabs(job: SpeechJob) async throws -> Data {
        // Get API key from environment, app settings, or ~/.env
        guard let apiKey = ElevenLabsApiKeyManager.resolvedKey(), !apiKey.isEmpty else {
            throw NSError(domain: "PiTalk", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "ElevenLabs API key not found. Add it in settings or import it from ~/.env."
            ])
        }
        
        // Map voice name to ElevenLabs voice ID (default to "ally")
        let voiceId = Self.elevenLabsVoices[job.voice.lowercased()] ?? Self.elevenLabsVoices["ally"] ?? "v2zbX16tJNtRIx8rSHDM"
        
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": job.text,
            "model_id": "eleven_monolingual_v1",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "PiTalk", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "PiTalk", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "ElevenLabs API error (\(httpResponse.statusCode)): \(errorMessage)"
            ])
        }

        return data
    }
    
    private func synthesizeWithGoogle(job: SpeechJob) async throws -> Data {
        guard let apiKey = GoogleApiKeyManager.resolvedKey(), !apiKey.isEmpty else {
            throw NSError(domain: "PiTalk", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Google Cloud API key not found. Add it in settings or import it from ~/.env."
            ])
        }
        
        // Map voice name to Google voice (default to "george")
        let voiceConfig = Self.googleVoices[job.voice.lowercased()] ?? Self.googleVoices["george"] ?? ("en-GB-Studio-B", "en-GB")
        
        let url = URL(string: "https://texttospeech.googleapis.com/v1/text:synthesize?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        
        // Get speech speed from settings (default 1.0)
        let rawSpeed = UserDefaults.standard.object(forKey: "speechSpeed") as? Double ?? 1.0
        let speed = (rawSpeed * 100).rounded() / 100
        
        let body: [String: Any] = [
            "input": ["text": job.text],
            "voice": [
                "languageCode": voiceConfig.languageCode,
                "name": voiceConfig.voiceName
            ],
            "audioConfig": [
                "audioEncoding": "MP3",
                "speakingRate": speed,
                "pitch": 0
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "PiTalk", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "PiTalk", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Google TTS API error (\(httpResponse.statusCode)): \(errorMessage)"
            ])
        }
        
        // Google returns JSON with base64-encoded audio
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let audioContentBase64 = json["audioContent"] as? String,
              let audioData = Data(base64Encoded: audioContentBase64) else {
            throw NSError(domain: "PiTalk", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to decode Google TTS response"
            ])
        }
        
        return audioData
    }
    
    /// Streaming TTS - uses fast model and streaming API for lower latency
    /// For ElevenLabs: uses streaming API. For Google: falls back to non-streaming.
    private func synthesizeAndPlayStreaming(job: SpeechJob, runNonce: UUID) async throws {
        switch Self.currentProvider {
        case .elevenlabs:
            try await synthesizeAndPlayStreamingElevenLabs(job: job, runNonce: runNonce)
        case .google:
            // Google doesn't have a simple REST streaming API, so use non-streaming
            try await synthesizeAndPlayGoogle(job: job, runNonce: runNonce)
        }
    }
    
    /// Google TTS - non-streaming (Google REST API doesn't support streaming)
    private func synthesizeAndPlayGoogle(job: SpeechJob, runNonce: UUID) async throws {
        guard let ffplayPath = findFFPlayPath() else {
            throw NSError(domain: "PiTalk", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "ffplay not found. Install with: brew install ffmpeg"
            ])
        }
        
        // Synthesize the audio
        let audioData = try await synthesizeWithGoogle(job: job)
        
        // Check if we should still continue
        if !shouldContinue(runNonce: runNonce) { return }
        
        // Write to temp file and play
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitalk-google-\(UUID().uuidString).mp3")
        try audioData.write(to: tempURL)
        
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffplayPath)
        process.arguments = [
            "-nodisp",
            "-autoexit",
            "-loglevel", "quiet",
            tempURL.path
        ]
        
        try process.run()
        
        queue.sync {
            self.currentProcess = process
        }
        
        // Wait for ffplay to finish
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
    }
    
    /// ElevenLabs streaming TTS
    private func synthesizeAndPlayStreamingElevenLabs(job: SpeechJob, runNonce: UUID) async throws {
        // Get API key from environment, app settings, or ~/.env
        guard let apiKey = ElevenLabsApiKeyManager.resolvedKey(), !apiKey.isEmpty else {
            throw NSError(domain: "PiTalk", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "ElevenLabs API key not found. Add it in settings or import it from ~/.env."
            ])
        }
        
        guard let ffplayPath = findFFPlayPath() else {
            throw NSError(domain: "PiTalk", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "ffplay not found. Install with: brew install ffmpeg"
            ])
        }
        
        // Map voice name to ElevenLabs voice ID
        let voiceId = Self.elevenLabsVoices[job.voice.lowercased()] ?? Self.elevenLabsVoices["ally"] ?? "v2zbX16tJNtRIx8rSHDM"
        
        // Use streaming endpoint with flash model for lowest latency
        // Use mp3_44100_64 for good quality with lower bandwidth
        var urlComponents = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream")!
        urlComponents.queryItems = [
            URLQueryItem(name: "output_format", value: "mp3_44100_64"),
            URLQueryItem(name: "optimize_streaming_latency", value: "4")
        ]
        
        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        // Get speech speed from settings (default 1.0)
        let rawSpeed = UserDefaults.standard.object(forKey: "speechSpeed") as? Double ?? 1.0
        // Round to 2 decimal places to avoid floating point precision issues in JSON
        let speed = (rawSpeed * 100).rounded() / 100
        
        if ProcessInfo.processInfo.environment["PITALK_DEBUG"] == "1" {
            print("PiTalk: Synthesizing with speed=\(speed), voice=\(job.voice), text=\(job.text.prefix(50))...")
        }
        
        var voiceSettings: [String: Any] = [
            "stability": 0.5,
            "similarity_boost": 0.75
        ]
        // Only add speed if not default (some models may not support it)
        if abs(speed - 1.0) > 0.01 {
            voiceSettings["speed"] = speed
        }
        
        let body: [String: Any] = [
            "text": job.text,
            "model_id": "eleven_flash_v2_5",  // Fastest model (~75ms latency)
            "voice_settings": voiceSettings
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // Stream to temp file and start playing once we have some data
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitalk-stream-\(UUID().uuidString).mp3")
        
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempURL)
        
        defer {
            try? fileHandle.close()
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        // Use bytes(for:) to stream the response
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "PiTalk", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        guard httpResponse.statusCode == 200 else {
            var errorData = Data()
            for try await byte in asyncBytes {
                errorData.append(byte)
                if errorData.count > 1000 { break }
            }
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "PiTalk", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "ElevenLabs API error (\(httpResponse.statusCode)): \(errorMessage)"
            ])
        }
        
        // Collect chunks and start playback early
        var totalBytes = 0
        var playbackStarted = false
        var ffplayProcess: Process?
        var buffer = Data()
        let flushSize = 4096  // Flush every 4KB
        
        for try await byte in asyncBytes {
            if !shouldContinue(runNonce: runNonce) {
                ffplayProcess?.terminate()
                return
            }
            
            buffer.append(byte)
            totalBytes += 1
            
            // Flush buffer periodically
            if buffer.count >= flushSize {
                fileHandle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            
            // Start playback after receiving ~16KB of audio data (enough for ffplay to start)
            if !playbackStarted && totalBytes >= 16384 {
                playbackStarted = true
                
                // Flush remaining buffer
                if !buffer.isEmpty {
                    fileHandle.write(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                try fileHandle.synchronize()
                
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffplayPath)
                process.arguments = [
                    "-nodisp",
                    "-autoexit",
                    "-loglevel", "quiet",
                    tempURL.path
                ]
                
                try process.run()
                ffplayProcess = process
                
                queue.sync {
                    self.currentProcess = process
                }
            }
        }
        
        // Flush any remaining buffer
        if !buffer.isEmpty {
            fileHandle.write(buffer)
        }
        
        // If we never started playback (very short audio), start it now
        if !playbackStarted {
            try fileHandle.synchronize()
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffplayPath)
            process.arguments = [
                "-nodisp",
                "-autoexit",
                "-loglevel", "quiet",
                tempURL.path
            ]
            
            try process.run()
            ffplayProcess = process
            
            queue.sync {
                self.currentProcess = process
            }
        }
        
        // Wait for ffplay to finish
        if let process = ffplayProcess {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        }
    }

    private func play(audioData: Data) async throws {
        guard let ffplayPath = findFFPlayPath() else {
            throw NSError(domain: "PiTalk", code: 404, userInfo: [NSLocalizedDescriptionKey: "ffplay not found. Install with: brew install ffmpeg"])
        }

        // ElevenLabs returns MP3, save with .mp3 extension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitalk-\(UUID().uuidString).mp3")
        try audioData.write(to: tempURL)

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffplayPath)
        process.arguments = [
            "-nodisp",
            "-autoexit",
            "-loglevel", "quiet",
            tempURL.path
        ]

        try process.run()

        queue.sync {
            self.currentProcess = process
        }

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
    }

    private func findFFPlayPath() -> String? {
        let paths = [
            "/opt/homebrew/bin/ffplay",
            "/usr/local/bin/ffplay",
            "/usr/bin/ffplay"
        ]

        for path in paths where FileManager.default.fileExists(atPath: path) {
            return path
        }

        return nil
    }

    private func terminateCurrentProcessLocked() {
        guard let process = currentProcess else {
            debugLog("PiTalk: terminateCurrentProcessLocked - no current process")
            return
        }

        debugLog("PiTalk: terminateCurrentProcessLocked - process PID=\(process.processIdentifier), isRunning=\(process.isRunning)")
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                if process.isRunning {
                    debugLog("PiTalk: Force killing process PID=\(pid)")
                    kill(pid, SIGKILL)
                }
            }
        }

        currentProcess = nil
    }

    private func resolveVoiceForQueueLocked(requestedVoice: String?, queueKey: String) -> String {
        let trimmedRequested = requestedVoice?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested = trimmedRequested, !requested.isEmpty {
            return requested
        }

        if let assigned = autoVoiceByQueueKey[queueKey] {
            return assigned
        }

        // Check all already-assigned voices, not just active queues.
        // This ensures different sessions get different voices even if they're
        // not concurrent (e.g., session A finishes before session B starts).
        let usedVoices = Set(autoVoiceByQueueKey.values)

        if let freeVoice = autoVoicePool.first(where: { !usedVoices.contains($0) }) {
            autoVoiceByQueueKey[queueKey] = freeVoice
            return freeVoice
        }

        guard !autoVoicePool.isEmpty else {
            return defaultVoiceProvider()
        }

        let cycled = autoVoicePool[autoVoiceCycleIndex % autoVoicePool.count]
        autoVoiceCycleIndex += 1
        autoVoiceByQueueKey[queueKey] = cycled
        return cycled
    }

    private func queueKey(sourceApp: String?, sessionId: String?) -> String {
        let app = normalizedSourceApp(sourceApp)
        let session = normalizedSessionId(sessionId)
        return "\(app)::\(session)"
    }

    private func normalizedSourceApp(_ sourceApp: String?) -> String {
        let trimmed = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : "unknown"
    }

    private func normalizedSessionId(_ sessionId: String?) -> String {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : "__none__"
    }

    private func dequeueNextJobLocked() -> (String, SpeechJob)? {
        while !queueOrder.isEmpty {
            let key = queueOrder.first!

            guard var jobs = queuesByKey[key], !jobs.isEmpty else {
                queueOrder.removeFirst()
                queuesByKey.removeValue(forKey: key)
                continue
            }

            let job = jobs.removeFirst()

            if jobs.isEmpty {
                // Queue for this session is empty, remove it and move to next
                queueOrder.removeFirst()
                queuesByKey.removeValue(forKey: key)
            } else {
                // Keep processing this session's queue (don't move to end)
                queuesByKey[key] = jobs
            }

            return (key, job)
        }

        return nil
    }

    private func allPendingHistoryIdsLocked() -> [UUID] {
        queuesByKey.values.flatMap { $0.map(\.historyEntryId) }
    }

    private func pendingCountLocked() -> Int {
        queuesByKey.values.reduce(0) { $0 + $1.count }
    }
}


final class LocalSpeechBroker {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loqui.local.broker")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let coordinator: SpeechPlaybackCoordinator

    init(port: Int, coordinator: SpeechPlaybackCoordinator) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "PiTalk", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid broker port: \(port)"])
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params, on: nwPort)
        self.coordinator = coordinator
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                break
            case .failed(let error):
                print("PiTalk: Broker failed: \(error)")
            default:
                break
            }
        }

        listener.start(queue: queue)
    }

    func stop() {
        debugLog("PiTalk: LocalSpeechBroker.stop() - cancelling listener")
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.send(response: .failure("Connection error: \(error.localizedDescription)"), on: connection)
                return
            }

            var newBuffer = buffer
            if let data {
                newBuffer.append(data)
            }

            if let range = newBuffer.range(of: Data([0x0A])) {
                let line = newBuffer.subdata(in: 0..<range.lowerBound)
                self.handleLine(line, on: connection)
                return
            }

            if isComplete {
                self.handleLine(newBuffer, on: connection)
                return
            }

            self.receive(on: connection, buffer: newBuffer)
        }
    }

    private func handleLine(_ line: Data, on connection: NWConnection) {
        guard !line.isEmpty else {
            debugLog("PiTalk Broker: received empty request")
            send(response: .failure("Empty request"), on: connection)
            return
        }

        let request: BrokerRequest
        do {
            request = try decoder.decode(BrokerRequest.self, from: line)
            debugLog("PiTalk Broker: received request type=\(request.type), text=\(request.text?.prefix(50) ?? "nil")")
        } catch {
            debugLog("PiTalk Broker: invalid JSON: \(String(data: line, encoding: .utf8) ?? "?")")
            send(response: .failure("Invalid JSON request"), on: connection)
            return
        }

        switch request.type {
        case "health":
            let state = coordinator.state()
            debugLog("PiTalk Broker: health check - pending=\(state.pending), playing=\(state.playing)")
            send(response: .success(pending: state.pending, playing: state.playing, currentQueue: state.currentQueue), on: connection)

        case "speak":
            guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                debugLog("PiTalk Broker: speak request missing text")
                send(response: .failure("Missing text"), on: connection)
                return
            }

            let queued = coordinator.enqueue(
                text: text,
                voice: request.voice,
                sourceApp: request.sourceApp,
                sessionId: request.sessionId,
                pid: request.pid
            )
            send(response: .success(queued: queued), on: connection)

        case "stop":
            coordinator.stopAll()
            let state = coordinator.state()
            send(response: .success(pending: state.pending, playing: state.playing, currentQueue: state.currentQueue), on: connection)

        default:
            send(response: .failure("Unknown command: \(request.type)"), on: connection)
        }
    }

    private func send(response: BrokerResponse, on connection: NWConnection) {
        let payload: Data
        do {
            var data = try encoder.encode(response)
            data.append(0x0A)
            payload = data
        } catch {
            let fallback = "{\"ok\":false,\"error\":\"Encoding failed\"}\n"
            connection.send(content: fallback.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @StateObject private var monitor = VoiceMonitor()
    
    var body: some View {
        TabView {
            SessionsTabView(monitor: monitor)
                .tabItem {
                    Label("Sessions", systemImage: "list.bullet")
                }

            SettingsTabView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
    }
}

// MARK: - Sessions Tab (Main View)

struct SessionsTabView: View {
    @ObservedObject var monitor: VoiceMonitor
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(monitor.summary.uiColor)
                    .frame(width: 12, height: 12)
                Text(monitor.summary.label)
                    .font(.headline)
                
                Spacer()
                
                // Speed control
                HStack(spacing: 4) {
                    Image(systemName: "hare")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $monitor.speechSpeed, in: 0.7...1.2, step: 0.05)
                        .frame(width: 80)
                    Text(String(format: "%.1fx", monitor.speechSpeed))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                
                // Server toggle
                Toggle("", isOn: Binding(
                    get: { monitor.serverEnabled },
                    set: { newValue in
                        monitor.serverEnabled = newValue
                        monitor.handleServerToggle(enabled: newValue)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding()
            
            // Status pills
            HStack(spacing: 8) {
                StatusPill(text: "sessions: \(monitor.sessions.count)")
                if monitor.speakingCount > 0 {
                    StatusPill(text: "speaking: \(monitor.speakingCount)", color: .red)
                }
                if monitor.totalQueuedItems > 0 {
                    StatusPill(text: "queued: \(monitor.totalQueuedItems)", color: .orange)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            
            Divider()
            
            // Sessions list
            if monitor.sessions.isEmpty {
                VStack {
                    Spacer()
                    Text("No active pi sessions")
                        .foregroundStyle(.secondary)
                    Text("Start a pi session to see it here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(monitor.sessions) { session in
                            SessionRowView(session: session, monitor: monitor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            
            Divider()
            
            // Footer buttons
            HStack {
                Button("Stop All") {
                    monitor.stopAll()
                }
                .disabled(monitor.speakingCount == 0 && monitor.totalQueuedItems == 0)
                
                Spacer()
                
                if let message = monitor.lastMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = .secondary
    
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(8)
    }
}

struct SessionRowView: View {
    let session: VoiceSession
    @ObservedObject var monitor: VoiceMonitor
    @State private var isHovered = false
    
    private var displayName: String {
        let app = session.sourceApp
        if let sid = session.sessionId {
            let shortId = sid.prefix(12)
            return "\(app) [\(shortId)...]"
        }
        return app
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Status indicator
            Circle()
                .fill(session.activity.color)
                .frame(width: 10, height: 10)
            
            // Main content
            VStack(alignment: .leading, spacing: 4) {
                // Title row
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(displayName)
                        .font(.system(.body, design: .default, weight: .semibold))
                    
                    Text("·")
                        .foregroundStyle(.tertiary)
                    
                    Text(session.activity.label)
                        .font(.subheadline)
                        .foregroundStyle(session.activity.color)
                }
                
                // Last spoken text
                if let text = session.currentText ?? session.lastSpokenText {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                
                // Metadata row
                HStack(spacing: 12) {
                    if let pid = session.pid {
                        Label {
                            Text("\(pid)")
                                .font(.system(.caption2, design: .monospaced))
                        } icon: {
                            Image(systemName: "number")
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(.tertiary)
                    }
                    
                    if let voice = session.voice {
                        Label {
                            Text(voice)
                                .font(.caption2)
                        } icon: {
                            Image(systemName: "waveform")
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(.tertiary)
                    }
                    
                    if session.queuedCount > 0 {
                        Label {
                            Text("\(session.queuedCount) queued")
                                .font(.caption2)
                        } icon: {
                            Image(systemName: "text.badge.plus")
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(.orange)
                    }
                }
            }
            
            Spacer()
            
            // Jump button
            if session.pid != nil {
                Button {
                    monitor.jump(to: session)
                } label: {
                    Text("Jump")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(isHovered ? 0.2 : 0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 1 : 0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if session.pid != nil {
                monitor.jump(to: session)
            }
        }
    }
}

// MARK: - Settings Tab (renamed from General)

struct SettingsTabView: View {
    @AppStorage("ttsProvider") var provider = "elevenlabs"
    @AppStorage("ttsVoice") var voice = "ally"
    @AppStorage("elevenLabsApiKey") var elevenLabsApiKey = ""
    @AppStorage("googleTtsApiKey") var googleApiKey = ""
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("showDockIcon") var showDockIcon = true
    @State private var isPreviewPlaying = false
    @State private var showApiKey = false
    @State private var envImportMessage: String?
    @State private var envImportMessageColor: Color = .secondary

    private var currentProvider: SpeechPlaybackCoordinator.TTSProvider {
        SpeechPlaybackCoordinator.TTSProvider(rawValue: provider) ?? .elevenlabs
    }
    
    // ElevenLabs voices - British & Scottish
    let elevenLabsVoices = ["ally", "dorothy", "lily", "alice", "dave", "joseph"]
    
    // Google voices - British & Australian
    let googleVoices = ["george", "emma", "oliver", "sophia", "charlotte", "william", "jack", "olivia", "isla", "liam"]
    
    private var availableVoices: [String] {
        currentProvider == .elevenlabs ? elevenLabsVoices : googleVoices
    }
    
    private var trimmedElevenLabsApiKey: String {
        elevenLabsApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var trimmedGoogleApiKey: String {
        googleApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveApiKey: String? {
        switch currentProvider {
        case .elevenlabs:
            if !trimmedElevenLabsApiKey.isEmpty { return trimmedElevenLabsApiKey }
            return ElevenLabsApiKeyManager.resolvedKey()
        case .google:
            if !trimmedGoogleApiKey.isEmpty { return trimmedGoogleApiKey }
            return GoogleApiKeyManager.resolvedKey()
        }
    }

    private var hasApiKey: Bool {
        effectiveApiKey?.isEmpty == false
    }
    
    var body: some View {
        Form {
            Section("TTS Provider") {
                Picker("Provider", selection: $provider) {
                    Text("ElevenLabs").tag("elevenlabs")
                    Text("Google Cloud").tag("google")
                }
                .pickerStyle(.segmented)
                .onChange(of: provider) { newValue in
                    // Reset voice to default for the new provider
                    if newValue == "elevenlabs" && !elevenLabsVoices.contains(voice) {
                        voice = "ally"
                    } else if newValue == "google" && !googleVoices.contains(voice) {
                        voice = "george"
                    }
                }
                
                if currentProvider == .elevenlabs {
                    Text("Scottish & British accents • Streaming support • Best quality")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("British & Australian accents • No streaming • Good quality")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if currentProvider == .elevenlabs {
                Section("ElevenLabs API") {
                    if !hasApiKey {
                        Text("Add your ElevenLabs API key to start using PiTalk.")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }

                    HStack {
                        if showApiKey {
                            TextField("API Key", text: $elevenLabsApiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Key", text: $elevenLabsApiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(showApiKey ? "Hide" : "Show") {
                            showApiKey.toggle()
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack(spacing: 8) {
                        Button("Import from ~/.env") {
                            importElevenLabsApiKey()
                        }
                        .buttonStyle(.bordered)

                        Text("Looks for ELEVEN_API_KEY or ELEVENLABS_API_KEY")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let envImportMessage {
                        Text(envImportMessage)
                            .font(.caption)
                            .foregroundStyle(envImportMessageColor)
                    }
                    
                    if hasApiKey {
                        Text("API key configured ✓")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Text("Get your API key from elevenlabs.io")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            } else {
                Section("Google Cloud API") {
                    if !hasApiKey {
                        Text("Add your Google Cloud API key to start using PiTalk.")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }

                    HStack {
                        if showApiKey {
                            TextField("API Key", text: $googleApiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Key", text: $googleApiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(showApiKey ? "Hide" : "Show") {
                            showApiKey.toggle()
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack(spacing: 8) {
                        Button("Import from ~/.env") {
                            importGoogleApiKey()
                        }
                        .buttonStyle(.bordered)

                        Text("Looks for GOOGLE_TTS_API_KEY")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let envImportMessage {
                        Text(envImportMessage)
                            .font(.caption)
                            .foregroundStyle(envImportMessageColor)
                    }
                    
                    if hasApiKey {
                        Text("API key configured ✓")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Text("Get your API key from console.cloud.google.com")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            Section("Voice") {
                HStack {
                    Picker("Voice", selection: $voice) {
                        ForEach(availableVoices, id: \.self) { v in
                            Text(v.capitalized).tag(v)
                        }
                    }
                    .pickerStyle(.menu)

                    Spacer()

                    Button(isPreviewPlaying ? "Playing…" : "Preview") {
                        previewVoice(voice)
                    }
                    .disabled(isPreviewPlaying || !hasApiKey)
                }
                
                if currentProvider == .google {
                    Text(voiceDescription(voice))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        setLaunchAtLogin(enabled: newValue)
                    }

                Toggle("Show Dock Icon", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _ in
                        updateDockIcon()
                    }
            }

            Section("Shortcut") {
                HStack {
                    Text("Stop Speech")
                        .foregroundColor(.secondary)
                    Spacer()
                    KeyboardShortcutView(keys: ["⌘", "."])
                }
            }
        }
        .formStyle(.grouped)
    }
    
    func voiceDescription(_ voice: String) -> String {
        switch voice.lowercased() {
        case "george": return "British male (Studio quality)"
        case "emma": return "British female (Studio quality)"
        case "oliver": return "British male (Neural2)"
        case "sophia": return "British female (Neural2)"
        case "charlotte": return "British female (Neural2)"
        case "william": return "British male (Neural2)"
        case "jack": return "Australian male (Neural2)"
        case "olivia": return "Australian female (Neural2)"
        case "isla": return "Australian female (Neural2)"
        case "liam": return "Australian male (Neural2)"
        default: return ""
        }
    }
    
    func updateDockIcon() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.updateDockIconVisibility()
        }
    }

    func importElevenLabsApiKey() {
        switch ElevenLabsApiKeyManager.importFromDotEnv(overwriteExisting: true) {
        case .imported:
            elevenLabsApiKey = UserDefaults.standard.string(forKey: ElevenLabsApiKeyManager.userDefaultsKey) ?? elevenLabsApiKey
            envImportMessage = "Imported API key from ~/.env"
            envImportMessageColor = .green
        case .missingFile:
            envImportMessage = "No ~/.env file found"
            envImportMessageColor = .orange
        case .keyNotFound:
            envImportMessage = "No ELEVEN_API_KEY or ELEVENLABS_API_KEY found in ~/.env"
            envImportMessageColor = .orange
        case .skippedExisting:
            envImportMessage = "API key already configured"
            envImportMessageColor = .secondary
        }
    }
    
    func importGoogleApiKey() {
        switch GoogleApiKeyManager.importFromDotEnv(overwriteExisting: true) {
        case .imported:
            googleApiKey = UserDefaults.standard.string(forKey: GoogleApiKeyManager.userDefaultsKey) ?? googleApiKey
            envImportMessage = "Imported API key from ~/.env"
            envImportMessageColor = .green
        case .missingFile:
            envImportMessage = "No ~/.env file found"
            envImportMessageColor = .orange
        case .keyNotFound:
            envImportMessage = "No GOOGLE_TTS_API_KEY found in ~/.env"
            envImportMessageColor = .orange
        case .skippedExisting:
            envImportMessage = "API key already configured"
            envImportMessageColor = .secondary
        }
    }
    
    func previewVoice(_ voiceName: String) {
        guard !isPreviewPlaying else { return }
        guard let apiKey = effectiveApiKey, !apiKey.isEmpty else { return }
        isPreviewPlaying = true
        
        let text = "Hi, this is \(voiceName.capitalized). I'm ready to help you with your coding projects."
        
        Task {
            do {
                let audioData: Data
                
                if currentProvider == .elevenlabs {
                    audioData = try await previewElevenLabsVoice(voiceName: voiceName, text: text, apiKey: apiKey)
                } else {
                    audioData = try await previewGoogleVoice(voiceName: voiceName, text: text, apiKey: apiKey)
                }
                
                // Write MP3 to temp file and play
                let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("voice_preview.mp3")
                try audioData.write(to: tempFile)
                
                // Play using ffplay or afplay
                let ffplayPath = ["/opt/homebrew/bin/ffplay", "/usr/local/bin/ffplay"].first { 
                    FileManager.default.fileExists(atPath: $0) 
                }
                
                let process = Process()
                if let ffplay = ffplayPath {
                    process.executableURL = URL(fileURLWithPath: ffplay)
                    process.arguments = ["-nodisp", "-autoexit", "-loglevel", "quiet", tempFile.path]
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                    process.arguments = [tempFile.path]
                }
                
                process.terminationHandler = { _ in
                    DispatchQueue.main.async {
                        self.isPreviewPlaying = false
                    }
                    try? FileManager.default.removeItem(at: tempFile)
                }
                try process.run()
            } catch {
                print("Voice preview error: \(error)")
                await MainActor.run {
                    isPreviewPlaying = false
                }
            }
        }
    }
    
    func previewElevenLabsVoice(voiceName: String, text: String, apiKey: String) async throws -> Data {
        let voiceIds: [String: String] = [
            "ally": "v2zbX16tJNtRIx8rSHDM",
            "dorothy": "ThT5KcBeYPX3keUQqHPh",
            "lily": "pFZP5JQG7iQjIQuC4Bku",
            "alice": "Xb7hH8MSUJpSbSDYk0k2",
            "dave": "CYw3kZ02Hs0563khs1Fj",
            "joseph": "Zlb1dXrM653N07WRdFW3",
        ]
        
        let voiceId = voiceIds[voiceName.lowercased()] ?? "v2zbX16tJNtRIx8rSHDM"
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        
        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_monolingual_v1",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "PiTalk", code: 500, userInfo: [NSLocalizedDescriptionKey: "ElevenLabs API error"])
        }
        
        return data
    }
    
    func previewGoogleVoice(voiceName: String, text: String, apiKey: String) async throws -> Data {
        let googleVoices: [String: (voiceName: String, languageCode: String)] = [
            "george": ("en-GB-Studio-B", "en-GB"),
            "emma": ("en-GB-Studio-C", "en-GB"),
            "oliver": ("en-GB-Neural2-B", "en-GB"),
            "sophia": ("en-GB-Neural2-A", "en-GB"),
            "charlotte": ("en-GB-Neural2-C", "en-GB"),
            "william": ("en-GB-Neural2-D", "en-GB"),
            "jack": ("en-AU-Neural2-B", "en-AU"),
            "olivia": ("en-AU-Neural2-A", "en-AU"),
            "isla": ("en-AU-Neural2-C", "en-AU"),
            "liam": ("en-AU-Neural2-D", "en-AU"),
        ]
        
        let voiceConfig = googleVoices[voiceName.lowercased()] ?? ("en-GB-Studio-B", "en-GB")
        let url = URL(string: "https://texttospeech.googleapis.com/v1/text:synthesize?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "input": ["text": text],
            "voice": [
                "languageCode": voiceConfig.languageCode,
                "name": voiceConfig.voiceName
            ],
            "audioConfig": [
                "audioEncoding": "MP3",
                "speakingRate": 1.0,
                "pitch": 0
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "PiTalk", code: 500, userInfo: [NSLocalizedDescriptionKey: "Google TTS API error"])
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let audioContentBase64 = json["audioContent"] as? String,
              let audioData = Data(base64Encoded: audioContentBase64) else {
            throw NSError(domain: "PiTalk", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to decode Google response"])
        }
        
        return audioData
    }
    
    func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to set launch at login: \(error)")
            }
        }
    }
}

struct HistoryView: View {
    @StateObject private var historyStore = RequestHistoryStore.shared
    @State private var searchText = ""
    @State private var selectedAppFilter = Self.allAppsToken
    @State private var selectedSessionFilter = Self.allSessionsToken
    @State private var derivedState = DerivedState.empty

    private static let allAppsToken = "__all_apps__"
    private static let allSessionsToken = "__all_sessions__"
    private static let noSessionToken = "__no_session__"

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private struct DerivedState {
        let totalEntryCount: Int
        let appFilterOptions: [String]
        let sessionFilterOptions: [String]
        let isFiltering: Bool
        let filteredEntries: [RequestHistoryEntry]
        let queueEntries: [RequestHistoryEntry]
        let completedEntries: [RequestHistoryEntry]

        static let empty = DerivedState(
            totalEntryCount: 0,
            appFilterOptions: [HistoryView.allAppsToken],
            sessionFilterOptions: [HistoryView.allSessionsToken],
            isFiltering: false,
            filteredEntries: [],
            queueEntries: [],
            completedEntries: []
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("History")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("\(derivedState.queueEntries.count) queued · \(derivedState.completedEntries.count) completed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if derivedState.isFiltering {
                        Button("Reset Filters") {
                            searchText = ""
                            selectedAppFilter = Self.allAppsToken
                            selectedSessionFilter = Self.allSessionsToken
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                    }
                    Button {
                        historyStore.clear()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(derivedState.totalEntryCount == 0)
                    .help("Clear all history")
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    TextField("Search text, app, or session...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)

                HStack(spacing: 8) {
                    Picker("App", selection: $selectedAppFilter) {
                        ForEach(derivedState.appFilterOptions, id: \.self) { option in
                            Text(appFilterLabel(option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Picker("Session", selection: $selectedSessionFilter) {
                        ForEach(derivedState.sessionFilterOptions, id: \.self) { option in
                            Text(sessionFilterLabel(option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if derivedState.totalEntryCount == 0 {
                emptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "No requests yet",
                    subtitle: "Speech requests will appear here"
                )
            } else if derivedState.filteredEntries.isEmpty {
                emptyState(
                    icon: "magnifyingglass",
                    title: "No matches",
                    subtitle: "Try adjusting your search or filters"
                )
            } else {
                List {
                    if !derivedState.queueEntries.isEmpty {
                        Section {
                            ForEach(derivedState.queueEntries) { entry in
                                entryRow(entry)
                            }
                        } header: {
                            Label("Queue", systemImage: "play.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section {
                        ForEach(derivedState.completedEntries) { entry in
                            entryRow(entry)
                        }
                    } header: {
                        Label("Completed", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { recomputeDerivedState() }
        .onReceive(historyStore.$entries) { _ in recomputeDerivedState() }
        .onChange(of: searchText) { _ in recomputeDerivedState() }
        .onChange(of: selectedAppFilter) { _ in recomputeDerivedState() }
        .onChange(of: selectedSessionFilter) { _ in recomputeDerivedState() }
    }

    private func recomputeDerivedState() {
        let entries = historyStore.entries

        let appOptions = [Self.allAppsToken] + Set(entries.map { normalizedAppName($0.sourceApp) }).sorted()

        var sessionOptions = [Self.allSessionsToken]
        if entries.contains(where: { normalizedSessionId($0.sessionId) == nil }) {
            sessionOptions.append(Self.noSessionToken)
        }
        sessionOptions.append(contentsOf: Set(entries.compactMap { normalizedSessionId($0.sessionId) }).sorted())

        var resolvedAppFilter = selectedAppFilter
        var resolvedSessionFilter = selectedSessionFilter

        if resolvedAppFilter != Self.allAppsToken && !appOptions.contains(resolvedAppFilter) {
            resolvedAppFilter = Self.allAppsToken
        }
        if resolvedSessionFilter != Self.allSessionsToken && !sessionOptions.contains(resolvedSessionFilter) {
            resolvedSessionFilter = Self.allSessionsToken
        }

        let searchLower = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filteredEntries = entries.filter { entry in
            if !searchLower.isEmpty {
                let textMatches = entry.text.lowercased().contains(searchLower)
                let appMatches = normalizedAppName(entry.sourceApp).lowercased().contains(searchLower)
                let sessionMatches = (entry.sessionId?.lowercased().contains(searchLower) ?? false)
                if !textMatches && !appMatches && !sessionMatches {
                    return false
                }
            }

            if resolvedAppFilter != Self.allAppsToken,
               normalizedAppName(entry.sourceApp) != resolvedAppFilter {
                return false
            }

            if resolvedSessionFilter == Self.noSessionToken {
                return normalizedSessionId(entry.sessionId) == nil
            }

            if resolvedSessionFilter != Self.allSessionsToken,
               normalizedSessionId(entry.sessionId) != resolvedSessionFilter {
                return false
            }

            return true
        }

        let queueEntries = filteredEntries
            .filter { $0.status.isInQueue }
            .sorted { $0.timestamp < $1.timestamp }
        let completedEntries = filteredEntries.filter { !$0.status.isInQueue }
        let isFiltering = !searchLower.isEmpty || resolvedAppFilter != Self.allAppsToken || resolvedSessionFilter != Self.allSessionsToken

        derivedState = DerivedState(
            totalEntryCount: entries.count,
            appFilterOptions: appOptions,
            sessionFilterOptions: sessionOptions,
            isFiltering: isFiltering,
            filteredEntries: filteredEntries,
            queueEntries: queueEntries,
            completedEntries: completedEntries
        )

        if selectedAppFilter != resolvedAppFilter {
            selectedAppFilter = resolvedAppFilter
        }
        if selectedSessionFilter != resolvedSessionFilter {
            selectedSessionFilter = resolvedSessionFilter
        }
    }

    private func normalizedAppName(_ sourceApp: String?) -> String {
        let trimmed = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : "Unknown"
    }

    private func normalizedSessionId(_ sessionId: String?) -> String? {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private func appFilterLabel(_ option: String) -> String {
        option == Self.allAppsToken ? "All apps" : option
    }

    private func sessionFilterLabel(_ option: String) -> String {
        if option == Self.allSessionsToken { return "All sessions" }
        if option == Self.noSessionToken { return "No session" }
        return String(option.prefix(12)) + (option.count > 12 ? "…" : "")
    }

    @ViewBuilder
    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.5))
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func entryRow(_ entry: RequestHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(normalizedAppName(entry.sourceApp))
                    .font(.subheadline)
                    .fontWeight(.medium)

                statusBadge(for: entry.status)

                Spacer()

                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(entry.text)
                .font(.callout)
                .lineLimit(3)
                .foregroundColor(.primary.opacity(0.9))

            HStack(spacing: 8) {
                if let voice = entry.voice, !voice.isEmpty {
                    Label(voice, systemImage: "waveform")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let sessionId = normalizedSessionId(entry.sessionId) {
                    Label(String(sessionId.prefix(8)), systemImage: "number")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if entry.status == .interrupted {
                    Label("Stopped via ⌘.", systemImage: "stop.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(for status: RequestPlaybackStatus) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(status.tintColor)
                .frame(width: 6, height: 6)
            Text(status.displayName)
                .font(.caption2)
                .foregroundColor(status.tintColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(status.tintColor.opacity(0.12))
        .cornerRadius(4)
    }
}


struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                helpSection(title: "Using PiTalk with Pi Agent", icon: "terminal") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How to use PiTalk with the pi.dev agent:")
                            .font(.callout)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("1. Keep PiTalk running in the menu bar.")
                            Text("2. Install the extension in Pi.")
                            Text("3. Ask Pi to respond normally — the extension routes <voice> content to PiTalk.")
                            Text("4. Use Pi commands to control playback.")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)

                        CodeRow(code: "pi install npm:@swairshah/pi-talk", description: "Install extension")

                        VStack(alignment: .leading, spacing: 4) {
                            CodeRow(code: "/tts", description: "Toggle TTS on/off")
                            CodeRow(code: "/tts-mute", description: "Mute/unmute audio")
                            CodeRow(code: "/tts-say <text>", description: "Speak arbitrary text")
                            CodeRow(code: "/tts-stop", description: "Stop speech")
                            CodeRow(code: "/tts-status", description: "Check extension + server status")
                        }
                    }
                }

                helpSection(title: "CLI Usage", icon: "chevron.left.forwardslash.chevron.right") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use ptts in Terminal:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            CodeRow(code: "ptts \"Hello, world!\"", description: "Enqueue speech")
                            CodeRow(code: "ptts -v alba \"Hello\"", description: "Pick a voice")
                            CodeRow(code: "echo \"Hello\" | ptts", description: "Pipe input")
                            CodeRow(code: "ptts --stop", description: "Stop playback")
                        }
                    }
                }

                helpSection(title: "HTTP API", icon: "network") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Health endpoint:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        CodeRow(code: "GET http://127.0.0.1:18080/health", description: "Check PiTalk app health")
                    }
                }

                helpSection(title: "Local Broker Queue", icon: "arrow.triangle.branch") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Centralized playback queue endpoint:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        CodeRow(code: "TCP 127.0.0.1:18081", description: "Connect via NDJSON")
                        CodeRow(code: "{\"type\":\"speak\",\"text\":\"Hi\"}", description: "Enqueue request")
                        CodeRow(code: "{\"type\":\"stop\"}", description: "Stop and clear queue")
                        CodeRow(code: "{\"type\":\"health\"}", description: "Check broker status")
                    }
                }

                Spacer(minLength: 8)
            }
            .padding()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private func helpSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.headline)
            }

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    Text("PiTalk")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Voice for Pi")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 8) {
                    Text("About")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("PiTalk is a macOS menu bar voice companion for Pi. It reads Pi telemetry for live status and uses a local pi-talk extension to route <voice> output into the PiTalk speech queue.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Required Pi Extensions")
                        .font(.headline)
                    Text("Install these in Pi for full functionality:")
                        .font(.callout)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        CodeRow(code: "pi install npm:pi-telemetry", description: "Telemetry data source")
                        CodeRow(code: "/pi-telemetry --data", description: "Enable telemetry in active Pi session")
                        CodeRow(code: "pi install npm:@swairshah/pi-talk", description: "PiTalk voice routing extension")
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("Credits")
                        .font(.headline)
                    Text("PiTalk’s status/jump UX is heavily inspired by Pi Status Bar.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Link("github.com/jademind/pi-statusbar", destination: URL(string: "https://github.com/jademind/pi-statusbar")!)
                        .font(.caption)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("Project Repository")
                        .font(.headline)
                    Text("PiTalk is maintained at the repository below. You can open issues, request features, and report bugs there.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Link("github.com/swairshah/PiTalk", destination: URL(string: "https://github.com/swairshah/PiTalk")!)
                        .font(.caption)
                    Link("github.com/swairshah/PiTalk/issues", destination: URL(string: "https://github.com/swairshah/PiTalk/issues")!)
                        .font(.caption)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                )

                Spacer(minLength: 8)
            }
            .padding()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}


struct CodeRow: View {
    let code: String
    var description: String? = nil

    var body: some View {
        HStack {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)

            if let desc = description {
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard")
        }
    }
}

struct KeyboardShortcutView: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .shadow(color: .black.opacity(0.1), radius: 0.5, y: 0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.headline)
            }

            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}

struct VoiceButton: View {
    let name: String
    let isSelected: Bool
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
                Text(name.capitalized)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 1.5 : 1)
            )
            .foregroundColor(isSelected ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - HTTP Health Server

/// Simple HTTP server that responds to /health endpoint
/// Required by pi-tts extension which checks http://127.0.0.1:18080/health
final class HealthHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "pitalk.health.server")
    
    init(port: Int) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(
                domain: "PiTalk",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid health server port: \(port)"]
            )
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        self.listener = try NWListener(using: params, on: nwPort)
    }
    
    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                debugLog("PiTalk: Health HTTP server ready")
            case .failed(let error):
                print("PiTalk: Health HTTP server failed: \(error)")
            default:
                break
            }
        }
        
        listener.start(queue: queue)
    }
    
    func stop() {
        listener.cancel()
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        
        // Read HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard error == nil, let data = data else {
                connection.cancel()
                return
            }
            
            self?.handleRequest(data, on: connection)
        }
    }
    
    private func handleRequest(_ data: Data, on connection: NWConnection) {
        guard let request = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }
        
        // Parse HTTP request line
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        
        let parts = requestLine.components(separatedBy: " ")
        let path = parts.count > 1 ? parts[1] : "/"
        
        let response: String
        if path == "/health" || path == "/" {
            // Health check - return 200 OK with JSON
            let body = "{\"ok\":true,\"service\":\"PiTalk\"}"
            response = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r
            \(body)
            """
        } else {
            // 404 for other paths
            let body = "Not Found"
            response = """
            HTTP/1.1 404 Not Found\r
            Content-Type: text/plain\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r
            \(body)
            """
        }
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
