import SwiftUI

// MARK: - Glass Effect Modifiers
// iOS 26+: native glass. Fallback: system materials (always correct in light/dark).

struct GlassRectModifier: ViewModifier {
    let cornerRadius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        }
    }
}

struct GlassCapsuleModifier: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint), in: .capsule)
            } else {
                content.glassEffect(.regular, in: .capsule)
            }
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        }
    }
}

struct GlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .circle)
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - Gradient Background

struct GradientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [PT.gradientTop, PT.gradientMid, PT.gradientBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ) 
        .ignoresSafeArea()
    }
}

// MARK: - Scroll Fade Mask

struct ScrollFadeMask: View {
    var topHeight: CGFloat = 24
    var bottomHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                .frame(height: topHeight)
            Color.white
            LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: bottomHeight)
        }
    }
}

// MARK: - Scroll Near-Bottom Detector

struct ScrollNearBottomDetector: ViewModifier {
    @Binding var isNearBottom: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geo in
                    let dist = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                    return dist <= 60
                } action: { _, newValue in
                    if newValue != isNearBottom {
                        withAnimation(.easeOut(duration: 0.2)) { isNearBottom = newValue }
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - Status Accent Bar

struct StatusAccentBar: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color.opacity(0.9))
            .frame(width: 3)
            .padding(.vertical, 6)
    }
}
