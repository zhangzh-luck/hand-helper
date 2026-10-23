import CoreGraphics

struct ScheduleSwipeState {
    static let actionWidth: CGFloat = 168
    static let threshold: CGFloat = 72

    private(set) var reveal: CGFloat = 0
    private(set) var dragging = false
    private var dragStart: CGFloat = 0

    mutating func update(horizontal: CGFloat, vertical: CGFloat) {
        guard abs(horizontal) > abs(vertical) else { return }
        if !dragging { dragging = true; dragStart = reveal }
        reveal = min(Self.actionWidth, max(0, dragStart - horizontal))
    }

    mutating func end() {
        guard dragging else { return }
        dragging = false
        reveal = reveal >= Self.threshold ? Self.actionWidth : 0
    }

    mutating func close() {
        dragging = false
        reveal = 0
    }
}
