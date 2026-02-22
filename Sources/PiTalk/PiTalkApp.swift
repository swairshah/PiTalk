import SwiftUI
import AppKit
import ServiceManagement
import Carbon.HIToolbox
import Network
import Darwin
import CoreAudio

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
    
    // Dock icon visibility (defaults to false for menubar app)
    var showDockIcon: Bool {
        get { 
            if UserDefaults.standard.object(forKey: "showDockIcon") == nil {
                return false
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
        
        // Menu bar is now handled by SwiftUI MenuBarExtra
        setupGlobalShortcut()
        updateDockIconVisibility()

        speechCoordinator = SpeechPlaybackCoordinator(
            defaultVoiceProvider: { [weak self] in self?.selectedVoice ?? "ally" }
        )
        
        // Restore server enabled state from preferences
        speechCoordinator?.isMuted = !serverEnabled

        micMonitor = MicrophoneActivityMonitor { [weak self] isActive in
            self?.speechCoordinator?.setMicrophoneActive(isActive)
        }
        micMonitor?.start()

        // Only start broker if server is enabled
        if serverEnabled {
            startLocalBroker()
        } else {
            print("PiTalk: Server disabled, broker not started")
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
        print("PiTalk: startLocalBroker called, coordinator=\(speechCoordinator != nil), localBroker=\(localBroker != nil)")
        guard let coordinator = speechCoordinator else {
            print("PiTalk: No coordinator, cannot start broker")
            return
        }
        
        // Don't start if already running
        if localBroker != nil {
            print("PiTalk: Broker already running, skipping start")
            return
        }
        
        do {
            let broker = try LocalSpeechBroker(port: brokerPort, coordinator: coordinator)
            broker.start()
            localBroker = broker
            print("PiTalk: Local broker listening on 127.0.0.1:\(brokerPort)")
            
            // Also start HTTP health server on 18080 (pi-tts extension expects this)
            if healthServer == nil {
                let server = HealthHTTPServer(port: 18080)
                server.start()
                healthServer = server
                print("PiTalk: Health server listening on 127.0.0.1:18080")
            }
        } catch {
            print("PiTalk: Failed to start local broker: \(error)")
        }
    }
    
    func stopLocalBroker() {
        print("PiTalk: stopLocalBroker called, localBroker=\(localBroker != nil)")
        localBroker?.stop()
        localBroker = nil
        healthServer?.stop()
        healthServer = nil
        print("PiTalk: Broker and health server stopped")
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
            window.setContentSize(NSSize(width: 520, height: 480))
            window.minSize = NSSize(width: 420, height: 380)
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

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let loquiDir = appSupport.appendingPathComponent("PiTalk", isDirectory: true)
        historyFileURL = loquiDir.appendingPathComponent("request-history.json")
        _ = syncOnMain { () -> Bool in
            loadFromDisk()
            return true
        }
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

        _ = syncOnMain { () -> Bool in
            entries.insert(entry, at: 0)
            if entries.count > maxEntries {
                entries.removeLast(entries.count - maxEntries)
            }
            persist()
            return true
        }

        return entry.id
    }

    func updateStatus(
        id: UUID,
        to newStatus: RequestPlaybackStatus,
        unlessCurrentIn blockedStatuses: Set<RequestPlaybackStatus> = []
    ) {
        _ = syncOnMain { () -> Bool in
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                return false
            }

            let current = entries[index].status
            if blockedStatuses.contains(current) {
                return false
            }

            if current != newStatus {
                entries[index].status = newStatus
                persist()
            }
            return true
        }
    }

    func clear() {
        _ = syncOnMain { () -> Bool in
            entries.removeAll()
            persist()
            return true
        }
    }

    private func syncOnMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }

        return DispatchQueue.main.sync(execute: work)
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: historyFileURL)
            let decoded = try JSONDecoder().decode([RequestHistoryEntry].self, from: data)
            
            // Clean up stale "playing" and "queued" entries (from crashes or bugs)
            let staleCutoff = Date().addingTimeInterval(-120)  // 2 minutes
            let cleaned = decoded.prefix(maxEntries).map { entry -> RequestHistoryEntry in
                if (entry.status == .playing || entry.status == .queued) && entry.timestamp < staleCutoff {
                    var fixed = entry
                    fixed.status = entry.status == .playing ? .interrupted : .cancelled
                    return fixed
                }
                return entry
            }
            entries = Array(cleaned)
        } catch {
            print("PiTalk: Failed to load request history: \(error)")
        }
    }

    private func persist() {
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
    // Using ElevenLabs voices
    private let autoVoicePool = ["ally", "dorothy", "lily", "alice", "dave", "joseph"]
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
        print("PiTalk: stopAll() called")
        let state = queue.sync { () -> (pending: [UUID], active: UUID?) in
            let pendingIds = allPendingHistoryIdsLocked()
            let activeId = currentJobHistoryId
            
            print("PiTalk: stopAll - pending=\(pendingIds.count), hasActive=\(activeId != nil), currentProcess=\(currentProcess != nil)")

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
        
        if ProcessInfo.processInfo.environment["PITALK_DEBUG"] == "1" {
            let hasProcess = currentProcess != nil
            let isRunning = currentProcess?.isRunning == true
            print("PiTalk: Coordinator mic state: \(active ? "ACTIVE" : "INACTIVE"), hasProcess=\(hasProcess), isRunning=\(isRunning)")
        }

        if active {
            let activelyPlaying = currentProcess?.isRunning == true

            // Requirement: if mic starts while voice is already playing, cancel all queued work at that moment.
            guard activelyPlaying else { return }

            let pendingIds = allPendingHistoryIdsLocked()
            let activeId = currentJobHistoryId

            queuesByKey.removeAll()
            queueOrder.removeAll()
            // Keep voice assignments so this queue key keeps the same voice after interruption.
            terminateCurrentProcessLocked()
            currentJobHistoryId = nil
            currentQueueKey = nil
            currentRunNonce = nil
            isPlaying = false

            for id in pendingIds {
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
    
    private func synthesize(job: SpeechJob) async throws -> Data {
        // Get API key from environment or UserDefaults
        guard let apiKey = ProcessInfo.processInfo.environment["ELEVEN_API_KEY"]
            ?? ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]
            ?? UserDefaults.standard.string(forKey: "elevenLabsApiKey"),
              !apiKey.isEmpty else {
            throw NSError(domain: "PiTalk", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "ElevenLabs API key not found. Set ELEVEN_API_KEY environment variable or configure in settings."
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
    
    /// Streaming TTS - uses fast model and streaming API for lower latency
    private func synthesizeAndPlayStreaming(job: SpeechJob, runNonce: UUID) async throws {
        // Get API key
        guard let apiKey = ProcessInfo.processInfo.environment["ELEVEN_API_KEY"]
            ?? ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]
            ?? UserDefaults.standard.string(forKey: "elevenLabsApiKey"),
              !apiKey.isEmpty else {
            throw NSError(domain: "PiTalk", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "ElevenLabs API key not found."
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
            print("PiTalk: terminateCurrentProcessLocked - no current process")
            return
        }

        print("PiTalk: terminateCurrentProcessLocked - process PID=\(process.processIdentifier), isRunning=\(process.isRunning)")
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                if process.isRunning {
                    print("PiTalk: Force killing process PID=\(pid)")
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
            let key = queueOrder.removeFirst()

            guard var jobs = queuesByKey[key], !jobs.isEmpty else {
                queuesByKey.removeValue(forKey: key)
                continue
            }

            let job = jobs.removeFirst()

            if jobs.isEmpty {
                queuesByKey.removeValue(forKey: key)
            } else {
                queuesByKey[key] = jobs
                queueOrder.append(key)
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
        print("PiTalk: LocalSpeechBroker.stop() - cancelling listener")
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
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Text("General")
                }

            HistoryView()
                .tabItem {
                    Text("History")
                }

            HelpView()
                .tabItem {
                    Text("Help")
                }

            AboutView()
                .tabItem {
                    Text("About")
                }
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("ttsVoice") var voice = "ally"
    @AppStorage("elevenLabsApiKey") var apiKey = ""
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("showDockIcon") var showDockIcon = false
    @State private var isPreviewPlaying = false
    @State private var showApiKey = false
    
    // ElevenLabs voices - British & Scottish only
    let availableVoices = [
        "ally", "dorothy", "lily", "alice", "dave", "joseph"
    ]
    
    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    Text("PiTalk")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Voice for Pi")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
            }

            Section("ElevenLabs API") {
                HStack {
                    if showApiKey {
                        TextField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(showApiKey ? "Hide" : "Show") {
                        showApiKey.toggle()
                    }
                    .buttonStyle(.borderless)
                }
                
                if apiKey.isEmpty {
                    Text("Get your API key from elevenlabs.io")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else {
                    Text("API key configured ✓")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                
                Text("Or set ELEVEN_API_KEY environment variable")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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
                    .disabled(isPreviewPlaying || apiKey.isEmpty)
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
    
    func updateDockIcon() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.updateDockIconVisibility()
        }
    }
    
    func previewVoice(_ voiceName: String) {
        guard !isPreviewPlaying else { return }
        isPreviewPlaying = true
        
        let text = "Hi, this is \(voiceName.capitalized). I'm ready to help you with your coding projects."
        
        Task {
            do {
                // ElevenLabs voice ID mapping - British & Scottish only
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
                    throw NSError(domain: "PiTalk", code: 500, userInfo: [NSLocalizedDescriptionKey: "API error"])
                }
                
                // Write MP3 to temp file and play
                let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("voice_preview.mp3")
                try data.write(to: tempFile)
                
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

    private static let allAppsToken = "__all_apps__"
    private static let allSessionsToken = "__all_sessions__"
    private static let noSessionToken = "__no_session__"

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private var availableApps: [String] {
        let apps = Set(historyStore.entries.map { normalizedAppName($0.sourceApp) })
        return apps.sorted()
    }

    private var availableSessions: [String] {
        let sessions = Set(historyStore.entries.compactMap { normalizedSessionId($0.sessionId) })
        return sessions.sorted()
    }

    private var appFilterOptions: [String] {
        [Self.allAppsToken] + availableApps
    }

    private var sessionFilterOptions: [String] {
        var options = [Self.allSessionsToken]
        if historyStore.entries.contains(where: { normalizedSessionId($0.sessionId) == nil }) {
            options.append(Self.noSessionToken)
        }
        options.append(contentsOf: availableSessions)
        return options
    }

    private var isFiltering: Bool {
        !searchText.isEmpty || selectedAppFilter != Self.allAppsToken || selectedSessionFilter != Self.allSessionsToken
    }

    private var filteredEntries: [RequestHistoryEntry] {
        historyStore.entries.filter { entry in
            if !searchText.isEmpty {
                let searchLower = searchText.lowercased()
                let textMatches = entry.text.lowercased().contains(searchLower)
                let appMatches = normalizedAppName(entry.sourceApp).lowercased().contains(searchLower)
                let sessionMatches = (entry.sessionId?.lowercased().contains(searchLower) ?? false)
                if !textMatches && !appMatches && !sessionMatches {
                    return false
                }
            }

            if selectedAppFilter != Self.allAppsToken,
               normalizedAppName(entry.sourceApp) != selectedAppFilter {
                return false
            }

            if selectedSessionFilter == Self.noSessionToken {
                return normalizedSessionId(entry.sessionId) == nil
            }

            if selectedSessionFilter != Self.allSessionsToken,
               normalizedSessionId(entry.sessionId) != selectedSessionFilter {
                return false
            }

            return true
        }
    }

    private var queueEntries: [RequestHistoryEntry] {
        filteredEntries
            .filter { $0.status.isInQueue }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var completedEntries: [RequestHistoryEntry] {
        filteredEntries.filter { !$0.status.isInQueue }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("History")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("\(queueEntries.count) queued · \(completedEntries.count) completed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isFiltering {
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
                    .disabled(historyStore.entries.isEmpty)
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
                        ForEach(appFilterOptions, id: \.self) { option in
                            Text(appFilterLabel(option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Picker("Session", selection: $selectedSessionFilter) {
                        ForEach(sessionFilterOptions, id: \.self) { option in
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

            if historyStore.entries.isEmpty {
                emptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "No requests yet",
                    subtitle: "Speech requests will appear here"
                )
            } else if filteredEntries.isEmpty {
                emptyState(
                    icon: "magnifyingglass",
                    title: "No matches",
                    subtitle: "Try adjusting your search or filters"
                )
            } else {
                List {
                    if !queueEntries.isEmpty {
                        Section {
                            ForEach(queueEntries) { entry in
                                entryRow(entry)
                            }
                        } header: {
                            Label("Queue", systemImage: "play.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Section {
                        ForEach(completedEntries) { entry in
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
        .onChange(of: appFilterOptions) { options in
            if selectedAppFilter != Self.allAppsToken && !options.contains(selectedAppFilter) {
                selectedAppFilter = Self.allAppsToken
            }
        }
        .onChange(of: sessionFilterOptions) { options in
            if selectedSessionFilter != Self.allSessionsToken && !options.contains(selectedSessionFilter) {
                selectedSessionFilter = Self.allSessionsToken
            }
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
                        Text("Direct synthesis endpoint:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        CodeRow(code: "POST http://127.0.0.1:18080/stream", description: "Stream PCM audio")
                        CodeRow(code: "{\"text\":\"Hello\",\"voice\":\"fantine\"}", description: "JSON body")
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("About")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("We package the pocket-tts binary with the app, which runs a local server that lets any applications (including your coding agent - https://pi.dev!) be send text which PiTalk says out loud. We ship a command line utility `ptts` so you can make any application talk via PiTalk and we ship a pi extension so the pi agent gets a voice via PiTalk.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Credits")
                        .font(.headline)
                    Text("PiTalk is built on top of the PocketTTS ecosystem. Huge thanks to the original authors.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Pocket TTS")
                        .font(.headline)
                    Text("The original model by Kyutai Labs. Fast, compact, and high-quality local TTS.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Link("github.com/kyutai-labs/pocket-tts", destination: URL(string: "https://github.com/kyutai-labs/pocket-tts")!)
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
                    Text("pocket-tts (Rust implementation)")
                        .font(.headline)
                    Text("Native Rust implementation by babybirdprd used by PiTalk under the hood.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Link("github.com/babybirdprd/pocket-tts", destination: URL(string: "https://github.com/babybirdprd/pocket-tts")!)
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
    
    init(port: Int) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        
        self.listener = try! NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(port))!)
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
