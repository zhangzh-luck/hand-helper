import SwiftUI
import UIKit
import XCTest
@testable import HandHelperNative

final class AnalysisHeaderLayoutTests: XCTestCase {
    @MainActor
    func testDeleteButtonHasCompactSurfaceAndSeparateTouchHeight() {
        let visible = measured(GradeDeleteVisualLabel(deleting: false))
        let touch = measured(GradeDeleteButton(deleting: false, disabled: false, action: {}))
        let header = measured(GradeSectionHeader(showsDelete: true, deleting: false,
                                                 deleteDisabled: false, onDelete: {})
            .frame(width: 343))
        let todayReference = measured(todayAddButton)
        let previousDelete = measured(previousDeleteButton)

        print("GRADE_DELETE_LAYOUT: visible=\(visible.height), touch=\(touch.height), "
              + "header=\(header.height), todayReference=\(todayReference.height), "
              + "previousDelete=\(previousDelete.height)")
        XCTAssertGreaterThanOrEqual(visible.height, 36)
        XCTAssertLessThanOrEqual(visible.height, 40)
        XCTAssertGreaterThanOrEqual(touch.height, 44)
        XCTAssertLessThanOrEqual(touch.height, 46)
        XCTAssertLessThanOrEqual(header.height, 46)
        XCTAssertLessThan(touch.height, previousDelete.height)
    }

    @MainActor
    private func measured<V: View>(_ view: V) -> CGSize {
        let host = UIHostingController(rootView: view)
        host.loadViewIfNeeded()
        return host.sizeThatFits(in: CGSize(width: 343, height: 1_000))
    }

    @MainActor @ViewBuilder
    private var todayAddButton: some View {
        let button = Button {} label: {
            Label("添加安排", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
        }
        .buttonBorderShape(.capsule)
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    @MainActor @ViewBuilder
    private var previousDeleteButton: some View {
        let button = Button(role: .destructive) {} label: {
            Label("删除本学期成绩", systemImage: "trash")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
        .buttonBorderShape(.capsule)
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glass(.regular.tint(.red)))
                .foregroundStyle(.red)
        } else {
            button.buttonStyle(.bordered)
                .tint(.red)
        }
    }
}
