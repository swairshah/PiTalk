import SwiftUI
import AppKit

struct StatusBarContentView: View {
    @ObservedObject var monitor: VoiceMonitor
    @StateObject private var audioRecorder = AudioRecorder()
    @State private var recordingForSession: VoiceSession? = nil
    
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
    
    private func pill(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.gray.opacity(0.12))
            )
    }
    
    private func sessionPrimaryLine(_ session: VoiceSession) -> String {
        let sessionLabel = session.sessionId.map { shortSessionLabel($0) } ?? nil
        
        if let label = sessionLabel {
            return "\(session.sourceApp) [\(label)] · \(session.activity.label)"
        }
        return "\(session.sourceApp) · \(session.activity.label)"
    }
    
    private func shortSessionLabel(_ sessionId: String) -> String {
        let suffix = sessionId.count > 12 ? "…" : ""
        return String(sessionId.prefix(12)) + suffix
    }
    
    private func trimmedText(_ text: String, maxLength: Int = 60) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)) + "…"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 8) {
                Circle()
                    .fill(monitor.summary.uiColor)
                    .frame(width: 10, height: 10)
                Text(monitor.summary.label)
                    .font(.headline)
                
                Spacer()
                
                // Speed slider + Mute toggle
                HStack(spacing: 6) {
                    // Speed slider
                    HStack(spacing: 2) {
                        Image(systemName: "hare")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Slider(value: $monitor.speechSpeed, in: 0.7...2.0, step: 0.05)
                            .frame(width: 50)
                            .controlSize(.mini)
                        Text(String(format: "%.1fx", monitor.speechSpeed))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                    }
                    .help("Speech speed: \(String(format: "%.2f", monitor.speechSpeed))x (0.7-2.0)")
                    
                    Divider()
                        .frame(height: 12)
                    
                    // Server on/off toggle
                    HStack(spacing: 3) {
                        Image(systemName: monitor.serverEnabled ? "speaker.wave.2" : "speaker.slash")
                            .font(.system(size: 10))
                            .foregroundStyle(monitor.serverEnabled ? .primary : .secondary)
                        Toggle("", isOn: Binding(
                            get: { monitor.serverEnabled },
                            set: { newValue in
                                monitor.serverEnabled = newValue
                                monitor.handleServerToggle(enabled: newValue)
                            }
                        ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }
                    .help(monitor.serverEnabled ? "Voice server is running" : "Voice server is stopped")
                }
            }
            
            // Status pills
            HStack(spacing: 6) {
                pill("sessions: \(monitor.sessions.count)")
                if monitor.speakingCount > 0 {
                    pill("speaking: \(monitor.speakingCount)", color: .red)
                }
                if monitor.totalQueuedItems > 0 {
                    pill("queued: \(monitor.totalQueuedItems)", color: .orange)
                }
            }
            
            Divider()
            
            // Sessions list (show max 8 in menu bar)
            if monitor.sessions.isEmpty {
                Text("No active voice sessions")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                let maxVisible = 8
                let visibleSessions = Array(monitor.sessions.prefix(maxVisible))
                let hiddenCount = monitor.sessions.count - visibleSessions.count
                
                ForEach(visibleSessions) { session in
                    sessionRow(session)
                }
                
                if hiddenCount > 0 {
                    Button(action: { openSettings() }) {
                        HStack {
                            Image(systemName: "ellipsis.circle")
                            Text("\(hiddenCount) more session\(hiddenCount == 1 ? "" : "s")...")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Recent history section (collapsed, show only 3)
            if !monitor.recentHistory.isEmpty {
                Divider()
                
                DisclosureGroup {
                    ForEach(monitor.recentHistory.prefix(3)) { entry in
                        historyRow(entry)
                    }
                } label: {
                    Text("Recent (\(monitor.recentHistory.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                
                HStack(spacing: 8) {
                    Button("Stop All") {
                        monitor.stopAll()
                    }
                    .buttonStyle(MenuBarButtonStyle())
                    .disabled(monitor.speakingCount == 0 && monitor.totalQueuedItems == 0)
                    
                    Button("Window") {
                        openSettings()
                    }
                    .buttonStyle(MenuBarButtonStyle())
                    
                    Button("Quit") {
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(MenuBarButtonStyle())
                }
            }
            
            if let msg = monitor.lastMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
    
    @ViewBuilder
    private func sessionRow(_ session: VoiceSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(session.activity.color)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            
            VStack(alignment: .leading, spacing: 2) {
                // Primary line: app [session] · activity
                Text(sessionPrimaryLine(session))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                
                // Last spoken text (if any)
                if let text = session.currentText ?? session.lastSpokenText {
                    Text("💬 " + trimmedText(text, maxLength: 45))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                // Metadata line: PID · voice · queued · last time
                HStack(spacing: 6) {
                    if let pid = session.pid {
                        Text("PID \(pid)")
                            .font(.system(.caption2, design: .monospaced))
                    }
                    
                    if let voice = session.voice {
                        HStack(spacing: 2) {
                            Image(systemName: "waveform")
                            Text(voice)
                        }
                        .font(.caption2)
                    }
                    
                    if session.queuedCount > 0 {
                        Text("\(session.queuedCount) queued")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    
                    if (session.activity == .idle || session.activity == .waiting), let lastAt = session.lastSpokenAt {
                        Text("· \(Self.relativeDateFormatter.localizedString(for: lastAt, relativeTo: Date()))")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if let pid = session.pid {
                VStack(spacing: 4) {
                    Button("Jump") {
                        monitor.jump(to: session)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(0.15))
                    )
                    .foregroundStyle(.blue)
                    .buttonStyle(.plain)
                    
                    // Push-to-talk mic button
                    MicButton(
                        isRecording: audioRecorder.isRecording && recordingForSession?.id == session.id,
                        onPress: {
                            recordingForSession = session
                            audioRecorder.startRecording()
                        },
                        onRelease: {
                            let targetSession = session
                            if let audioData = audioRecorder.stopRecording() {
                                print("PiTalk: Got \(audioData.count) bytes of audio, transcribing...")
                                
                                SpeechToText.transcribe(audioData: audioData) { result in
                                    if result.success, let text = result.text, !text.isEmpty {
                                        print("PiTalk: Transcribed: \(text)")
                                        monitor.sendText(to: targetSession, text: text)
                                    } else {
                                        print("PiTalk: Transcription failed: \(result.error ?? "unknown")")
                                    }
                                }
                            }
                            recordingForSession = nil
                        }
                    )
                }
            }
        }
        .padding(.vertical, 3)
    }
    
    @ViewBuilder
    private func historyRow(_ entry: RequestHistoryEntry) -> some View {
        HStack {
            statusBadge(for: entry.status)
            
            Text(trimmedText(entry.text, maxLength: 40))
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            Spacer()
            
            Text(Self.relativeDateFormatter.localizedString(for: entry.timestamp, relativeTo: Date()))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
    
    @ViewBuilder
    private func statusBadge(for status: RequestPlaybackStatus) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(status.tintColor)
                .frame(width: 6, height: 6)
        }
    }
    
    private func openSettings() {
        AppDelegate.shared?.openSettings()
    }
}

// MARK: - Status Bar Icon

struct StatusBarIcon: View {
    let summary: VoiceSummary
    let serverOnline: Bool
    let serverEnabled: Bool
    
    var body: some View {
        Image(nsImage: menuBarImage)
            .help(!serverEnabled ? "Voice server is stopped" : (serverOnline ? summary.label : "API key not configured"))
    }
    
    private var statusColor: NSColor {
        // White when server is disabled (to indicate "off" state)
        guard serverEnabled else { return .white }
        
        // White when API key/server is offline
        guard serverOnline else { return .white }
        
        // Green when any session is waiting for input, otherwise white
        if summary.color == "green" {
            return .systemGreen
        }
        return .white
    }
    
    private var menuBarImage: NSImage {
        // Use "off" icon when server disabled or no API key
        let imageName = (serverOnline && serverEnabled) ? "menubar_on" : "menubar_off"
        
        guard let url = Bundle.module.url(forResource: imageName, withExtension: "png", subdirectory: "Resources"),
              let originalImage = NSImage(contentsOf: url) else {
            // Fallback to a simple SF Symbol if image not found
            return NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) ?? NSImage()
        }
        
        // Create a tinted version of the image
        let tintedImage = tintImage(originalImage, with: statusColor)
        tintedImage.size = NSSize(width: 18, height: 18)
        return tintedImage
    }
    
    private func tintImage(_ image: NSImage, with color: NSColor) -> NSImage {
        let size = image.size
        let tinted = NSImage(size: size)
        
        tinted.lockFocus()
        
        // Draw the original image
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: size),
                   operation: .sourceOver,
                   fraction: 1.0)
        
        // Apply color tint using source-atop to only color non-transparent pixels
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        
        tinted.unlockFocus()
        tinted.isTemplate = false  // Not a template since we're applying custom colors
        
        return tinted
    }
}

// MARK: - Custom Button Style

struct MenuBarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed 
                        ? Color.accentColor.opacity(0.3) 
                        : Color.accentColor.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
            .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
            .opacity(isEnabled ? 1.0 : 0.5)
    }
}

// MARK: - Push-to-Talk Mic Button

struct MicButton: View {
    let isRecording: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Image(systemName: isRecording ? "mic.fill" : "mic")
            .font(.system(size: 14))
            .foregroundStyle(isRecording ? .red : .orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isRecording ? Color.red.opacity(0.2) : Color.orange.opacity(0.15))
            )
            .scaleEffect(isPressed ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        onRelease()
                    }
            )
    }
}
