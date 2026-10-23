import SwiftUI

enum DesignTokens {
    static let brand = Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255)
    static let actionBlue = Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255)
    static let lightBackground = Color(red: 244 / 255, green: 247 / 255, blue: 251 / 255)
    static let darkBackground = Color.black
    static let lightCard = Color.white
    static let darkCard = Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255)
    static let lightPrimaryText = Color(red: 23 / 255, green: 32 / 255, blue: 51 / 255)
    static let darkPrimaryText = Color.white
    static let lightSecondaryText = Color(red: 100 / 255, green: 116 / 255, blue: 139 / 255)
    static let darkSecondaryText = Color(red: 161 / 255, green: 161 / 255, blue: 166 / 255)

    static let pageInset: CGFloat = 18
    static let cardRadius: CGFloat = 18
    static let cardShadowColor = Color(red: 15 / 255, green: 23 / 255, blue: 42 / 255).opacity(16 / 255)
    static let cardShadowBlur: CGFloat = 9
    static let headingSize: CGFloat = 27
    static let bodySize: CGFloat = 15
    static let secondarySize: CGFloat = 12
    static let shortAnimation: TimeInterval = 0.22
    static let standardAnimation: TimeInterval = 0.26
    static let tabVisibilityAnimation: TimeInterval = 0.20
    static let standardCurve = Animation.timingCurve(0.215, 0.61, 0.355, 1, duration: standardAnimation)
}
