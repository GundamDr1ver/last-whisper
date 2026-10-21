import XCTest
import AppKit
import AVFoundation
@testable import VoiceInput

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class VoiceInputTests: XCTestCase {
    func testPolishingStartsDisabledEvenWithLegacyOptIn() throws {
        let name = "VoiceInputTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "polish")
        XCTAssertFalse(APIConfiguration.load(defaults: defaults, keyProvider: { "" }).polish)
        defaults.set(true, forKey: "batchPolishEnabled")
        XCTAssertTrue(APIConfiguration.load(defaults: defaults, keyProvider: { "" }).polish)
        defaults.set(false, forKey: "batchPolishEnabled")
        XCTAssertFalse(APIConfiguration.load(defaults: defaults, keyProvider: { "" }).polish)
    }
    func testCaptureTimingMeasuresFirstAudioAndIgnoresLaterBuffers() {
        let timing = CaptureStartTiming(requestedAt: 100)
        XCTAssertEqual(timing.receiveFirstBuffer(now: 100.08)!, 0.08, accuracy: 0.00001)
        XCTAssertNil(timing.receiveFirstBuffer(now: 100.16))
    }
    func testDisabledDictationDoesNotReadKeychain() throws {
        let name = "VoiceInputTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var reads = 0
        let config = APIConfiguration.load(defaults: defaults, keyProvider: { reads += 1; return "secret" }, includeKeyWhenDisabled: false)
        XCTAssertFalse(config.polish)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(config.polishKey, "")
        defaults.set(true, forKey: "batchPolishEnabled")
        let enabled = APIConfiguration.load(defaults: defaults, keyProvider: { reads += 1; return "secret" }, includeKeyWhenDisabled: false)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(enabled.polishKey, "secret")
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
    @MainActor func testStockRecordingCuesAreDecodableAndNotClipped() throws {
        for cue in [RecordingCue.start, .stop] {
            let fallback = try XCTUnwrap(cue.url)
            let sound = try XCTUnwrap(NSSound(contentsOf: fallback, byReference: false))
            XCTAssertGreaterThan(sound.duration, 0.15)
            XCTAssertLessThan(sound.duration, 0.3)
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
    func testConservativeChineseCleanupAndPunctuation() {
        XCTAssertEqual(TranscriptCleanup.clean("嗯，今天我们我们测试 API,然后确认结果."), "今天我们测试 API，然后确认结果。")
        XCTAssertEqual(TranscriptCleanup.clean("那个功能就是我要的，然后再看看，好好说话，人人都可以。"), "那个功能就是我要的，然后再看看，好好说话，人人都可以。")
        XCTAssertEqual(TranscriptCleanup.clean("呃，"), "")
    }
    func testEnglishFillersAndMeaningfulWords() {
        XCTAssertEqual(TranscriptCleanup.clean("Um, we we need the API, uh, today."), "we need the API, today.")
        XCTAssertEqual(TranscriptCleanup.clean("The aluminum is 5 mm. Very very good. I had had enough."), "The aluminum is 5 mm. Very very good. I had had enough.")
    }
    func testNumbersURLsCodeAndMixedLanguageSurvive() {
        XCTAssertEqual(TranscriptCleanup.clean("版本 3.14，价格 0.5 元，访问 https://example.com/a_b"), "版本 3.14，价格 0.5 元，访问 https://example.com/a_b")
        XCTAssertEqual(TranscriptCleanup.clean("Hello, how are you? 你好!"), "Hello, how are you? 你好！")
        XCTAssertEqual(TranscriptCleanup.clean("明天 review 这个 PR"), "明天 review 这个 PR。")
        XCTAssertEqual(TranscriptCleanup.clean(" \n "), "")
    }
    func testTextOnlyAPIAndSeparateKey() async throws {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel(); StubProtocol.handler = nil }
        // Testing the endpoint must work without enabling polishing for dictation.
        let config = APIConfiguration(polishBaseURL: "https://example.com/v1", polishKey: "test-only-secret", polishModel: "configured-model", polish: false)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-secret")
            let body: Data
            if let data = request.httpBody { body = data }
            else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                body = data
            }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
            XCTAssertEqual(messages.last?["content"], "明天 review PR")
            XCTAssertFalse(String(data: body, encoding: .utf8)!.contains("input_audio"))
            XCTAssertEqual(json["model"] as? String, "configured-model")
            return (200, Data(#"{"choices":[{"message":{"content":"明天 review PR。"},"finish_reason":"stop"}]}"#.utf8))
        }
        let result = try await RemoteAPI.polish("明天 review PR", config: config, session: session)
        XCTAssertEqual(result, "明天 review PR。")
    }
    func testDeepSeekDisablesThinkingWithoutAffectingOtherProviders() throws {
        for (base, disables) in [("https://api.deepseek.com", true), ("https://example.com/v1", false)] {
            let config = APIConfiguration(polishBaseURL: base, polishKey: "test", polishModel: "deepseek-flash", polish: true)
            let request = try RemoteAPI.polishRequest("先测试 API，再测试识别", config: config)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            if disables { XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "disabled") }
            else { XCTAssertNil(json["thinking"]) }
            let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
            XCTAssertEqual(messages.last?["content"], "先测试 API，再测试识别")
            XCTAssertTrue(messages.first?["content"]?.contains("编号") == true)
            XCTAssertTrue(messages.first?["content"]?.contains("不强行列表") == true)
        }
    }
    func testPolishingRejectsEnglishTranslationAndAllowsEnglishEditing() throws {
        XCTAssertThrowsError(try RemoteAPI.preservingLanguage("你好，你怎么样？", source: "Hello, how are you?"))
        XCTAssertThrowsError(try RemoteAPI.preservingLanguage("明天审查代码。", source: "明天 review code"))
        XCTAssertThrowsError(try RemoteAPI.preservingLanguage("Hello，你好吗？", source: "Hello, how are you?"))
        XCTAssertEqual(try RemoteAPI.preservingLanguage("Hello, how are you?", source: "hello how are you"), "Hello, how are you?")
        XCTAssertEqual(try RemoteAPI.preservingLanguage("明天 review 这个 PR。", source: "明天 review 这个 PR"), "明天 review 这个 PR。")
        XCTAssertEqual(try RemoteAPI.preservingLanguage("- 先测试\n- 再确认", source: "先测试再确认"), "- 先测试\n- 再确认")
    }
    func testUnauthorizedDoesNotExposeSecrets() async throws {
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel(); StubProtocol.handler = nil }
        StubProtocol.handler = { _ in (401, Data("private response".utf8)) }
        let config = APIConfiguration(polishBaseURL: "https://example.com", polishKey: "test-only-secret", polishModel: "test", polish: true)
        do { _ = try await RemoteAPI.polish("hello", config: config, session: session); XCTFail("Should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("401")); XCTAssertFalse(error.localizedDescription.contains("test-only-secret")) }
    }
    func testIncompleteResultsAndUnsafeURLsRejected() throws {
        for json in [#"{"choices":[{"message":{"content":"unfinished"},"finish_reason":"length"}]}"#, #"{"choices":[{"message":{"content":""}}]}"#] {
            XCTAssertThrowsError(try RemoteAPI.chatText(Data(json.utf8)))
        }
        for base in ["http://example.com", "https://user:password@example.com", "https://example.com?secret=x"] {
            XCTAssertThrowsError(try APIConfiguration(polishBaseURL: base, polishKey: "test", polishModel: "test", polish: true).request("/chat/completions"))
        }
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
