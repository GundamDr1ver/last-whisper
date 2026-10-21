import Foundation

/// The microphone callback and main actor share only this lock-protected timestamp.
/// The first-buffer measurement does not retain any audio or keep the microphone running.
final class CaptureStartTiming: @unchecked Sendable {
    private let lock = NSLock()
    private let requestedAt: Double
    private var received = false
    init(requestedAt: Double) { self.requestedAt = requestedAt }
    func receiveFirstBuffer(now: Double = ProcessInfo.processInfo.systemUptime) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard !received else { return nil }
        received = true
        return max(0, now - requestedAt)
    }
}
