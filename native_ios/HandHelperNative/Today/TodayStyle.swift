import SwiftUI

enum TodayStyle {
    static func color(_ hex: UInt32, alpha: Double = 1) -> Color {
        Color(red: Double((hex >> 16) & 0xff) / 255,
              green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255).opacity(alpha)
    }

    static func background(_ dark: Bool) -> Color { dark ? .black : color(0xf7f9fc) }
    static func secondary(_ dark: Bool) -> Color { color(dark ? 0xb2b8c2 : 0x64748b) }
    static let shadow = color(0x0f172a, alpha: 18.0 / 255)
}
