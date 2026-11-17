import Foundation
import XCTest
@testable import HandHelperNative

final class WidgetProbeTests: XCTestCase {
    func testProbeDistinguishesUnavailableMissingInvalidAndSuccess() throws {
        XCTAssertEqual(WidgetProbeStore.read(from: nil), .containerUnavailable)
        XCTAssertEqual(WidgetProbeStore.write(to: nil), .containerUnavailable)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(WidgetProbeStore.read(from: directory), .missing)
        XCTAssertEqual(WidgetProbeStore.write(to: directory), .success)
        XCTAssertEqual(WidgetProbeStore.read(from: directory), .success)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("widget-probe-v1.txt"))
        XCTAssertEqual(WidgetProbeStore.read(from: directory), .invalid)
    }
}
