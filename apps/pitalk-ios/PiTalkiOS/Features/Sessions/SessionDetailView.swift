import PhotosUI
import SwiftUI
import UIKit

/// A unified timeline item that merges TTS history and user-sent messages.
private enum TimelineItem: Identifiable {
    case history(RemoteHistoryEntry)
    case sent(SentMessage)

    var id: String {
        switch self {
        case .history(let e): return "h-\(e.id)"
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

    private var session: RemoteSession? {
        store.socket.snapshot.sessions.first(where: { $0.id == sessionId })
    }

    /// History entries for this session in chronological order.
    private var history: [RemoteHistoryEntry] {
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

    /// Merged timeline: history + sent messages, sorted chronologically.
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

    var body: some View {
        VStack(spacing: 0) {
            if let session {
                header(for: session)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            } else {
                Text("Session not found")
                    .foregroundStyle(.secondary)
                    .padding()
            }

            if timeline.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.bubble")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("No speech history yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(timeline) { item in
                                switch item {
                                case .history(let entry):
                                    historyRow(entry)
                                case .sent(let msg):
                                    sentRow(msg)
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
                    .mask(scrollFadeMask)
                    .onAppear {
                        proxy.scrollTo("historyBottom", anchor: .bottom)
                    }
                    .onChange(of: latestItemId) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("historyBottom", anchor: .bottom)
                        }
                    }
                }
            }

            composeBar
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .padding(.top, 4)
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Scroll fade mask

    /// Subtle gradient mask so content fades at top and bottom edges.
    /// Uses opacity stops (works in both light and dark mode).
    private var scrollFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .frame(height: 16)
            Color.white
            LinearGradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .frame(height: 16)
        }
    }

    // MARK: - Header

    private func header(for session: RemoteSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(session.sourceApp)
                    .font(.headline)
                if let mux = session.mux, !mux.isEmpty {
                    Text(mux)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                Text(session.activityLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(activityColor(session.activity))
            }
            Text(session.sessionId ?? session.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let currentText = session.currentText {
                Text(currentText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Timeline rows

    /// TTS history entry (response from the system).
    private func historyRow(_ entry: RemoteHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.text)
                .font(.subheadline)
            HStack {
                Text(entry.status.capitalized)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor(entry.status))
                Spacer()
                Text(relativeDate(entry.timestampMs))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    /// User-sent message (you → session).
    private func sentRow(_ msg: SentMessage) -> some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                Text(msg.text)
                    .font(.subheadline)
                Text(relativeDate(msg.timestampMs))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
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
            if hasPendingScreenshot {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.caption)
                    Text("Screenshot ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        pendingScreenshotData = nil
                        selectedScreenshotItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            TextField("Message…", text: $store.draftText, axis: .vertical)
                .font(.subheadline)
                .lineLimit(2...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 8) {
                Button {
                    Task {
                        await sendComposePayload()
                    }
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .foregroundStyle(hasOutgoingContent ? .white : .secondary)
                .background(hasOutgoingContent ? Color.blue : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: hasOutgoingContent ? 0 : 1))
                .disabled(!hasOutgoingContent)
                .buttonStyle(.plain)

                PhotosPicker(selection: $selectedScreenshotItem, matching: .images, photoLibrary: .shared()) {
                    Label("Photo", systemImage: "photo")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .foregroundStyle(.primary)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                .buttonStyle(.plain)

                Spacer()

                PushToTalkButton(
                    isRecording: ptt.isRecording,
                    onPress: { ptt.startRecording() },
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

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "played": return .green
        case "playing": return .blue
        case "failed": return .red
        case "cancelled", "interrupted": return .orange
        default: return .secondary
        }
    }

    private func activityColor(_ activity: String) -> Color {
        switch activity {
        case "speaking", "running": return .red
        case "queued": return .orange
        case "waiting": return .green
        default: return .secondary
        }
    }

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
        .background(
            isRecording ? AnyShapeStyle(Color.red.opacity(0.15)) : AnyShapeStyle(.ultraThinMaterial),
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(isRecording ? Color.red.opacity(0.4) : Color.clear, lineWidth: 1)
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
