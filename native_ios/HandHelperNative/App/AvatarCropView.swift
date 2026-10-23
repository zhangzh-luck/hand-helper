import SwiftUI
import UIKit

@MainActor
struct AvatarCropView: View {
    let source: Data
    let onUse: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var viewportSide: CGFloat = 1
    @State private var processing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = UIImage(data: source) {
                    GeometryReader { geometry in
                        let side = min(geometry.size.width, geometry.size.height)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: side, height: side)
                            .scaleEffect(zoom)
                            .offset(offset)
                            .frame(width: side, height: side)
                            .clipped()
                            .contentShape(Rectangle())
                            .simultaneousGesture(dragGesture(image: image, side: side))
                            .simultaneousGesture(magnificationGesture(image: image, side: side))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.secondary, lineWidth: 1))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onAppear { viewportSide = side }
                            .onChange(of: side) { _, newSide in
                                viewportSide = newSide
                                offset = bounded(offset, image: image, side: newSide, zoom: zoom)
                                dragStart = offset
                            }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 600)
                    Text("拖动或双指缩放，调整正方形头像范围")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("无法预览图片", systemImage: "photo")
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("裁剪头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(processing ? "处理中…" : "使用头像") { finish() }
                        .disabled(processing || viewportSide <= 1)
                }
            }
        }
        .interactiveDismissDisabled(processing)
        .alert("图片处理失败", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func bounded(_ proposal: CGSize, image: UIImage, side: CGFloat, zoom: CGFloat) -> CGSize {
        guard image.size.width > 0, image.size.height > 0, side > 0 else { return .zero }
        let factor = max(side / image.size.width, side / image.size.height) * zoom
        let maxX = max(0, (image.size.width * factor - side) / 2)
        let maxY = max(0, (image.size.height * factor - side) / 2)
        return CGSize(width: min(max(proposal.width, -maxX), maxX),
                      height: min(max(proposal.height, -maxY), maxY))
    }

    private func dragGesture(image: UIImage, side: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let proposed = CGSize(width: dragStart.width + value.translation.width,
                                      height: dragStart.height + value.translation.height)
                offset = bounded(proposed, image: image, side: side, zoom: zoom)
            }
            .onEnded { _ in dragStart = offset }
    }

    private func magnificationGesture(image: UIImage, side: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(zoomStart * value, 1), 5)
                offset = bounded(offset, image: image, side: side, zoom: zoom)
            }
            .onEnded { _ in zoomStart = zoom; dragStart = offset }
    }

    private func finish() {
        guard !processing, let image = UIImage(data: source),
              image.size.width > 0, image.size.height > 0, viewportSide > 1 else { return }
        let factor = max(viewportSide / image.size.width, viewportSide / image.size.height) * zoom
        let visibleSide = viewportSide / factor
        let originX = min(max((image.size.width - visibleSide) / 2 - offset.width / factor, 0),
                          image.size.width - visibleSide)
        let originY = min(max((image.size.height - visibleSide) / 2 - offset.height / factor, 0),
                          image.size.height - visibleSide)
        let crop = CGRect(x: originX / image.size.width, y: originY / image.size.height,
                          width: visibleSide / image.size.width, height: visibleSide / image.size.height)
        processing = true
        Task {
            defer { processing = false }
            do { onUse(try await AvatarImageProcessor.crop(source, normalizedRect: crop)) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
