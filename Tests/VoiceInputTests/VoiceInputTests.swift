import XCTest
import AppKit
import AVFoundation
@testable import VoiceInput

final class VoiceInputTests: XCTestCase {
    func testCaptureTimingMeasuresFirstAudioAndIgnoresLaterBuffers() {
        let timing = CaptureStartTiming(requestedAt: 100)
        XCTAssertEqual(timing.receiveFirstBuffer(now: 100.08)!, 0.08, accuracy: 0.00001)
        XCTAssertNil(timing.receiveFirstBuffer(now: 100.16))
    }
    func testSpeechEvidenceRejectsNoiseSpikesAndShortCue() {
        let cases: [[Float]] = [Array(repeating: 0.1, count: 200), [0, 0.99, 0.99, 0, 0], [0.1, 0.95, 0.2, 0.1, 0.1, 0.1, 0.1, 0.1, 0.95], [.nan, .infinity, 0]]
        for probabilities in cases {
            XCTAssertFalse(SpeechEvidence.decide(probabilities: probabilities, sampleCount: probabilities.count * 512).hasSpeech)
        }
    }
    func testSpeechEvidenceKeepsShortSpeechWithPaddingAndPauses() {
        let probabilities: [Float] = Array(repeating: 0.1, count: 20) + Array(repeating: 0.95, count: 8) + Array(repeating: 0.1, count: 30) + Array(repeating: 0.95, count: 8) + Array(repeating: 0.1, count: 20)
        let decision = SpeechEvidence.decide(probabilities: probabilities, sampleCount: probabilities.count * 512)
        XCTAssertTrue(decision.hasSpeech)
        XCTAssertEqual(decision.ranges.count, 2)
        XCTAssertLessThan(decision.ranges[0].lowerBound, 20 * 512)
        XCTAssertGreaterThan(decision.ranges[1].upperBound, 66 * 512)
        XCTAssertLessThan(decision.ranges[0].upperBound, decision.ranges[1].lowerBound)
    }
    @MainActor func testNativeDictationCuesAreDecodableAndNotClipped() throws {
        for cue in [RecordingCue.start, .stop] {
            let fallback = try XCTUnwrap(cue.url)
            let sound = try XCTUnwrap(NSSound(contentsOf: fallback, byReference: false))
            XCTAssertGreaterThan(sound.duration, 0.15)
            XCTAssertLessThan(sound.duration, 0.5)
            XCTAssertNotNil(cue.sound)
            let file = try AVAudioFile(forReading: fallback)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            XCTAssertLessThan(samples.map { abs($0) }.max()!, 0.95)
            XCTAssertGreaterThan(sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)), 0.02)
            XCTAssertLessThan(abs(samples.first!), 0.01)
            XCTAssertLessThan(abs(samples.last!), 0.01)
        }
        XCTAssertNotEqual(RecordingCue.start.url, RecordingCue.stop.url)
    }
    @MainActor func testClipboardPreservesMultipleItemsAndFormats() {
        let clipboard = NSPasteboard.withUniqueName(); defer { clipboard.releaseGlobally() }
        let first = NSPasteboardItem(); first.setString("original", forType: .string)
        first.setData(Data("<b>original</b>".utf8), forType: .html)
        let second = NSPasteboardItem(); second.setString("second item", forType: .string)
        clipboard.writeObjects([first, second])
        let saved = ClipboardSnapshot(clipboard)
        clipboard.clearContents(); clipboard.setString("dictation", forType: .string)
        saved.restore(to: clipboard)
        XCTAssertEqual(clipboard.pasteboardItems?.count, 2)
        XCTAssertEqual(clipboard.pasteboardItems?.first?.string(forType: .string), "original")
        XCTAssertEqual(clipboard.pasteboardItems?.last?.string(forType: .string), "second item")
        XCTAssertEqual(clipboard.pasteboardItems?.first?.data(forType: .html), Data("<b>original</b>".utf8))
    }
}

final class RecordingTests: XCTestCase {
    func testRecordingExcludesCueAndConvertsTo16kMono() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        buffer.floatChannelData![0].initialize(repeating: 0.8, count: 4800)
        let url = directory.appendingPathComponent("recording.wav")
        let capture = try RecordingCapture(format: format, url: url)
        for _ in 0..<5 { capture.append(buffer) }
        capture.begin()
        buffer.floatChannelData![0].update(repeating: 0.1, count: 4800)
        for _ in 0..<12 { capture.append(buffer) }
        capture.finish()
        let result = try AudioSamples.load(url)
        XCTAssertGreaterThan(result.count, 18800); XCTAssertLessThanOrEqual(result.count, 19200)
        XCTAssertLessThan(result.map { abs($0) }.max()!, 0.15)
        let recorded = try AVAudioFile(forReading: url)
        XCTAssertEqual(recorded.processingFormat.sampleRate, 16000)
        XCTAssertEqual(recorded.processingFormat.channelCount, 1)
    }
    func testSilenceDoesNotReachLocalModel() async throws {
        let samples = Array(repeating: Float(0), count: 32000)
        let text = try await RecordingRecognition.transcribe(samples, settings: .init())
        XCTAssertEqual(text, "")
    }
}

final class SettingsAndDownloadTests: XCTestCase {
    @MainActor func testUpgradeKeepsLocalUntilCloudIsExplicitlySaved() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("cloud", forKey: "recognitionMode")
        defaults.set("mimo", forKey: "cloudModelID")
        defaults.set(true, forKey: "batchPolishEnabled")
        defaults.set("whisper", forKey: "localModel")
        let draft = SettingsDraft()
        draft.load(defaults: defaults)
        XCTAssertEqual(draft.selection, RecognitionSettings(local: .whisper, cloudID: "mimo"))
        XCTAssertFalse(draft.dirty)
        draft.selection.local = .qwen
        XCTAssertTrue(draft.dirty)
        draft.selection.local = .whisper
        XCTAssertFalse(draft.dirty)
        draft.selection.local = .vibevoice
        draft.save(defaults: defaults)
        XCTAssertFalse(draft.dirty)
        XCTAssertEqual(RecognitionSettings.load(defaults), RecognitionSettings(local: .vibevoice, cloudID: "mimo"))
        XCTAssertTrue(defaults.bool(forKey: "batchPolishEnabled")) // Legacy settings are ignored, not destroyed.
    }
    func testWhisperWaveEncodingPreservesPCMAndHeader() {
        let data = PCM16.wave([0, 1, -1, .nan])
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(Array(data.suffix(8)), [0, 0, 255, 127, 1, 128, 0, 0])
    }
    func testDownloadCancelledBeforeStartDoesNotConnect() async throws {
        let download = ModelFileTransfer(expectedBytes: 10, update: { _ in XCTFail("No progress expected") })
        download.cancel()
        do { _ = try await download.download(URLRequest(url: URL(string: "https://example.invalid/model")!)); XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testInvalidModelFileCannotBeInstalled() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("truncated download".utf8).write(to: file)
        XCTAssertThrowsError(try LocalModel.qwen.validate(file))
    }
}

final class ModelSelectionTests: XCTestCase {
    func testDefaultAndDownloadCatalog() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(RecognitionSettings.load(defaults).local, .qwen)
        XCTAssertEqual(LocalModel.allCases.first, .qwen)
        XCTAssertTrue(LocalModel.qwen.downloadURL.path.contains("Qwen3-ASR-1.7B-GGUF"))
        XCTAssertEqual(LocalModel.qwen.bytes, 2_473_017_600)
        XCTAssertEqual(LocalModel.whisper.file, "ggml-large-v3-turbo-q8_0.bin")
        XCTAssertEqual(Set(LocalModel.allCases.map(\.file)).count, 3)
        for model in LocalModel.allCases {
            XCTAssertEqual(model.sha256.count, 64)
            XCTAssertEqual(model.downloadURL.scheme, "https")
        }
        defaults.set("whisper", forKey: "localModel")
        XCTAssertEqual(RecognitionSettings.load(defaults).local, .whisper)
        defaults.set("invalid", forKey: "localModel")
        XCTAssertEqual(RecognitionSettings.load(defaults).local, .qwen)
    }
    func testWhisperUsesTranscriptionAndAutomaticLanguage() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: WhisperRecognition.executable.path))
        let file = URL(fileURLWithPath: "/private/tmp/a file")
        let args = WhisperRecognition.arguments(model: file, audio: file, output: file)
        XCTAssertTrue(args.contains("auto"))
        XCTAssertTrue(args.contains("-otxt"))
        XCTAssertFalse(args.contains("--translate"))
        XCTAssertFalse(args.contains("-tr"))
        XCTAssertThrowsError(try WhisperRecognition.transcribe([Float](repeating: 0, count: 16000), model: URL(fileURLWithPath: "/nonexistent-model.bin")))
    }
}

final class BrandingTests: XCTestCase {
    @MainActor func testMenuIconUsesSEMonogramAndAdaptsToMenuBar() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MenuBarIcon", withExtension: "svg", subdirectory: "Resources"))
        let svg = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(svg.contains("speakeasy SE"))
        let icon = SpeakeasyBrand.menuIcon
        XCTAssertTrue(icon.isValid)
        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size, NSSize(width: 20, height: 20))
        let data = try XCTUnwrap(icon.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var visible = false, transparent = false
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 5) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 5) {
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                visible = visible || alpha > 0.5
                transparent = transparent || alpha < 0.1
            }
        }
        XCTAssertTrue(visible)
        XCTAssertTrue(transparent)
    }
}
