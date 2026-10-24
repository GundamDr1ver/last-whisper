import XCTest
import AppKit
import AVFoundation
@testable import VoiceInput

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var contentType = "application/json"
    nonisolated(unsafe) static var fragmentSize: Int? = nil
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": Self.contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let size = Self.fragmentSize {
                for start in stride(from: 0, to: data.count, by: size) { client?.urlProtocol(self, didLoad: data.subdata(in: start..<min(start + size, data.count))) }
            } else { client?.urlProtocol(self, didLoad: data) }
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
            XCTAssertEqual(messages.map { $0["role"] }, ["system", "user", "assistant", "user", "assistant", "user", "assistant", "user", "assistant", "user"])
            XCTAssertTrue(messages.first?["content"]?.hasPrefix(RemoteAPI.polishInstructions) == true)
            XCTAssertEqual(messages.last?["content"], "<transcript>\n明天 review PR\n</transcript>")
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
            XCTAssertEqual(messages.last?["content"], "<transcript>\n先测试 API，再测试识别\n</transcript>")
            XCTAssertTrue(messages.first?["content"]?.contains("编号") == true)
            XCTAssertTrue(messages.first?["content"]?.contains("普通聊天和短句使用自然段") == true)
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

final class RecordingTests: XCTestCase {
    func testSelectionMigrationAndCustomModelsPersistWithoutSecrets() throws {
        let name = "RecordingTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("mimo", forKey: "cloudProvider")
        XCTAssertEqual(RecognitionSettings.load(defaults).cloud.id, "mimo")
        var selection = RecognitionSettings.load(defaults)
        selection.cloudModels.append(.init(id: "custom-one", title: "Other", endpoint: "https://example.com/v1/audio/transcriptions", model: "whisper-1"))
        selection.cloudID = "custom-one"; selection.save(defaults)
        XCTAssertEqual(RecognitionSettings.load(defaults), selection)
        XCTAssertEqual(selection.cloud.keyAccount, "asr-custom-one")
        XCTAssertNotEqual(CloudModel.qwen.keyAccount, CloudModel.mimo.keyAccount)
        XCTAssertFalse(String(decoding: defaults.data(forKey: "cloudModels")!, as: UTF8.self).contains("secret"))
    }
    func testCloudPresetsUseWholeRecordingAndAllowMixedLanguages() throws {
        for model in CloudModel.presets {
            let request = try CloudRecognition.request(samples: [0, 0.1], model: model, key: "test-secret")
            XCTAssertEqual(request.url?.absoluteString, model.endpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertEqual(body["model"] as? String, model.model)
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 1)
            if model.id == "qwen" { XCTAssertNil((body["asr_options"] as? [String: Any])?["language"]) }
            else { XCTAssertEqual((body["asr_options"] as? [String: Any])?["language"] as? String, "auto") }
        }
        XCTAssertEqual(CloudModel.qwen.model, "qwen3-asr-flash")
        XCTAssertThrowsError(try CloudRecognition.request(samples: [0], model: .mimo, key: ""))
    }
    func testCustomTranscriptionAndUnsafeURLs() throws {
        var model = CloudModel(id: "custom", title: "Other", endpoint: "https://example.com/v1/audio/transcriptions", model: "other-asr")
        let request = try CloudRecognition.request(samples: [0, 0.1], model: model, key: "test-secret")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("other-asr")); XCTAssertTrue(body.contains("recording.wav"))
        for url in ["http://example.com", "https://user:password@example.com", "https://example.com?key=secret"] {
            model.endpoint = url; XCTAssertThrowsError(try model.validatedURL())
        }
    }
    func testCloudReturnsSingleFinalResponse() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); StubProtocol.handler = nil }
        StubProtocol.handler = { _ in (200, Data(#"{"choices":[{"message":{"content":"Hello，你好！"},"finish_reason":"stop"}]}"#.utf8)) }
        let text = try await CloudRecognition.transcribe([0, 0.1], model: .mimo, key: "test-secret", session: session)
        XCTAssertEqual(text, "Hello，你好！")
        StubProtocol.handler = { _ in (200, Data(#"{"text":"Custom transcription."}"#.utf8)) }
        let custom = try await CloudRecognition.transcribe([0], model: .mimo, key: "test", session: session)
        XCTAssertEqual(custom, "Custom transcription.")
    }
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
    func testSilenceDoesNotReachCloud() async throws {
        let samples = Array(repeating: Float(0), count: 32000)
        let text = try await RecordingRecognition.transcribe(samples, settings: .init(mode: .cloud), key: "")
        XCTAssertEqual(text, "")
    }
    @MainActor func testPolishDraftRemainsIndependentFromModelSelection() async {
        let draft = SettingsDraft()
        XCTAssertFalse(draft.dirty)
        await draft.load(readKey: { _ in "" })
        XCTAssertFalse(draft.dirty)
        draft.polish = true
        draft.selection.mode = .cloud
        XCTAssertTrue(draft.polish); XCTAssertTrue(draft.dirty)
        draft.addCloudModel()
        let firstID = draft.selection.cloudID
        draft.cloudBinding(\.endpoint).wrappedValue = "https://example.com/v1/chat/completions"
        draft.cloudBinding(\.model).wrappedValue = "other-asr"
        draft.selection.cloudID = "mimo"
        draft.selection.cloudID = firstID
        XCTAssertEqual(draft.selection.cloud.model, "other-asr")
    }
}

private final class MemoryKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func write(_ key: String, account: String) -> Bool { lock.lock(); defer { lock.unlock() }; values[account] = key; return true }
    func read(_ account: String) -> String { lock.lock(); defer { lock.unlock() }; return values[account] ?? "" }
}
final class SettingsAndDownloadTests: XCTestCase {
    @MainActor func testCustomKeyAutoUpdateAndSaveBecomesClean() async throws {
        let keys = MemoryKeys()
        let draft = SettingsDraft(writeKey: { keys.write($0, account: $1) })
        await draft.load(readKey: { _ in "" })
        draft.selection.mode = .cloud; draft.polish = false
        draft.addCloudModel()
        let account = draft.selection.cloud.keyAccount
        draft.cloudBinding(\.endpoint).wrappedValue = "https://example.com/v1/chat/completions"
        draft.cloudBinding(\.model).wrappedValue = "test-asr"
        draft.editKey("old", account: account)
        draft.editKey("new", account: account)
        draft.editKey("mimo-key", account: CloudModel.mimo.keyAccount)
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertEqual(keys.read(account), "new")
        XCTAssertEqual(keys.read(CloudModel.mimo.keyAccount), "mimo-key")
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(draft.dirty)
        draft.save(defaults: defaults)
        XCTAssertFalse(draft.dirty)
        XCTAssertEqual(RecognitionSettings.load(defaults).cloud.model, "test-asr")
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
    @MainActor func testDeleteCustomModelAndPreservePresets() async throws {
        let draft = SettingsDraft()
        await draft.load(readKey: { _ in "" })
        draft.selection = RecognitionSettings()
        draft.removeCloudModel()
        XCTAssertEqual(draft.selection.cloudModels, CloudModel.presets)
        draft.addCloudModel()
        let first = draft.selection.cloudID
        draft.addCloudModel()
        let second = draft.selection.cloudID
        draft.removeCloudModel()
        XCTAssertFalse(draft.selection.cloudModels.contains { $0.id == second })
        XCTAssertTrue(draft.selection.cloudModels.contains { $0.id == first })
        XCTAssertEqual(draft.selection.cloudID, CloudModel.qwen.id)
        draft.selection.cloudID = first
        draft.removeCloudModel()
        XCTAssertEqual(draft.selection.cloudModels, CloudModel.presets)
        XCTAssertFalse(draft.canRemoveCloudModel)
        draft.selection.mode = .local; draft.polish = false
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        draft.save(defaults: defaults)
        XCTAssertEqual(RecognitionSettings.load(defaults).cloudModels, CloudModel.presets)
        XCTAssertFalse(draft.dirty)
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
