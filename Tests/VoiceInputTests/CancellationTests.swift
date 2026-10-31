import XCTest
import AppKit
@testable import VoiceInput

final class CancellationTests: XCTestCase {
    func testShortFirstPressStartsOnceAndDoesNotStopOnRelease() {
        var key = DictationHotKey()
        XCTAssertEqual(key.press(idle: true, recording: false, now: 0), .start)
        XCTAssertEqual(key.press(idle: false, recording: true, now: 0.1), .none)
        XCTAssertEqual(key.release(now: 0.2), .none)
        XCTAssertNil(key.pressedAt)
        XCTAssertEqual(key.release(now: 0.3), .none)
    }
    func testShortRecordingPressStopsOnlyOnRelease() {
        var key = DictationHotKey()
        XCTAssertEqual(key.press(idle: false, recording: true, now: 10), .none)
        XCTAssertEqual(key.held(now: 10.3), .none)
        XCTAssertEqual(key.release(now: 10.4), .stop)
    }
    func testHoldCancelsOnceAndNeverSubmitsOnRelease() {
        for idle in [true, false] {
            var key = DictationHotKey()
            _ = key.press(idle: idle, recording: !idle, now: 0)
            XCTAssertEqual(key.held(now: 0.7), .cancel)
            XCTAssertEqual(key.press(idle: false, recording: true, now: 0.8), .none)
            XCTAssertEqual(key.held(now: 0.9), .none)
            XCTAssertEqual(key.release(now: 1), .none)
            XCTAssertEqual(key.press(idle: true, recording: false, now: 2), .start)
        }
    }
    func testReleaseDetectsHoldEvenWhenTimerIsDelayed() {
        var key = DictationHotKey()
        _ = key.press(idle: false, recording: true, now: 0)
        XCTAssertEqual(key.release(now: 0.7), .cancel)
        XCTAssertEqual(key.held(now: 1), .none)
    }
    func testBusyShortPressIgnoredAndExplicitCancelSuppressesRelease() {
        var key = DictationHotKey()
        _ = key.press(idle: false, recording: false, now: 0)
        XCTAssertEqual(key.release(now: 0.2), .none)
        _ = key.press(idle: false, recording: true, now: 1)
        key.suppressRelease()
        XCTAssertEqual(key.release(now: 1.1), .none)
    }
    @MainActor func testCancelDiscardsTextWithoutChangingClipboardInEveryActivePhase() {
        let model = DictationModel()
        let clipboardVersion = NSPasteboard.general.changeCount
        for phase in [DictationModel.Phase.preparing, .recording, .processing] {
            model.phase = phase; model.text = "本次应丢弃的文字"; model.audioLevel = 0.8
            model.timingSummary = "旧耗时"; model.needsAttention = true
            model.cancelRecording()
            XCTAssertEqual(model.phase, .idle)
            XCTAssertEqual(model.text, "")
            XCTAssertEqual(model.audioLevel, 0)
            XCTAssertEqual(model.timingSummary, "")
            XCTAssertTrue(model.wasCancelled)
            XCTAssertFalse(model.needsAttention)
            XCTAssertTrue(model.message.contains("已取消"))
            XCTAssertEqual(NSPasteboard.general.changeCount, clipboardVersion)
        }
    }
    @MainActor func testLongPressCancelsAndReleaseDoesNotStartAgain() async throws {
        let model = DictationModel()
        model.phase = .recording; model.text = "discard"
        model.hotKeyPressed()
        XCTAssertEqual(model.phase, .recording)
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.wasCancelled)
        model.hotKeyReleased()
        await Task.yield()
        XCTAssertEqual(model.phase, .idle)
    }
    @MainActor func testClickCancellationStopsHeldTimerFromCancellingNextRecording() async throws {
        let model = DictationModel()
        model.phase = .recording
        model.hotKeyPressed()
        model.cancelRecording()
        model.phase = .recording; model.text = "next recording"
        try await Task.sleep(for: .milliseconds(750))
        model.hotKeyReleased()
        await Task.yield()
        XCTAssertEqual(model.phase, .recording)
        XCTAssertEqual(model.text, "next recording")
        model.cancelRecording()
    }
}
