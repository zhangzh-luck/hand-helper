import SwiftUI

/// A single native surface for close controls shown over modal content.
struct GlassCloseButton: View {
    let accessibilityLabel: String
    let diameter: CGFloat
    let onDarkBackground: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(onDarkBackground ? Color.white : Color.primary)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(GlassCloseButtonSurface())
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct GlassCloseButtonSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}
