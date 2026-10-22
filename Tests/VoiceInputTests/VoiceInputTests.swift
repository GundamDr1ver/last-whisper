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

final class StreamingTests: XCTestCase {
    func testDefaultsAndSavedSelectionAreIndependentFromLegacyPolish() throws {
        let name = "StreamingTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "batchPolishEnabled")
        XCTAssertEqual(RecognitionSettings.load(defaults).mode, .local)
        XCTAssertEqual(RecognitionSettings.load(defaults).local, .vibevoice)
        let selected = RecognitionSettings(mode: .cloud, local: .qwen, provider: .mimo)
        selected.save(defaults)
        XCTAssertEqual(RecognitionSettings.load(defaults), selected)
        XCTAssertNotEqual(CloudProvider.qwen.keyAccount, CloudProvider.mimo.keyAccount)
        XCTAssertNotEqual(CloudProvider.mimo.keyAccount, "polish-key")
    }
    func testPartialReplacementIsScopedToItemAndLateDraftCannotReplaceFinal() {
        var transcript = StreamingTranscript()
        transcript.update(id: "first", text: "第一句。", final: true)
        transcript.update(id: "second", text: "How", final: false)
        transcript.update(id: "second", text: "How are you?", final: false)
        XCTAssertEqual(transcript.text, "第一句。 How are you?")
        transcript.update(id: "second", text: "How are you? 你好！", final: true)
        transcript.update(id: "second", text: "How", final: false)
        transcript.update(id: "first", text: "第一句确认。", final: true)
        XCTAssertEqual(transcript.text, "第一句确认。 How are you? 你好！")
        XCTAssertEqual(transcript.order.count, 2)
    }
    func testWaveHeaderAndPCMClipping() {
        let samples: [Float] = [0, 1, -1, .nan, .infinity, 2, -2]
        let wave = PCM16.wave(samples)
        XCTAssertEqual(String(decoding: wave.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wave[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(wave.count, 44 + samples.count * 2)
        let encoded = PCM16.encode(samples)
        XCTAssertEqual(Array(encoded.prefix(6)), [0, 0, 255, 127, 1, 128])
    }
    func testMiMoUsesAudioChunksAndSSEWithoutPolishOrLanguageRestriction() throws {
        let request = try MiMoStreaming.request(samples: [0, 0.1], key: "test-secret")
        XCTAssertEqual(request.url?.absoluteString, "https://api.xiaomimimo.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "mimo-v2.5-asr")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["asr_options"] as? [String: String])?["language"], "auto")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertThrowsError(try MiMoStreaming.request(samples: [0], key: ""))
    }
    func testQwenUsesRealtimeEndpointAndIsolatedKey() {
        let request = QwenStreaming.request(key: "test-qwen-key")
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "dashscope.aliyuncs.com")
        XCTAssertTrue(request.url?.query?.contains("qwen3-asr-flash-realtime") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-qwen-key")
    }
    func testAudioConversionProducesHalfSecondChunksAndFinalTail() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let capture = try StreamingCapture(format: format)
        for _ in 0..<12 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            buffer.frameLength = 4800
            buffer.floatChannelData![0].initialize(repeating: 0.1, count: 4800)
            capture.append(buffer)
        }
        capture.finish()
        var sizes: [Int] = []
        for try await chunk in capture.stream { sizes.append(chunk.count) }
        XCTAssertEqual(sizes.prefix(2), [8000, 8000])
        XCTAssertGreaterThan(sizes.reduce(0,+), 18800)
        XCTAssertLessThanOrEqual(sizes.reduce(0,+), 19200)
    }
    func testBoundedAudioBufferReportsOverflowInsteadOfSilentlyDroppingSpeech() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let capture = try StreamingCapture(format: format)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000; buffer.floatChannelData![0].initialize(repeating: 0, count: 8000)
        for _ in 0..<70 { capture.append(buffer) }
        do { for try await _ in capture.stream {}; XCTFail("Must fail rather than lose audio") }
        catch { XCTAssertTrue(error.localizedDescription.contains("跟不上")) }
    }
    @MainActor func testSettingsSaveButtonTracksDraftAndReturnsCleanAfterSave() async {
        let draft = SettingsDraft()
        await draft.load(readKey: { _ in "" })
        XCTAssertFalse(draft.dirty)
        draft.polishModel += "-changed"
        XCTAssertTrue(draft.dirty)
        draft.polishModel.removeLast("-changed".count)
        XCTAssertFalse(draft.dirty)
    }
}

private final class FakeCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [String: String] = [:]
    func write(_ key: String, account: String) -> Bool { lock.lock(); defer { lock.unlock() }; saved[account] = key; return true }
    func read(_ account: String) -> String { lock.lock(); defer { lock.unlock() }; return saved[account] ?? "" }
}
final class CredentialAndSilenceTests: XCTestCase {
    @MainActor func testCloudKeySwitchAndUpdateNeverOverwriteAnotherProvider() async throws {
        let store = FakeCredentials()
        let draft = SettingsDraft(writeKey: { key, account in store.write(key, account: account) })
        await draft.load(readKey: { account in account == CloudProvider.mimo.keyAccount ? "existing-mimo" : "" })
        draft.selection.provider = .mimo
        XCTAssertEqual(draft.keyBinding(CloudProvider.mimo.keyAccount).wrappedValue, "existing-mimo")
        draft.editKey("qwen-old", account: CloudProvider.qwen.keyAccount)
        draft.editKey("qwen-new", account: CloudProvider.qwen.keyAccount)
        draft.selection.provider = .mimo
        draft.editKey("mimo-new", account: CloudProvider.mimo.keyAccount)
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertEqual(store.read(CloudProvider.qwen.keyAccount), "qwen-new")
        XCTAssertEqual(store.read(CloudProvider.mimo.keyAccount), "mimo-new")
        XCTAssertEqual(draft.keys[CloudProvider.qwen.keyAccount], "qwen-new")
        draft.editKey("", account: CloudProvider.mimo.keyAccount)
        XCTAssertEqual(store.read(CloudProvider.mimo.keyAccount), "mimo-new")
        XCTAssertTrue(draft.savingKeys.isEmpty)
    }
    func testSilenceAndStartCueDoNotSubmitCloudAudio() async throws {
        let cue = try XCTUnwrap(RecordingCue.start.url)
        let cueSamples = try AudioSamples.load(cue)
        let samples = cueSamples + Array(repeating: Float(0), count: 48000)
        let stream = AsyncThrowingStream<[Float], Error> { continuation in
            for offset in stride(from: 0, to: samples.count, by: 8000) {
                continuation.yield(Array(samples[offset..<min(offset + 8000, samples.count)]))
            }
            continuation.finish()
        }
        // An empty key makes any attempted API submission fail locally; no network can be used.
        let text = try await StreamingRecognition.run(stream, settings: .init(mode: .cloud, local: .vibevoice, provider: .mimo), key: "", update: { _ in XCTFail("Noise must not produce a transcript") })
        XCTAssertEqual(text, "")
    }
}
