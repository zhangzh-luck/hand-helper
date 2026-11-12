import SwiftUI
import UIKit

enum TodayAvatarLightboxLayout {
    static func imageSide(in viewport: CGSize) -> CGFloat {
        max(1, min(viewport.width - 48, viewport.height - 150, 520))
    }

    static func targetImageFrame(in viewport: CGSize) -> CGRect {
        let side = imageSide(in: viewport)
        let stackHeight = side + 24 + 54
        return CGRect(x: (viewport.width - side) / 2,
                      y: max(0, (viewport.height - stackHeight) / 2),
                      width: side, height: side)
    }

    static func closeButtonCenter(for imageFrame: CGRect) -> CGPoint {
        CGPoint(x: imageFrame.midX, y: imageFrame.maxY + 24 + 27)
    }

    static func localSourceFrame(sourceFrameInGlobal: CGRect, containerFrameInGlobal: CGRect) -> CGRect? {
        guard sourceFrameInGlobal.width > 0, sourceFrameInGlobal.height > 0,
              containerFrameInGlobal.width > 0, containerFrameInGlobal.height > 0 else { return nil }
        let local = sourceFrameInGlobal.offsetBy(dx: -containerFrameInGlobal.minX,
                                                 dy: -containerFrameInGlobal.minY)
        let bounds = CGRect(origin: .zero, size: containerFrameInGlobal.size)
        return bounds.contains(local) ? local : nil
    }

    static func shouldUseHero(reduceMotion: Bool, sourceFrame: CGRect?, openingViewport: CGSize?,
                              currentViewport: CGSize) -> Bool {
        guard !reduceMotion, sourceFrame != nil else { return false }
        guard let openingViewport else { return true }
        return openingViewport == currentViewport
    }

    static func displayedImageFrame(sourceFrame: CGRect?, targetFrame: CGRect,
                                    isVisible: Bool, usesHero: Bool) -> CGRect {
        guard usesHero, let sourceFrame else { return targetFrame }
        return isVisible ? targetFrame : sourceFrame
    }

    /// A hero overlay replaces the source image immediately at its source frame.
    /// Non-hero presentations retain the existing fade-in behavior.
    static func imageOpacity(isVisible: Bool, usesHero: Bool) -> Double {
        usesHero || isVisible ? 1 : 0
    }

    static func interpolatedFrame(from source: CGRect, to target: CGRect, progress: CGFloat) -> CGRect {
        let amount = min(max(progress, 0), 1)
        return CGRect(x: source.minX + (target.minX - source.minX) * amount,
                      y: source.minY + (target.minY - source.minY) * amount,
                      width: source.width + (target.width - source.width) * amount,
                      height: source.height + (target.height - source.height) * amount)
    }
}

struct TodayAvatarLightboxView: View {
    let image: UIImage
    let sourceFrameInGlobal: CGRect
    let isVisible: Bool
    let reduceMotion: Bool
    let onClose: () -> Void
    @State private var openingViewport: CGSize?

    var body: some View {
        GeometryReader { geometry in
            let targetFrame = TodayAvatarLightboxLayout.targetImageFrame(in: geometry.size)
            let sourceFrame = TodayAvatarLightboxLayout.localSourceFrame(
                sourceFrameInGlobal: sourceFrameInGlobal,
                containerFrameInGlobal: geometry.frame(in: .global)
            )
            let usesHero = TodayAvatarLightboxLayout.shouldUseHero(
                reduceMotion: reduceMotion,
                sourceFrame: sourceFrame,
                openingViewport: openingViewport,
                currentViewport: geometry.size
            )
            let imageFrame = TodayAvatarLightboxLayout.displayedImageFrame(
                sourceFrame: sourceFrame, targetFrame: targetFrame,
                isVisible: isVisible, usesHero: usesHero
            )
            let cornerRadius: CGFloat = usesHero && !isVisible ? 18 : 24
            ZStack {
                Color.black.opacity(isVisible ? 0.74 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { } // Consume taps without dismissing or touching the page below.

                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.white, lineWidth: 2.5)
                            .opacity(isVisible ? 1 : 0)
                    }
                    .opacity(TodayAvatarLightboxLayout.imageOpacity(isVisible: isVisible,
                                                                     usesHero: usesHero))
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                    .accessibilityLabel("头像大图")

                GlassCloseButton(accessibilityLabel: "关闭头像预览", diameter: 54,
                                 onDarkBackground: true, action: onClose)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    .position(TodayAvatarLightboxLayout.closeButtonCenter(for: targetFrame))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear { openingViewport = geometry.size }
        }
        .ignoresSafeArea()
    }
}
