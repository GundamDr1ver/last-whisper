import Foundation

/// Start on key-down; defer stop until release so a hold can cancel instead.
struct DictationHotKey {
    enum Action: Equatable { case none, start, stop, cancel }
    static let holdDuration = 0.6
    private(set) var pressedAt: Double?
    private var stopOnRelease = false
    private var consumed = false

    mutating func press(idle: Bool, recording: Bool, now: Double) -> Action {
        guard pressedAt == nil else { return .none }
        pressedAt = now; stopOnRelease = recording; consumed = false
        return idle ? .start : .none
    }
    mutating func held(now: Double) -> Action {
        guard let pressedAt, !consumed, now - pressedAt >= Self.holdDuration else { return .none }
        consumed = true
        return .cancel
    }
    mutating func release(now: Double) -> Action {
        guard let pressedAt else { return .none }
        defer { self.pressedAt = nil; consumed = false; stopOnRelease = false }
        guard !consumed else { return .none }
        if now - pressedAt >= Self.holdDuration { return .cancel }
        return stopOnRelease ? .stop : .none
    }
    mutating func suppressRelease() { consumed = true }
}
