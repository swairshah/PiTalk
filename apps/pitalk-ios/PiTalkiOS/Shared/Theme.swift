import SwiftUI
import UIKit

// MARK: - PiTalk Color Palette
// Warm palette inspired by the PiTalk icon — browns, terra cotta, gold.
// Muted and cozy, not loud. Takes structural cues from Litter.

enum PT {
    // MARK: Adaptive helpers

    static func adaptive(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    // MARK: Backgrounds
    // Light: warm cream/ivory. Dark: warm charcoal-brown (not cold slate).

    static let bg           = adaptive(light: "#F9F6F1", dark: "#1C1816")
    static let bgSecondary  = adaptive(light: "#F2EDE5", dark: "#242019")
    static let surface      = adaptive(light: "#FFFFFF", dark: "#2C2620")
    static let surfaceLight = adaptive(light: "#F6F1EA", dark: "#362E27")

    // MARK: Text

    static let textPrimary   = adaptive(light: "#3C2A1E", dark: "#E8DED4")
    static let textSecondary = adaptive(light: "#7A6255", dark: "#B5A69A")
    static let textMuted     = adaptive(light: "#A89585", dark: "#7A6E65")
    static let textOnAccent  = adaptive(light: "#FFFFFF", dark: "#1C1816")

    // MARK: Accents — drawn from the icon

    static let accent     = adaptive(light: "#A5492E", dark: "#D4784A")  // terra cotta
    static let accentTint = adaptive(light: "#A5492E", dark: "#D4784A").opacity(0.12)

    static let green   = adaptive(light: "#5B7D3E", dark: "#8BAA6A")  // warm olive green
    static let red     = adaptive(light: "#B03A2E", dark: "#D4645A")  // warm brick red
    static let orange  = adaptive(light: "#C07A1A", dark: "#D9A33D")  // icon gold/amber
    static let cyan    = adaptive(light: "#4A7B7B", dark: "#6AABAB")  // warm teal
    static let yellow  = adaptive(light: "#9A7B20", dark: "#D4B85C")  // warm gold

    // MARK: Semantic

    static let success = green
    static let danger  = red
    static let warning = orange

    // MARK: Borders / Separators

    static let border    = adaptive(light: "#E2DAD0", dark: "#3D342C")
    static let separator = adaptive(light: "#EBE4DA", dark: "#322A23")

    // MARK: Gradient

    static let gradientTop    = adaptive(light: "#FAF7F2", dark: "#1A1614")
    static let gradientMid    = adaptive(light: "#F7F3EC", dark: "#1C1816")
    static let gradientBottom = adaptive(light: "#F5F0E8", dark: "#1E1A17")
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
