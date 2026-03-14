import SwiftUI

// MARK: - Typing / Speaking Indicator

struct TypingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(PT.textMuted)
                    .frame(width: 6, height: 6)
                    .offset(y: phase == i ? -4 : 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .modifier(GlassRectModifier(cornerRadius: 12))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                phase = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                    phase = 2
                }
            }
        }
    }
}

// MARK: - Pulsing Dot

struct PulsingDot: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Scroll To Bottom

struct ScrollToBottomButton: View {
    let action: () -> Void
    @State private var bob = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.system(.caption2, weight: .bold))
                    .offset(y: bob ? 1.5 : -1.5)
                Text("Latest")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(PT.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .modifier(GlassCapsuleModifier())
        }
        .contentShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                bob = true
            }
        }
    }
}

// MARK: - Status Chip

struct StatusChip: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Activity / Status Color Helpers

func isWorkActivity(_ activity: String) -> Bool {
    switch activity {
    case "starting", "thinking", "reading", "editing", "running", "searching", "error":
        return true
    default:
        return false
    }
}

func activityColor(_ activity: String) -> Color {
    switch activity {
    case "speaking": return PT.red
    case "starting": return PT.green
    case "thinking": return PT.orange
    case "reading": return PT.accent
    case "editing": return PT.yellow
    case "running": return PT.orange
    case "searching": return PT.orange
    case "error": return PT.red
    case "queued": return PT.orange
    case "waiting": return PT.green
    default: return PT.textMuted
    }
}

func statusColor(_ status: String) -> Color {
    switch status {
    case "played": return PT.green
    case "playing": return PT.accent
    case "failed": return PT.red
    case "cancelled", "interrupted": return PT.orange
    default: return PT.textMuted
    }
}

// MARK: - Audio Waveform

struct AudioWaveformView: View {
    let isRecording: Bool
    @State private var animating = false

    private let barCount = 5
    private let barWidth: CGFloat = 3

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(PT.red.opacity(0.8))
                    .frame(width: barWidth, height: barHeight(for: i))
                    .animation(
                        .easeInOut(duration: Double.random(in: 0.3...0.6))
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.08),
                        value: animating
                    )
            }
        }
        .frame(height: 20)
        .onAppear { if isRecording { animating = true } }
        .onChange(of: isRecording) { _, rec in animating = rec }
    }

    private func barHeight(for index: Int) -> CGFloat {
        if !animating { return 4 }
        let heights: [CGFloat] = [14, 20, 10, 18, 12]
        return heights[index % heights.count]
    }
}

// MARK: - Metric Pill

struct MetricPill: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(tint)
            Text("\(value)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(PT.textMuted)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(PT.textSecondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(PT.textMuted)
            }
        }
        .padding(.top, 40)
    }
}
