import Foundation
import ImageIO

enum TimetableWallpaperImageError: LocalizedError {
    case oversizedSource
    case invalidImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .oversizedSource: "照片需小于 30 MB，且不超过 8000 万像素。"
        case .invalidImage: "无法读取这张照片，请选择其他图片。"
        case .encodingFailed: "照片处理失败，请选择其他图片。"
        }
    }
}

/// A single bounded image for the fixed timetable background. Existing wallpaper files
/// are left untouched; `displayImage` also downsamples those files when they are read.
enum TimetableWallpaperImage {
    static let maxPixelSize = 2400
    static let maxSourceBytes = 30_000_000
    static let maxSourcePixels = 80_000_000
    static let maxStoredBytes = 8_000_000

    static func prepare(_ data: Data) async throws -> Data {
        let worker = Task.detached(priority: .userInitiated) {
            guard !data.isEmpty, data.count <= maxSourceBytes else {
                throw TimetableWallpaperImageError.oversizedSource
            }
            let image = try thumbnail(data, enforceSourceLimit: true)
            try Task.checkCancellation()
            for quality in [0.85, 0.72, 0.58] {
                if let jpeg = encodeJPEG(image, quality: quality), jpeg.count <= maxStoredBytes {
                    return jpeg
                }
            }
            throw TimetableWallpaperImageError.encodingFailed
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func displayImage(_ data: Data) async throws -> CGImage {
        let worker = Task.detached(priority: .userInitiated) {
            try thumbnail(data, enforceSourceLimit: false)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func thumbnail(_ data: Data, enforceSourceLimit: Bool) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
            width > 0, height > 0 else { throw TimetableWallpaperImageError.invalidImage }
        guard !enforceSourceLimit || Double(width) * Double(height) <= Double(maxSourcePixels) else {
            throw TimetableWallpaperImageError.oversizedSource
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false
        ]
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw TimetableWallpaperImageError.invalidImage
        }
        return image
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
