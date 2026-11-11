import UIKit
import XCTest
@testable import HandHelperNative

@MainActor
final class SettingsAvatarImageCacheTests: XCTestCase {
    func testAvatarUpdatesOnlyWhenSourceBytesChangeAndClearsForAnotherAccount() throws {
        let cache = SettingsAvatarImageCache()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let firstData = try XCTUnwrap(renderer.pngData())

        cache.update(data: firstData)
        let firstImage = try XCTUnwrap(cache.image)
        cache.update(data: firstData)
        XCTAssertTrue(firstImage === cache.image,
                      "Unchanged avatar bytes must reuse the already decoded image.")

        cache.update(data: nil)
        XCTAssertNil(cache.image, "A logout or avatar deletion must clear the stale image.")

        let secondData = try XCTUnwrap(renderer.pngData())
        cache.update(data: secondData)
        XCTAssertNotNil(cache.image)
    }
}
