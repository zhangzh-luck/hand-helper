import SwiftUI

enum DestructiveConfirmationKind: Equatable {
    case grades, schedule, manualCourse

    var title: String {
        switch self {
        case .grades: "删除本学期成绩？"
        case .schedule: "删除这项安排？"
        case .manualCourse: "删除这门课程？"
        }
    }

    var message: String {
        switch self {
        case .grades: "将删除本学期已导入的全部成绩及对应 AI 分析缓存，此操作无法撤销，其他学期不受影响。"
        case .schedule: "删除后无法恢复这项自定义安排。"
        case .manualCourse: "删除后这门手动课程将从本机课程表移除。"
        }
    }

    var deleteTitle: String {
        switch self {
        case .grades: "删除成绩"
        case .schedule: "删除安排"
        case .manualCourse: "删除课程"
        }
    }
}

struct DestructiveConfirmationRequest: Identifiable {
    let id = UUID()
    let kind: DestructiveConfirmationKind
    let confirm: @MainActor () -> Void
    let cancel: @MainActor () -> Void
}

/// Keeps the business target alive until the system Alert action runs.
@MainActor
final class DestructiveConfirmationCoordinator: ObservableObject {
    @Published private(set) var request: DestructiveConfirmationRequest?
    @Published private(set) var alertVisible = false

    var isPresenting: Bool { request != nil }

    @discardableResult
    func present(_ kind: DestructiveConfirmationKind,
                 confirm: @escaping @MainActor () -> Void,
                 cancel: @escaping @MainActor () -> Void) -> Bool {
        guard request == nil else { return false }
        request = DestructiveConfirmationRequest(kind: kind, confirm: confirm, cancel: cancel)
        alertVisible = true
        return true
    }

    // SwiftUI can set the binding to false before invoking a Button action.
    // Do not discard the request here; the captured Alert action still needs its ID.
    func setAlertVisible(_ visible: Bool) { alertVisible = visible }

    func confirm(id: UUID) {
        guard let current = request, current.id == id else { return }
        request = nil
        alertVisible = false
        current.confirm()
    }

    func cancel(id: UUID) {
        guard let current = request, current.id == id else { return }
        request = nil
        alertVisible = false
        current.cancel()
    }

    func clear() {
        guard let current = request else { return }
        cancel(id: current.id)
    }
}
