import SwiftUI
import UIKit

enum TodayAvatarLightboxLayout {
    static func imageSide(in viewport: CGSize) -> CGFloat {
        max(1, min(viewport.width - 48, viewport.height - 150, 520))
    }
}

struct TodayAvatarLightboxView: View {
    let image: UIImage
    let isVisible: Bool
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let side = TodayAvatarLightboxLayout.imageSide(in: geometry.size)
            ZStack {
                Color.black.opacity(isVisible ? 0.74 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { } // Consume taps without dismissing or touching the page below.

                VStack(spacing: 24) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(.white, lineWidth: 2.5)
                        }

                    GlassCloseButton(accessibilityLabel: "关闭头像预览", diameter: 54,
                                     onDarkBackground: true, action: onClose)
                }
                .scaleEffect(isVisible ? 1 : 0.92)
                .opacity(isVisible ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }
}
