import Foundation
import Combine
import CryptoKit

enum RecognitionMode: String, CaseIterable, Codable {
    case local, cloud
    var title: String { self == .local ? "本地模型" : "云端模型" }
}
struct CloudModel: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var endpoint: String
    var model: String
    var keyAccount: String { "asr-" + id }
    static let qwen = Self(id: "qwen", title: "Qwen ASR", endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", model: "qwen3-asr-flash")
    static let mimo = Self(id: "mimo", title: "MiMo ASR", endpoint: "https://api.xiaomimimo.com/v1/chat/completions", model: "mimo-v2.5-asr")
    static var presets: [Self] { [.qwen, .mimo] }
    func validatedURL() throws -> URL {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil, url.query == nil, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("请填写有效的 HTTPS 接口地址和模型名称。") }
        return url
    }
}
enum LocalModel: String, CaseIterable, Codable {
    case qwen, vibevoice, whisper
    var title: String {
        switch self {
        case .qwen: return "Qwen3-ASR 1.7B · Q8"
        case .vibevoice: return "VibeVoice 1.5B"
        case .whisper: return "Whisper Large v3 Turbo · Q8"
        }
    }
    var detail: String {
        switch self { case .qwen: return "2.47 GB"; case .vibevoice: return "3.34 GB"; case .whisper: return "874 MB" }
    }
    var family: String {
        switch self { case .qwen: return "qwen3_asr"; case .vibevoice: return "vibevoice_asr_streaming"; case .whisper: return "whisper" }
    }
    var file: String {
        switch self {
        case .qwen: return "qwen3-asr-1.7b-q8_0.gguf"
        case .vibevoice: return "vibevoice-asr-streaming-1.5b-q8_0.gguf"
        case .whisper: return "ggml-large-v3-turbo-q8_0.bin"
        }
    }
    var downloadURL: URL {
        let path: String
        switch self {
        case .qwen: path = "audio-cpp/audio.cpp-gguf/resolve/main/Qwen3-ASR-1.7B-GGUF/"
        case .vibevoice: path = "christopherthompson81/VibeVoice-ASR-Streaming-1.5B-GGUF/resolve/main/"
        case .whisper: path = "ggerganov/whisper.cpp/resolve/main/"
        }
        return URL(string: "https://huggingface.co/" + path + file + "?download=true")!
    }
    var bytes: Int64 {
        switch self { case .qwen: return 2_473_017_600; case .vibevoice: return 3_343_199_488; case .whisper: return 874_188_075 }
    }
    var sha256: String {
        switch self {
        case .qwen: return "3bc2462eca3a3a8f56abcd860d0943ffdc0546547dde55a9d08589607d6f3936"
        case .vibevoice: return "1a92c0f6c72439d58dedaaff96bb77264802618bd577f58cc0176f47bae5180d"
        case .whisper: return "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"
        }
    }
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["VOICEINPUT_MODEL_ROOT"] { return URL(fileURLWithPath: path) }
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app", app.deletingLastPathComponent().lastPathComponent == "build" {
            let development = app.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Models")
            if FileManager.default.fileExists(atPath: development.path) { return development }
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceInput/Models")
    }
    var url: URL { Self.root.appendingPathComponent(file) }
    var installed: Bool { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) == bytes } == true }
    func validate(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(); var count: Int64 = 0
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { count += Int64(data.count); hash.update(data: data) }
        guard count == bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw Failure("模型文件校验失败，请重新下载。")
        }
    }
}

struct RecognitionSettings: Equatable, Sendable {
    var mode: RecognitionMode = .local
    var local: LocalModel = .qwen
    var cloudID = "qwen"
    var cloudModels = CloudModel.presets
    var cloud: CloudModel { cloudModels.first(where: { $0.id == cloudID }) ?? .qwen }
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        var settings = Self()
        settings.mode = RecognitionMode(rawValue: defaults.string(forKey: "recognitionMode") ?? "") ?? .local
        settings.local = LocalModel(rawValue: defaults.string(forKey: "localModel") ?? "") ?? .qwen
        if let data = defaults.data(forKey: "cloudModels"), let models = try? JSONDecoder().decode([CloudModel].self, from: data), !models.isEmpty {
            settings.cloudModels = models
        }
        settings.cloudID = defaults.string(forKey: "cloudModelID") ?? defaults.string(forKey: "cloudProvider") ?? "qwen"
        if !settings.cloudModels.contains(where: { $0.id == settings.cloudID }) { settings.cloudID = settings.cloudModels[0].id }
        return settings
    }
    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: "recognitionMode")
        defaults.set(local.rawValue, forKey: "localModel")
        defaults.set(cloudID, forKey: "cloudModelID")
        defaults.set(try? JSONEncoder().encode(cloudModels), forKey: "cloudModels")
        NotificationCenter.default.post(name: .recognitionSettingsChanged, object: nil)
    }
}
extension Notification.Name { static let recognitionSettingsChanged = Notification.Name("recognitionSettingsChanged") }

final class ModelFileTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var cancelled = false
    private var lastPercent = -1
    private let expectedBytes: Int64
    private let update: @Sendable (Double) -> Void
    init(expectedBytes: Int64, update: @escaping @Sendable (Double) -> Void) { self.expectedBytes = expectedBytes; self.update = update }
    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForResource = 24 * 60 * 60
                configuration.timeoutIntervalForRequest = 90
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: request); self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let value = Double(totalBytesWritten) / Double(max(1, expectedBytes))
        let percent = Int(value * 100)
        if percent != lastPercent { lastPercent = percent; update(min(1, value)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceInput-download-" + UUID().uuidString)
        do {
            guard let response = downloadTask.response else { throw Failure("下载服务器没有返回响应。") }
            try FileManager.default.moveItem(at: location, to: owned)
            complete(.success((owned, response)))
        } catch { try? FileManager.default.removeItem(at: owned); complete(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if let error { complete(.failure(error)) } }
    private func complete(_ result: Result<(URL, URLResponse), Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil
        let session = session; self.session = nil; task = nil; lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

@MainActor final class ModelDownloads: ObservableObject {
    static let shared = ModelDownloads()
    @Published private(set) var progress: [LocalModel: Double] = [:]
    @Published private(set) var messages: [LocalModel: String] = [:]
    @Published private(set) var revision = 0
    private var tasks: [LocalModel: Task<Void, Never>] = [:]
    func download(_ model: LocalModel) {
        guard tasks[model] == nil, !model.installed else { return }
        progress[model] = 0; messages[model] = "正在连接…"
        tasks[model] = Task {
            defer { tasks[model] = nil; progress[model] = nil; revision += 1 }
            do {
                let update: @Sendable (Double) -> Void = { value in
                    Task { @MainActor in
                        guard self.tasks[model] != nil else { return }
                        self.progress[model] = min(0.99, value)
                        self.messages[model] = "下载 \(Int(value * 100))%"
                    }
                }
                let (temp, response) = try await Self.fetch(model.downloadURL, expectedBytes: model.bytes, update: update)
                defer { try? FileManager.default.removeItem(at: temp) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw Failure("模型下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)），请重试。")
                }
                messages[model] = "正在校验完整性…"
                let validation = Task.detached(priority: .utility) { try model.validate(temp) }
                try await validation.value
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: LocalModel.root, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: model.url.path) { try FileManager.default.removeItem(at: model.url) }
                try FileManager.default.moveItem(at: temp, to: model.url)
                messages[model] = "已下载并校验"
                NotificationCenter.default.post(name: .recognitionSettingsChanged, object: nil)
            } catch {
                messages[model] = Task.isCancelled ? "下载已取消" : "下载失败：\(error.localizedDescription)"
            }
        }
    }
    nonisolated static func fetch(_ url: URL, expectedBytes: Int64, update: @escaping @Sendable (Double) -> Void) async throws -> (URL, URLResponse) {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "request", value: UUID().uuidString)]
            var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 90
            do {
                let result = try await ModelFileTransfer(expectedBytes: expectedBytes, update: update).download(request)
                let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 { return result }
                try? FileManager.default.removeItem(at: result.0)
                guard [403, 408, 429, 500, 502, 503, 504].contains(code), attempt < 2 else { throw Failure("模型下载失败（HTTP \(code)）。") }
            } catch {
                try Task.checkCancellation()
                guard attempt < 2, (error as? URLError) != nil else { throw error }
            }
            try await Task.sleep(for: .seconds(attempt + 1))
        }
        throw Failure("模型下载失败，请检查网络后重试。")
    }
    func cancel(_ model: LocalModel) { tasks[model]?.cancel() }
}
