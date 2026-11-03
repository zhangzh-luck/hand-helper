import SwiftUI

/// A compact settings navigation label; the containing List/Form row owns the tap target.
struct SettingsNavigationRow: View {
    static let rowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
        }
        .frame(minHeight: 36)
    }
}
