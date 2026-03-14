import SwiftUI
import UIKit

// MARK: - PiTalk Color Palette
// Muted, Atom One Dark-inspired. Slate backgrounds, soft accents.

enum PT {
    // MARK: Adaptive helpers

    static func adaptive(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    // MARK: Backgrounds
    // Dark: slate gray (not pure black). Light: clean white/off-white.

    static let bg           = adaptive(light: "#F7F7F5", dark: "#21252B")
    static let bgSecondary  = adaptive(light: "#F0F0ED", dark: "#282C34")
    static let surface      = adaptive(light: "#FFFFFF", dark: "#2C313A")
    static let surfaceLight = adaptive(light: "#F5F5F2", dark: "#353B45")

    // MARK: Text

    static let textPrimary   = adaptive(light: "#383A42", dark: "#D4D8DE")
    static let textSecondary = adaptive(light: "#696C77", dark: "#9DA3AD")
    static let textMuted     = adaptive(light: "#9D9D9F", dark: "#6B7280")
    static let textOnAccent  = adaptive(light: "#FFFFFF", dark: "#21252B")

    // MARK: Accents — Litter-inspired, no purple/magenta

    static let accent     = adaptive(light: "#4A4A4A", dark: "#C8CCD2")  // neutral gray
    static let accentTint = adaptive(light: "#4A4A4A", dark: "#C8CCD2").opacity(0.12)

    static let green   = adaptive(light: "#2E7D32", dark: "#6EA676")  // muted forest green
    static let red     = adaptive(light: "#D32F2F", dark: "#FF5555")  // soft red
    static let orange  = adaptive(light: "#E65100", dark: "#E2A644")  // warm amber
    static let cyan    = adaptive(light: "#0184BC", dark: "#56B6C2")  // teal
    static let yellow  = adaptive(light: "#986801", dark: "#E5C07B")  // warm yellow

    // MARK: Semantic

    static let success = green
    static let danger  = red
    static let warning = orange

    // MARK: Borders / Separators

    static let border    = adaptive(light: "#E0E0DC", dark: "#3E4451")
    static let separator = adaptive(light: "#EAEAE6", dark: "#333842")

    // MARK: Gradient — use adaptive colors so SwiftUI resolves them correctly

    static let gradientTop    = adaptive(light: "#F8F8F6", dark: "#1E2228")
    static let gradientMid    = adaptive(light: "#F5F5F3", dark: "#21252B")
    static let gradientBottom = adaptive(light: "#F8F8F7", dark: "#1A1E23")
}

// MARK: - Hex init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255
        let g = CGFloat((int >> 8) & 0xFF) / 255
        let b = CGFloat(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
