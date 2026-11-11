import UIKit
import XCTest
@testable import HandHelperNative

@MainActor
final class SettingsAvatarImageCacheTests: XCTestCase {
    func testAvatarUpdatesOnlyWhenSourceBytesChangeAndClearsForAnotherAccount() throws {
        let cache = SettingsAvatarImageCache()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let firstData = renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }

        cache.update(data: firstData)
        let firstImage = try XCTUnwrap(cache.image)
        cache.update(data: firstData)
        XCTAssertTrue(firstImage === cache.image,
                      "Unchanged avatar bytes must reuse the already decoded image.")

        cache.update(data: nil)
        XCTAssertNil(cache.image, "A logout or avatar deletion must clear the stale image.")

        let secondData = renderer.pngData { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        cache.update(data: secondData)
        XCTAssertNotNil(cache.image)
    }
}
