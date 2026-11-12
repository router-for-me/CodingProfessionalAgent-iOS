import SwiftUI
import UIKit

// Light colors sampled from the design screenshots (Display P3), with adaptive dark surfaces.
enum Theme {
    static let accent = Color(.displayP3, red: 0.933, green: 0.525, blue: 0.427)
    static let online = Color(.displayP3, red: 0.353, green: 0.745, blue: 0.510)
    static let userBubble = adaptive(
        light: UIColor(displayP3Red: 0.988, green: 0.945, blue: 0.933, alpha: 1),
        dark: UIColor(displayP3Red: 0.235, green: 0.165, blue: 0.145, alpha: 1)
    )
    static let userBubbleText = adaptive(
        light: UIColor(displayP3Red: 0.776, green: 0.220, blue: 0.157, alpha: 1),
        dark: UIColor(displayP3Red: 0.961, green: 0.686, blue: 0.608, alpha: 1)
    )
    static let chipBackground = adaptive(
        light: UIColor(white: 0.96, alpha: 1),
        dark: .secondarySystemBackground
    )
    static let groupedRow = Color.black.opacity(0.06)
    // Skill chip color of the desktop Web composer (`--accent-blue`, #6ea8fe).
    static let skillChip = Color(red: 110 / 255, green: 168 / 255, blue: 254 / 255)

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            let color = traits.userInterfaceStyle == .dark ? dark : light
            return color.resolvedColor(with: traits)
        })
    }
}
