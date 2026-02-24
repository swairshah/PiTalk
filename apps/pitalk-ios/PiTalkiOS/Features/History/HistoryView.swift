import SwiftUI

struct HistoryListView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            Group {
                if store.socket.snapshot.history.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No history yet")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.socket.snapshot.history) { entry in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(entry.text)
                                        .lineLimit(3)

                                    HStack {
                                        Text(entry.status.capitalized)
                                            .font(.caption)
                                            .foregroundStyle(statusColor(entry.status))

                                        Spacer()

                                        Text(timestampString(entry.timestampMs))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "played": return .green
        case "playing": return .blue
        case "failed": return .red
        case "cancelled", "interrupted": return .orange
        default: return .secondary
        }
    }

    private func timestampString(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
