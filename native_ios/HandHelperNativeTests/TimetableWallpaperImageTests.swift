import ImageIO
import UIKit
import XCTest
@testable import HandHelperNative

final class TimetableWallpaperImageTests: XCTestCase {
    func testDefaultAndPhotoRenderingPoliciesRemainDistinct() {
        XCTAssertFalse(TimetableWallpaperStyle.showsPhoto(hasImage: false,
            reduceTransparency: false, increasedContrast: false))
        XCTAssertTrue(TimetableWallpaperStyle.showsPhoto(hasImage: true,
            reduceTransparency: false, increasedContrast: false))
        XCTAssertFalse(TimetableWallpaperStyle.showsPhoto(hasImage: true,
            reduceTransparency: true, increasedContrast: false))
        XCTAssertFalse(TimetableWallpaperStyle.showsPhoto(hasImage: true,
            reduceTransparency: false, increasedContrast: true))
        XCTAssertEqual(TimetableWallpaperStyle.cellOpacity(hasPhoto: false), 1)
        XCTAssertEqual(TimetableWallpaperStyle.cardOpacity(hasPhoto: false), 1)
        XCTAssertLessThan(TimetableWallpaperStyle.cellOpacity(hasPhoto: true), 0.2)
    }

    @MainActor
    func testDownsamplesWithoutCroppingAndBoundsStoredBytes() async throws {
        let input = imageData(size: CGSize(width: 3000, height: 1500))
        let output = try await TimetableWallpaperImage.prepare(input)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 2400)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 1200)
        XCTAssertLessThanOrEqual(output.count, TimetableWallpaperImage.maxStoredBytes)
        let type = try XCTUnwrap(CGImageSourceGetType(image))
        XCTAssertTrue(CFEqual(type, "public.jpeg" as CFString))
    }

    @MainActor
    func testOrientationIsAppliedToDisplayAndStoredImage() async throws {
        let input = imageData(size: CGSize(width: 80, height: 40))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(input as CFData, nil))
        let raw = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rotated = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            rotated as CFMutableData, "public.jpeg" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, raw,
            [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let display = try await TimetableWallpaperImage.displayImage(rotated as Data)
        XCTAssertEqual(display.width, 40)
        XCTAssertEqual(display.height, 80)
        let output = try await TimetableWallpaperImage.prepare(rotated as Data)
        let storedSource = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let stored = try XCTUnwrap(CGImageSourceCreateImageAtIndex(storedSource, 0, nil))
        XCTAssertEqual(stored.width, 40)
        XCTAssertEqual(stored.height, 80)
    }

    @MainActor
    func testInvalidAndOversizedPhotosAreRejected() async throws {
        do {
            _ = try await TimetableWallpaperImage.prepare(Data([1, 2, 3]))
            XCTFail("Corrupt input must fail")
        } catch TimetableWallpaperImageError.invalidImage {}

        do {
            _ = try await TimetableWallpaperImage.prepare(Data(count: TimetableWallpaperImage.maxSourceBytes + 1))
            XCTFail("Oversized input must fail before decoding")
        } catch TimetableWallpaperImageError.oversizedSource {}
    }

    @MainActor
    func testExistingPNGDisplaysWithoutMigration() async throws {
        let previousFormatImage = imageData(size: CGSize(width: 100, height: 200))
        let displayed = try await TimetableWallpaperImage.displayImage(previousFormatImage)
        XCTAssertEqual(displayed.width, 100)
        XCTAssertEqual(displayed.height, 200)
    }

    @MainActor
    private func imageData(size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
