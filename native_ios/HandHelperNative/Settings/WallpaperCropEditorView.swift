import SwiftUI
import UIKit
import CoreImage

enum WallpaperCropError: LocalizedError {
    case invalidImage
    case invalidCrop
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: "无法读取这张照片，请选择其他图片。"
        case .invalidCrop: "裁剪区域无效，请调整照片后重试。"
        case .encodingFailed: "无法生成裁剪后的壁纸。"
        }
    }
}

enum WallpaperCropProcessor {
    static func normalized(_ image: UIImage) throws -> UIImage {
        guard let source = image.cgImage, image.size.width > 0, image.size.height > 0 else {
            throw WallpaperCropError.invalidImage
        }
        let oriented = CIImage(cgImage: source)
            .oriented(forExifOrientation: exifOrientation(for: image.imageOrientation))
        let extent = oriented.extent.integral
        guard extent.width > 0, extent.height > 0,
              let output = CIContext().createCGImage(oriented, from: extent) else {
            throw WallpaperCropError.invalidImage
        }
        return UIImage(cgImage: output, scale: 1, orientation: .up)
    }

    private static func exifOrientation(for orientation: UIImage.Orientation) -> Int32 {
        switch orientation {
        case .up: 1
        case .upMirrored: 2
        case .down: 3
        case .downMirrored: 4
        case .leftMirrored: 5
        case .right: 6
        case .rightMirrored: 7
        case .left: 8
        @unknown default: 1
        }
    }

    static func jpeg(image: UIImage, crop: CGRect) throws -> Data {
        guard let source = image.cgImage else { throw WallpaperCropError.invalidImage }
        let sourceBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let rounded = crop.integral.intersection(sourceBounds)
        guard rounded.width >= 1, rounded.height >= 1,
              let cropped = source.cropping(to: rounded) else {
            throw WallpaperCropError.invalidCrop
        }
        let maximum = CGFloat(TimetableWallpaperImage.maxPixelSize)
        let ratio = min(1, maximum / max(rounded.width, rounded.height))
        let outputSize = CGSize(width: max(1, floor(rounded.width * ratio)),
                                height: max(1, floor(rounded.height * ratio)))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let output = UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            UIImage(cgImage: cropped, scale: 1, orientation: .up)
                .draw(in: CGRect(origin: .zero, size: outputSize))
        }
        guard let data = output.jpegData(compressionQuality: 0.88),
              data.count <= TimetableWallpaperImage.maxStoredBytes else {
            throw WallpaperCropError.encodingFailed
        }
        return data
    }
}

@MainActor
struct WallpaperCropEditorView: View {
    let image: UIImage
    let aspectRatio: CGFloat
    let onCancel: () -> Void
    let onComplete: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var zoomStart: CGFloat?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let cropSize = cropSize(in: proxy.size)
                let scale = baseScale(for: cropSize) * zoom
                let imageSize = CGSize(width: image.size.width * scale,
                                       height: image.size.height * scale)
                VStack(spacing: 18) {
                    Spacer(minLength: 0)
                    ZStack {
                        Color.black
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: imageSize.width, height: imageSize.height)
                            .offset(clamped(offset, imageSize: imageSize, cropSize: cropSize))
                    }
                    .frame(width: cropSize.width, height: cropSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.9), lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(imageSize: imageSize, cropSize: cropSize))
                    .simultaneousGesture(magnifyGesture(imageSize: imageSize, cropSize: cropSize))
                    Text("拖动照片，双指缩放；照片将按当前页面的实际显示比例裁剪。")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
                .onChange(of: cropSize) { _, newValue in
                    offset = clamped(offset,
                                     imageSize: CGSize(width: image.size.width * baseScale(for: newValue) * zoom,
                                                       height: image.size.height * baseScale(for: newValue) * zoom),
                                     cropSize: newValue)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { onCancel(); dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            do {
                                let crop = cropRect(imageSize: imageSize, cropSize: cropSize, scale: scale)
                                let data = try WallpaperCropProcessor.jpeg(image: image, crop: crop)
                                AppHaptics.trigger(.cropCompleted)
                                onComplete(data)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
            }
            .navigationTitle("裁剪壁纸")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("无法裁剪壁纸", isPresented: Binding(get: { errorMessage != nil },
                                                    set: { if !$0 { errorMessage = nil } })) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func cropSize(in available: CGSize) -> CGSize {
        let horizontal = max(0, available.width - 32)
        let vertical = max(0, available.height - 150)
        guard horizontal > 0, vertical > 0, aspectRatio > 0 else { return .zero }
        if horizontal / vertical > aspectRatio {
            return CGSize(width: vertical * aspectRatio, height: vertical)
        }
        return CGSize(width: horizontal, height: horizontal / aspectRatio)
    }

    private func baseScale(for cropSize: CGSize) -> CGFloat {
        max(cropSize.width / image.size.width, cropSize.height / image.size.height)
    }

    private func clamped(_ candidate: CGSize, imageSize: CGSize, cropSize: CGSize) -> CGSize {
        let limitX = max(0, (imageSize.width - cropSize.width) / 2)
        let limitY = max(0, (imageSize.height - cropSize.height) / 2)
        return CGSize(width: min(max(candidate.width, -limitX), limitX),
                      height: min(max(candidate.height, -limitY), limitY))
    }

    private func cropRect(imageSize: CGSize, cropSize: CGSize, scale: CGFloat) -> CGRect {
        let displayedOffset = clamped(offset, imageSize: imageSize, cropSize: cropSize)
        return CGRect(x: (imageSize.width - cropSize.width) / 2 / scale - displayedOffset.width / scale,
                      y: (imageSize.height - cropSize.height) / 2 / scale - displayedOffset.height / scale,
                      width: cropSize.width / scale,
                      height: cropSize.height / scale)
    }

    private func dragGesture(imageSize: CGSize, cropSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = offset }
                let start = dragStart ?? .zero
                offset = clamped(CGSize(width: start.width + value.translation.width,
                                        height: start.height + value.translation.height),
                                 imageSize: imageSize, cropSize: cropSize)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func magnifyGesture(imageSize: CGSize, cropSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if zoomStart == nil { zoomStart = zoom }
                zoom = min(max((zoomStart ?? 1) * value, 1), 5)
                let updated = CGSize(width: image.size.width * baseScale(for: cropSize) * zoom,
                                     height: image.size.height * baseScale(for: cropSize) * zoom)
                offset = clamped(offset, imageSize: updated, cropSize: cropSize)
            }
            .onEnded { _ in zoomStart = nil }
    }
}

struct WallpaperCropPreview: Identifiable {
    let id = UUID()
    let data: Data
    let generation: Int
}

@MainActor
struct WallpaperCropPreviewView: View {
    let preview: WallpaperCropPreview
    let onCancel: () -> Void
    let onUse: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = UIImage(data: preview.data) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 20)
                }
                Text("确认后才会替换当前壁纸。")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("壁纸预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回编辑") { onCancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用") { onUse() }.fontWeight(.semibold)
                }
            }
        }
    }
}
