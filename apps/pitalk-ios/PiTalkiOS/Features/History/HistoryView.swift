import SwiftUI

private struct CoalescedHistoryEntry: Identifiable {
    let id: String
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
    let status: String
    let timestampMs: Int64
    private let texts: [String]

    init(entry: RemoteHistoryEntry) {
        id = entry.id
        sourceApp = entry.sourceApp
        sessionId = entry.sessionId
        pid = entry.pid
        status = entry.status
        timestampMs = entry.timestampMs
        texts = [entry.text]
    }

    private init(
        id: String,
        sourceApp: String?,
        sessionId: String?,
        pid: Int?,
        status: String,
        timestampMs: Int64,
        texts: [String]
    ) {
        self.id = id
        self.sourceApp = sourceApp
        self.sessionId = sessionId
        self.pid = pid
        self.status = status
        self.timestampMs = timestampMs
        self.texts = texts
    }

    var chunkCount: Int { texts.count }

    var displayText: String {
        texts
            .reversed() // history list is newest first; render coalesced text oldest -> newest
            .joined(separator: " ")
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

        // Group adjacent chunks that arrive close together.
        return abs(timestampMs - entry.timestampMs) <= 15_000
    }

    func appending(_ entry: RemoteHistoryEntry) -> CoalescedHistoryEntry {
        CoalescedHistoryEntry(
            id: id,
            sourceApp: sourceApp,
            sessionId: sessionId,
            pid: pid,
            status: status,
            timestampMs: timestampMs,
            texts: texts + [entry.text]
        )
    }
}

struct HistoryListView: View {
    @EnvironmentObject private var store: AppStore

    private var history: [CoalescedHistoryEntry] {
        var grouped: [CoalescedHistoryEntry] = []

        for entry in store.socket.snapshot.history {
            if let last = grouped.last, last.canMerge(with: entry) {
                grouped[grouped.count - 1] = last.appending(entry)
            } else {
                grouped.append(CoalescedHistoryEntry(entry: entry))
            }
        }

        return grouped
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                Group {
                    if history.isEmpty {
                        EmptyStateView(
                            icon: "clock.arrow.circlepath",
                            title: "No history yet"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(history) { entry in
                                    historyCard(entry)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 8)
                        }
                        .mask(ScrollFadeMask(topHeight: 12, bottomHeight: 12))
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func historyCard(_ entry: CoalescedHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.displayText)
                .font(.subheadline)
                .lineLimit(4)
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

                Text(timestampString(entry.timestampMs))
                    .font(.caption2)
                    .foregroundStyle(PT.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .modifier(GlassRectModifier(cornerRadius: 14))
        .overlay(alignment: .leading) {
            StatusAccentBar(color: statusColor(entry.status))
        }
    }

    private func timestampString(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
