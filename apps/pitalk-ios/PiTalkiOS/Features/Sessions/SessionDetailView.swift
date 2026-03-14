import PhotosUI
import SwiftUI
import UIKit

/// Coalesced history item to avoid fragmented one-line chunks in the UI.
private struct SessionHistoryGroup: Identifiable {
    let id: String
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
    let status: String
    var timestampMs: Int64
    private var texts: [String]

    init(entry: RemoteHistoryEntry) {
        id = entry.id
        sourceApp = entry.sourceApp
        sessionId = entry.sessionId
        pid = entry.pid
        status = entry.status
        timestampMs = entry.timestampMs
        texts = [entry.text]
    }

    var chunkCount: Int { texts.count }

    var displayText: String {
        texts.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func canMerge(with entry: RemoteHistoryEntry) -> Bool {
        guard sourceApp == entry.sourceApp,
              sessionId == entry.sessionId,
              pid == entry.pid,
              status == entry.status
        else {
            return false
        }

        // Short coalescing window to group streaming chunks from one response.
        return abs(timestampMs - entry.timestampMs) <= 15_000
    }

    mutating func append(_ entry: RemoteHistoryEntry) {
        texts.append(entry.text)
        timestampMs = entry.timestampMs
    }
}

/// A unified timeline item that merges TTS history and user-sent messages.
private enum TimelineItem: Identifiable {
    case history(SessionHistoryGroup)
    case sent(SentMessage)

    var id: String {
        switch self {
        case .history(let e): return "h-\(e.id)-\(e.chunkCount)"
        case .sent(let m): return "s-\(m.id.uuidString)"
        }
    }

    var timestampMs: Int64 {
        switch self {
        case .history(let e): return e.timestampMs
        case .sent(let m): return m.timestampMs
        }
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var store: AppStore
    let sessionId: String

    @StateObject private var ptt = PushToTalkController()
    @State private var selectedScreenshotItem: PhotosPickerItem?
    @State private var pendingScreenshotData: Data?
    @State private var isNearBottom = true

    private var session: RemoteSession? {
        store.socket.snapshot.sessions.first(where: { $0.id == sessionId })
    }

    /// Raw history entries for this session in chronological order.
    private var rawHistory: [RemoteHistoryEntry] {
        store.socket.snapshot.history.filter { entry in
            if let sid = entry.sessionId, let sessionSid = session?.sessionId, sid == sessionSid {
                if let entryPid = entry.pid, let sessPid = session?.pid {
                    return entryPid == sessPid
                }
                return true
            }
            if let entryPid = entry.pid, let sessPid = session?.pid, entryPid == sessPid {
                return true
            }
            return false
        }
        .reversed()
    }

    /// Coalesced history that merges adjacent streaming chunks from one response.
    private var history: [SessionHistoryGroup] {
        var grouped: [SessionHistoryGroup] = []

        for entry in rawHistory {
            if var last = grouped.last, last.canMerge(with: entry) {
                last.append(entry)
                grouped[grouped.count - 1] = last
            } else {
                grouped.append(SessionHistoryGroup(entry: entry))
            }
        }

        return grouped
    }

    /// Merged timeline: coalesced history + sent messages, sorted chronologically.
    private var timeline: [TimelineItem] {
        var items: [TimelineItem] = history.map { .history($0) }
        if let sent = store.sentMessages[sessionId] {
            items.append(contentsOf: sent.map { .sent($0) })
        }
        items.sort { $0.timestampMs < $1.timestampMs }
        return items
    }

    private var latestItemId: String? {
        timeline.last?.id
    }

    /// Whether the session is actively speaking/working.
    private var isSpeaking: Bool {
        guard let activity = session?.activity else { return false }
        return activity == "speaking" || isWorkActivity(activity)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session {
                sessionHeader(for: session)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }

            if timeline.isEmpty {
                EmptyStateView(
                    icon: "text.bubble",
                    title: "No speech history yet"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .bottomTrailing) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(timeline) { item in
                                    switch item {
                                    case .history(let entry):
                                        historyRow(entry)
                                    case .sent(let msg):
                                        sentRow(msg)
                                    }
                                }

                                // Speaking indicator
                                if isSpeaking {
                                    HStack {
                                        TypingIndicator()
                                        Spacer()
                                    }
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id("historyBottom")
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .simultaneousGesture(TapGesture().onEnded {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        })
                        .mask(ScrollFadeMask(topHeight: 20, bottomHeight: 20))
                        .modifier(ScrollNearBottomDetector(isNearBottom: $isNearBottom))
                        .onAppear {
                            proxy.scrollTo("historyBottom", anchor: .bottom)
                        }
                        .onChange(of: latestItemId) { _, _ in
                            if isNearBottom {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("historyBottom", anchor: .bottom)
                                }
                            }
                        }
                    }

                    // Floating scroll-to-bottom button
                    if !isNearBottom && !timeline.isEmpty {
                        ScrollToBottomButton {
                            isNearBottom = true
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }

            composeBar
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .padding(.top, 4)
        }
        .onAppear {
            store.selectedSessionId = sessionId
        }
        .onChange(of: selectedScreenshotItem) { _, item in
            guard let item else { return }
            Task {
                await loadSelectedScreenshot(item)
            }
        }
    }

    // MARK: - Session Header

    private func sessionHeader(for session: RemoteSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isSpeaking {
                    PulsingDot(color: .red)
                }
                Text(session.project ?? session.sourceApp)
                    .font(.headline)
                Spacer()
                StatusChip(
                    label: session.activityLabel,
                    color: activityColor(session.activity)
                )
            }
            if let detail = session.statusDetail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PT.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                if let cwd = session.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.caption2.monospaced())
                        .foregroundStyle(PT.textMuted)
                        .lineLimit(1)
                }
                if let voice = session.voice {
                    StatusChip(label: voice, color: PT.cyan)
                }
            }
            if let currentText = session.currentText {
                Text(currentText)
                    .font(.subheadline)
                    .foregroundStyle(PT.textPrimary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .modifier(GlassRectModifier(cornerRadius: 14))
    }

    // MARK: - Timeline rows

    /// TTS history entry — glass card with status accent bar.
    private func historyRow(_ entry: SessionHistoryGroup) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayText)
                    .font(.subheadline)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    StatusChip(
                        label: entry.status.capitalized,
                        color: statusColor(entry.status)
                    )

                    if entry.chunkCount > 1 {
                        Text("• \(entry.chunkCount) chunks")
                            .font(.caption2)
                            .foregroundStyle(PT.textSecondary)
                    }

                    Spacer()
                    Text(relativeDate(entry.timestampMs))
                        .font(.caption2)
                        .foregroundStyle(PT.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .modifier(GlassRectModifier(cornerRadius: 12))
        .overlay(alignment: .leading) {
            StatusAccentBar(color: statusColor(entry.status))
        }
    }

    /// User-sent message — right-aligned accent-tinted glass bubble.
    private func sentRow(_ msg: SentMessage) -> some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                Text(msg.text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                Text(relativeDate(msg.timestampMs))
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(GlassRectModifier(cornerRadius: 14, tint: PT.accent.opacity(0.3)))
        }
    }

    // MARK: - Compose bar

    private var hasDraft: Bool {
        !store.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasPendingScreenshot: Bool {
        pendingScreenshotData != nil
    }

    private var hasOutgoingContent: Bool {
        hasDraft || hasPendingScreenshot
    }

    private var composeBar: some View {
        VStack(spacing: 8) {
            // Screenshot preview
            if hasPendingScreenshot {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(PT.accent)
                    Text("Screenshot ready")
                        .font(.caption)
                        .foregroundStyle(PT.textSecondary)
                    Spacer()
                    Button {
                        pendingScreenshotData = nil
                        selectedScreenshotItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(PT.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .modifier(GlassRectModifier(cornerRadius: 12))
            }

            // Input field
            HStack(spacing: 8) {
                TextField("Message…", text: $store.draftText, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(.leading, 14)
                    .padding(.vertical, 10)

                if hasDraft {
                    Button {
                        Task { await sendComposePayload() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(PT.accent)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                    .transition(.scale.combined(with: .opacity))
                } else if ptt.isRecording {
                    AudioWaveformView(isRecording: true)
                        .frame(width: 48, height: 20)

                    Button {
                        Task {
                            if let transcript = await ptt.stopAndTranscribe(),
                               !transcript.isEmpty {
                                store.draftText = transcript
                            }
                        }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(PT.red)
                            .frame(width: 36, height: 36)
                    }
                    .padding(.trailing, 4)
                }
            }
            .modifier(GlassRectModifier(cornerRadius: 20))
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: hasDraft)
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: ptt.isRecording)

            // Action buttons row
            HStack(spacing: 8) {
                // Send button (when no inline send arrow visible)
                if !hasDraft {
                    Button {
                        Task { await sendComposePayload() }
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .foregroundStyle(hasOutgoingContent ? .white : .secondary)
                    .background(
                        hasOutgoingContent ? AnyShapeStyle(PT.accent) : AnyShapeStyle(.clear),
                        in: Capsule()
                    )
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: hasOutgoingContent ? 0 : 1))
                    .disabled(!hasOutgoingContent)
                    .buttonStyle(.plain)
                }

                PhotosPicker(selection: $selectedScreenshotItem, matching: .images, photoLibrary: .shared()) {
                    Label("Photo", systemImage: "photo")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .modifier(GlassCapsuleModifier())
                .buttonStyle(.plain)

                Spacer()

                PushToTalkButton(
                    isRecording: ptt.isRecording,
                    onPress: {
                        store.selectedSessionId = sessionId
                        store.interruptForPushToTalk()
                        ptt.startRecording()
                    },
                    onRelease: {
                        Task {
                            if let transcript = await ptt.stopAndTranscribe(), !transcript.isEmpty {
                                store.selectedSessionId = sessionId
                                store.draftText = transcript
                                store.sendDraftToSelectedSession()
                            }
                        }
                    }
                )
            }
        }
    }

    private func loadSelectedScreenshot(_ item: PhotosPickerItem) async {
        defer { selectedScreenshotItem = nil }
        guard let rawData = try? await item.loadTransferable(type: Data.self), !rawData.isEmpty else {
            return
        }

        // Normalize to JPEG so the remote server can persist a single format.
        if let image = UIImage(data: rawData), let converted = image.jpegData(compressionQuality: 0.82) {
            pendingScreenshotData = converted
        } else {
            pendingScreenshotData = rawData
        }
    }

    private func sendComposePayload() async {
        store.selectedSessionId = sessionId

        if hasDraft {
            store.sendDraftToSelectedSession()
        }

        if let pendingScreenshotData {
            await store.sendScreenshotToSelectedSession(imageData: pendingScreenshotData)
            self.pendingScreenshotData = nil
        }
    }

    // MARK: - Helpers

    private func relativeDate(_ timestampMs: Int64) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Push to Talk Button

private struct PushToTalkButton: View {
    let isRecording: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var pressed = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.caption)
            Text(isRecording ? "Recording" : "Hold")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(isRecording ? .red : .primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .modifier(GlassCapsuleModifier(tint: isRecording ? PT.red.opacity(0.2) : nil))
        .overlay(
            Capsule().strokeBorder(isRecording ? PT.red.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .scaleEffect(pressed ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: pressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    onPress()
                }
                .onEnded { _ in
                    pressed = false
                    onRelease()
                }
        )
    }
}
