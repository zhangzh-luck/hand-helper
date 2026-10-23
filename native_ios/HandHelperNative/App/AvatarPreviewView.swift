import SwiftUI
import UIKit

enum AvatarPreviewGeometry {
    static func boundedOffset(_ proposed: CGSize, image: CGSize,
                              viewport: CGSize, scale: CGFloat) -> CGSize {
        guard image.width > 0, image.height > 0,
              viewport.width > 0, viewport.height > 0 else { return .zero }
        let fit = min(viewport.width / image.width, viewport.height / image.height)
        let maxX = max(0, (image.width * fit * scale - viewport.width) / 2)
        let maxY = max(0, (image.height * fit * scale - viewport.height) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }
}

@MainActor
struct AvatarPreviewView: View {
    let data: Data?
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var pinchStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                if let data, let image = UIImage(data: data) {
                    GeometryReader { geometry in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .scaleEffect(scale)
                            .offset(offset)
                            .contentShape(Rectangle())
                            .simultaneousGesture(dragGesture(image: image, viewport: geometry.size))
                            .simultaneousGesture(magnifyGesture(image: image, viewport: geometry.size))
                            .accessibilityLabel("头像大图")
                            .accessibilityHint("双指缩放或拖动查看")
                            .accessibilityAdjustableAction { direction in
                                switch direction {
                                case .increment: changeScale(to: scale + 0.5, image: image, viewport: geometry.size)
                                case .decrement: changeScale(to: scale - 0.5, image: image, viewport: geometry.size)
                                @unknown default: break
                                }
                            }
                            .onChange(of: geometry.size) { _, size in
                                offset = AvatarPreviewGeometry.boundedOffset(offset,
                                    image: image.size, viewport: size, scale: scale)
                                dragStart = offset
                            }
                    }
                    .clipped()
                } else {
                    ContentUnavailableView("尚未设置头像", systemImage: "person.crop.circle")
                }
            }
            .navigationTitle("头像预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func changeScale(to value: CGFloat, image: UIImage, viewport: CGSize) {
        scale = min(max(value, 1), 5)
        pinchStart = scale
        offset = AvatarPreviewGeometry.boundedOffset(offset,
            image: image.size, viewport: viewport, scale: scale)
        dragStart = offset
    }

    private func dragGesture(image: UIImage, viewport: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let proposed = CGSize(width: dragStart.width + value.translation.width,
                                      height: dragStart.height + value.translation.height)
                offset = AvatarPreviewGeometry.boundedOffset(proposed,
                    image: image.size, viewport: viewport, scale: scale)
            }
            .onEnded { _ in dragStart = offset }
    }

    private func magnifyGesture(image: UIImage, viewport: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(pinchStart * value.magnification, 1), 5)
                offset = AvatarPreviewGeometry.boundedOffset(offset,
                    image: image.size, viewport: viewport, scale: scale)
            }
            .onEnded { _ in pinchStart = scale; dragStart = offset }
    }
}
