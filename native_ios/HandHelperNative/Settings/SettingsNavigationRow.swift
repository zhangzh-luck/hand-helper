import SwiftUI

/// A compact settings navigation label; the containing List/Form row owns the tap target.
struct SettingsNavigationRow: View {
    static let rowInsets = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)

    private enum Icon {
        case system(name: String, color: Color)
        case asset(name: String)
    }

    let title: String
    private let icon: Icon

    init(title: String, symbol: String, color: Color) {
        self.title = title
        icon = .system(name: symbol, color: color)
    }

    init(title: String, assetName: String) {
        self.title = title
        icon = .asset(name: assetName)
    }

    var body: some View {
        HStack(spacing: 12) {
            iconView
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
        }
        .frame(minHeight: 56)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case let .system(name, color):
            Image(systemName: name)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case let .asset(name):
            Image(name)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .accessibilityHidden(true)
    }
}
