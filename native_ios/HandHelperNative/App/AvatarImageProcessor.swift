import Foundation
import ImageIO

enum AvatarImageError: LocalizedError {
    case oversizedSource, invalidImage, encodingFailed

    var errorDescription: String? {
        switch self {
        case .oversizedSource: "原图需小于 15 MB，且不超过 2500 万像素。"
        case .invalidImage: "无法读取这张图片，请选择可识别的照片。"
        case .encodingFailed: "头像处理失败，请更换图片后重试。"
        }
    }
}

enum AvatarImageProcessor {
    static func prepare(_ data: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard !data.isEmpty, data.count <= 15_000_000 else { throw AvatarImageError.oversizedSource }
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                  width > 0, height > 0 else { throw AvatarImageError.invalidImage }
            guard Double(width) * Double(height) <= 25_000_000 else { throw AvatarImageError.oversizedSource }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCache: false
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let encoded = encodeJPEG(image, quality: 0.9) else {
                throw AvatarImageError.invalidImage
            }
            return encoded
        }.value
    }

    /// `rect` uses coordinates normalized to the orientation-corrected preview image.
    static func crop(_ data: Data, normalizedRect rect: CGRect) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  rect.width > 0, rect.height > 0 else { throw AvatarImageError.invalidImage }
            let width = CGFloat(image.width)
            let height = CGFloat(image.height)
            let side = max(1, min(Int((rect.width * width).rounded(.down)),
                                  Int((rect.height * height).rounded(.down))))
            let x = max(0, min(Int((rect.minX * width).rounded()), image.width - side))
            let y = max(0, min(Int((rect.minY * height).rounded()), image.height - side))
            let pixelRect = CGRect(x: CGFloat(x), y: CGFloat(y),
                                   width: CGFloat(side), height: CGFloat(side))
            guard let cropped = image.cropping(to: pixelRect),
                  let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw AvatarImageError.invalidImage
            }
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 512, height: 512))
            guard let result = context.makeImage() else { throw AvatarImageError.encodingFailed }
            for quality in [0.86, 0.75, 0.64, 0.52] {
                if let jpeg = encodeJPEG(result, quality: quality),
                   jpeg.count <= 1_000_000 { return jpeg }
            }
            throw AvatarImageError.encodingFailed
        }.value
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result as CFMutableData,
            "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return result as Data
    }
}
