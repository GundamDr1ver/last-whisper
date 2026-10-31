import XCTest
import Foundation
@testable import VoiceInput

private final class ASRStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, text) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private final class TestKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func write(_ key: String, account: String) -> Bool { lock.lock(); defer { lock.unlock() }; values[account] = key; return true }
    func read(_ account: String) -> String { lock.lock(); defer { lock.unlock() }; return values[account] ?? "" }
}
final class CloudAndDeletionTests: XCTestCase {
    func testPresetsSendAudioOnlyAndDoNotForceChinese() throws {
        for model in CloudModel.presets {
            let request = try CloudRecognition.request(samples: [0, 0.1], model: model, key: "fake-key")
            XCTAssertEqual(request.url?.absoluteString, model.endpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-key")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, model.model)
            XCTAssertEqual(body["stream"] as? Bool, false)
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 1)
            XCTAssertEqual(messages.first?["role"] as? String, "user")
            let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
            XCTAssertEqual(content.count, 1)
            XCTAssertEqual(content[0]["type"] as? String, "input_audio")
            let data = try XCTUnwrap((content[0]["input_audio"] as? [String: String])?["data"])
            XCTAssertTrue(data.hasPrefix("data:audio/wav;base64,"))
            if model.id == "qwen" { XCTAssertNil((body["asr_options"] as? [String: Any])?["language"]) }
            else { XCTAssertEqual((body["asr_options"] as? [String: Any])?["language"] as? String, "auto") }
        }
    }
    func testCustomMultipartAndValidation() throws {
        var model = CloudModel(id: "test", title: "Test", endpoint: "https://example.invalid/v1/audio/transcriptions", model: "whisper-1")
        let request = try CloudRecognition.request(samples: [0], model: model, key: "fake")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")!.contains("multipart/form-data"))
        XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("whisper-1"))
        for url in ["http://example.com", "https://key:secret@example.com", "https://example.com?key=x"] {
            model.endpoint = url
            XCTAssertThrowsError(try model.validatedURL())
        }
        XCTAssertThrowsError(try CloudRecognition.request(samples: [0], model: .qwen, key: ""))
    }
    func testSingleRecognitionResponseErrorsAndSilence() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ASRStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ASRStub.handler = nil }
        var requests = 0
        ASRStub.handler = { _ in requests += 1; return (200, #"{"choices":[{"message":{"content":"Hello，你好！"},"finish_reason":"stop"}]}"#) }
        let settings = RecognitionSettings(mode: .cloud)
        let silence = try await RecordingRecognition.transcribe(Array(repeating: Float(0), count: 32000), settings: settings, key: "fake", session: session)
        XCTAssertEqual(silence, ""); XCTAssertEqual(requests, 0)
        let output = try await CloudRecognition.transcribe([0], model: .mimo, key: "fake", session: session)
        XCTAssertEqual(output, "Hello，你好！"); XCTAssertEqual(requests, 1)
        ASRStub.handler = { _ in (200, #"{"text":"Custom result."}"#) }
        let custom = try await CloudRecognition.transcribe([0], model: .qwen, key: "fake", session: session)
        XCTAssertEqual(custom, "Custom result.")
        for response in [#"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#, #"{"choices":[{"message":{"content":""}}]}"#] {
            XCTAssertThrowsError(try CloudRecognition.chatText(Data(response.utf8)))
        }
        ASRStub.handler = { _ in (401, "private-response") }
        do { _ = try await CloudRecognition.transcribe([0], model: .qwen, key: "fake-secret", session: session); XCTFail("Must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("401")); XCTAssertFalse(error.localizedDescription.contains("fake-secret")); XCTAssertFalse(error.localizedDescription.contains("private-response")) }
    }
    @MainActor func testCloudEditingKeyUpdatesAndSaveState() async throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keys = TestKeys()
        let draft = SettingsDraft(writeKey: { keys.write($0, account: $1) })
        draft.load(defaults: defaults)
        await draft.loadKey(readKey: { _ in XCTFail("Local mode must not read keys"); return "" })
        XCTAssertFalse(draft.dirty)
        draft.selection.mode = .cloud
        draft.addCloudModel()
        let id = draft.selection.cloudID, account = draft.selection.cloud.keyAccount
        draft.cloudBinding(\.endpoint).wrappedValue = "https://example.invalid/v1/audio/transcriptions"
        draft.cloudBinding(\.model).wrappedValue = "test-asr"
        draft.editKey("old", account: account); draft.editKey("new", account: account)
        draft.editKey("mimo", account: CloudModel.mimo.keyAccount)
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertEqual(keys.read(account), "new")
        XCTAssertEqual(keys.read(CloudModel.mimo.keyAccount), "mimo")
        draft.selection.cloudID = "mimo"
        await draft.loadKey(readKey: { keys.read($0) })
        XCTAssertEqual(draft.keys[CloudModel.mimo.keyAccount], "mimo")
        draft.selection.cloudID = id
        XCTAssertEqual(draft.keys[account], "new")
        XCTAssertTrue(draft.dirty)
        draft.save(defaults: defaults)
        XCTAssertFalse(draft.dirty)
        XCTAssertEqual(RecognitionSettings.load(defaults), draft.selection)
        XCTAssertFalse(String(decoding: defaults.data(forKey: "cloudModels")!, as: UTF8.self).contains("new"))
        draft.removeCloudModel()
        XCTAssertTrue(draft.dirty)
        XCTAssertFalse(draft.selection.cloudModels.contains { $0.id == id })
        XCTAssertEqual(keys.read(account), "new")
        draft.removeCloudModel()
        XCTAssertEqual(draft.selection.cloudModels, CloudModel.presets)
    }
    @MainActor func testDeletePersistsAutoDownloadSuppressionAndMissingFileFeedback() async throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("fixture".utf8).write(to: directory.appendingPathComponent(LocalModel.qwen.file))
        let downloads = ModelDownloads()
        await downloads.remove(.qwen, directory: directory, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: "modelDeleted-qwen"))
        XCTAssertEqual(downloads.messages[.qwen], "已删除，可重新下载")
        XCTAssertFalse(downloads.removing.contains(.qwen))
        await downloads.remove(.whisper, directory: directory, defaults: defaults)
        XCTAssertTrue(downloads.messages[.whisper]?.hasPrefix("删除失败") == true)
        XCTAssertFalse(defaults.bool(forKey: "modelDeleted-whisper"))
    }
    func testDeleteOnlyRequestedModelFileAndReportMissingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for model in LocalModel.allCases { try Data("fixture".utf8).write(to: directory.appendingPathComponent(model.file)) }
        let recognizer = LocalRecognition()
        try await recognizer.remove(.whisper, directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(LocalModel.whisper.file).path))
        for model in [LocalModel.qwen, .vibevoice] { XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(model.file).path)) }
        do { try await recognizer.remove(.whisper, directory: directory); XCTFail("Must report deletion error") } catch {}
    }
}
