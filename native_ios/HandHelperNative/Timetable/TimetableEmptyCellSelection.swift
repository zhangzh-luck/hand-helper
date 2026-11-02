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

    func select(_ cell: TimetableEmptyCellSelection) {
        if selected != cell { selected = cell }
    }

    func clear() {
        if selected != nil { selected = nil }
    }
}
