import SwiftUI

struct TimetableEmptyCellSelection: Equatable {
    let owner: String
    let authenticationRevision: Int
    let termID: Int
    let week: Int
    let snapshotRevision: Int
    let weekday: Int
    let periodNumber: Int
}

@MainActor
final class TimetableEmptyCellSelectionCoordinator: ObservableObject {
    @Published private(set) var selected: TimetableEmptyCellSelection?
    @Published private(set) var route: ManualCourseEditorRoute?
    private(set) var selectionOperationID: UUID?
    private var lastRouteOperationID: UUID?

    enum OpenRejection: String, Equatable {
        case routeActive, selectionChanged, tabInactive, detailPresenting, pagerBusy
        case termChanged, weekChanged, snapshotChanged, accountChanged
    }

    struct OpeningContext {
        let tabActive: Bool
        let detailPresenting: Bool
        let pagerBusy: Bool
        let termID: Int?
        let week: Int
        let snapshotRevision: Int
        let verifiedOwner: String?
    }

    func select(_ cell: TimetableEmptyCellSelection, operationID: UUID = UUID()) {
        selectionOperationID = operationID
        if selected != cell {
            selected = cell
        }
        TimetableAddCourseDiagnostics.record("cell_selected", operationID: selectionOperationID)
    }

    func clear(reason: String = "unspecified") {
        guard selected != nil else { return }
        TimetableAddCourseDiagnostics.record("selection_cleared_\(reason)", operationID: selectionOperationID)
        selected = nil
        selectionOperationID = nil
    }

    @discardableResult
    func open(_ cell: TimetableEmptyCellSelection, context: OpeningContext,
              tappedAt: TimeInterval) -> OpenRejection? {
        let operationID = selectionOperationID
        let rejection: OpenRejection?
        if route != nil { rejection = .routeActive }
        else if selected != cell { rejection = .selectionChanged }
        else if !context.tabActive { rejection = .tabInactive }
        else if context.detailPresenting { rejection = .detailPresenting }
        else if context.pagerBusy { rejection = .pagerBusy }
        else if context.termID != cell.termID { rejection = .termChanged }
        else if context.week != cell.week { rejection = .weekChanged }
        else if context.snapshotRevision != cell.snapshotRevision { rejection = .snapshotChanged }
        else if context.verifiedOwner != cell.owner { rejection = .accountChanged }
        else { rejection = nil }
        if let rejection {
            TimetableAddCourseDiagnostics.record("guard_rejected_\(rejection.rawValue)",
                                                operationID: operationID, startedAt: tappedAt)
            return rejection
        }
        TimetableAddCourseDiagnostics.record("T1_guards_passed", operationID: operationID, startedAt: tappedAt)
        let newRoute = ManualCourseEditorRoute(cell: cell, operationID: operationID ?? UUID(),
                                               tappedAt: tappedAt)
        clear(reason: "route_opening")
        lastRouteOperationID = newRoute.operationID
        route = newRoute
        TimetableAddCourseDiagnostics.record("T2_route_assigned", operationID: newRoute.operationID,
                                            startedAt: tappedAt)
        return nil
    }

    func dismissRoute(reason: String) {
        guard let route else { return }
        TimetableAddCourseDiagnostics.record("route_cleared_\(reason)",
                                            operationID: route.operationID, startedAt: route.tappedAt)
        self.route = nil
    }

    func sheetDidDismiss() {
        TimetableAddCourseDiagnostics.record("sheet_onDismiss", operationID: lastRouteOperationID)
    }
}
