import SwiftUI

// Colors sampled from the design screenshots (Display P3).
enum Theme {
    static let accent = Color(.displayP3, red: 0.933, green: 0.525, blue: 0.427)
    static let online = Color(.displayP3, red: 0.353, green: 0.745, blue: 0.510)
    static let userBubble = Color(.displayP3, red: 0.988, green: 0.945, blue: 0.933)
    static let userBubbleText = Color(.displayP3, red: 0.776, green: 0.220, blue: 0.157)
    static let chipBackground = Color(white: 0.96)
    static let groupedRow = Color.black.opacity(0.06)
    // Skill chip color of the desktop Web composer (`--accent-blue`, #6ea8fe).
    static let skillChip = Color(red: 110 / 255, green: 168 / 255, blue: 254 / 255)
}
