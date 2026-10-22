import Foundation
import Combine
import CryptoKit

enum RecognitionMode: String, CaseIterable, Codable {
    case local, cloud
    var title: String { self == .local ? "本地模型" : "云端模型" }
}
enum CloudProvider: String, CaseIterable, Codable {
    case qwen, mimo
    var title: String { self == .qwen ? "Qwen ASR · 实时流式" : "MiMo ASR · 分段流式" }
    var model: String { self == .qwen ? "qwen3-asr-flash-realtime" : "mimo-v2.5-asr" }
    var keyAccount: String { "asr-" + rawValue }
}
enum LocalModel: String, CaseIterable, Codable {
    case vibevoice, qwen
    var title: String { self == .vibevoice ? "VibeVoice-ASR-Streaming 1.5B" : "Qwen3-ASR 0.6B" }
    var detail: String { self == .vibevoice ? "原生流式 · 中英混合 · 3.34 GB" : "分块流式 · 中英混合 · 1.15 GB" }
    var family: String { self == .vibevoice ? "vibevoice_asr_streaming" : "qwen3_asr" }
    var file: String { self == .vibevoice ? "vibevoice-asr-streaming-1.5b-q8_0.gguf" : "qwen3-asr-0.6b-q8_0.gguf" }
    var downloadURL: URL {
        let path = self == .vibevoice ? "christopherthompson81/VibeVoice-ASR-Streaming-1.5B-GGUF/resolve/main/" : "audio-cpp/audio.cpp-gguf/resolve/main/Qwen3-ASR-0.6B-GGUF/"
        return URL(string: "https://huggingface.co/" + path + file + "?download=true")!
    }
    var bytes: Int64 { self == .vibevoice ? 3_343_199_488 : 1_151_279_968 }
    var sha256: String { self == .vibevoice ? "1a92c0f6c72439d58dedaaff96bb77264802618bd577f58cc0176f47bae5180d" : "5c53bbb9a6b2ade85c16c290c560658ca18b78a23c323378528f1f945683fcbe" }
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
    var local: LocalModel = .vibevoice
    var provider: CloudProvider = .qwen
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        Self(mode: RecognitionMode(rawValue: defaults.string(forKey: "recognitionMode") ?? "") ?? .local,
             local: LocalModel(rawValue: defaults.string(forKey: "localModel") ?? "") ?? .vibevoice,
             provider: CloudProvider(rawValue: defaults.string(forKey: "cloudProvider") ?? "") ?? .qwen)
    }
    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: "recognitionMode")
        defaults.set(local.rawValue, forKey: "localModel")
        defaults.set(provider.rawValue, forKey: "cloudProvider")
        NotificationCenter.default.post(name: .recognitionSettingsChanged, object: nil)
    }
}
extension Notification.Name { static let recognitionSettingsChanged = Notification.Name("recognitionSettingsChanged") }

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Double) -> Void
    private var lastPercent = -1
    init(_ update: @escaping @Sendable (Double) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let percent = Int(value * 100)
            if percent != lastPercent { lastPercent = percent; update(value) }
        }
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
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            configuration.timeoutIntervalForRequest = 90
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel(); tasks[model] = nil; progress[model] = nil; revision += 1 }
            do {
                let delegate = DownloadProgress { value in
                    Task { @MainActor in
                        guard self.tasks[model] != nil else { return }
                        self.progress[model] = min(0.99, value)
                        self.messages[model] = "下载 \(Int(value * 100))%"
                    }
                }
                let (temp, response) = try await session.download(from: model.downloadURL, delegate: delegate)
                defer { try? FileManager.default.removeItem(at: temp) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("模型服务器未正常响应。") }
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
    func cancel(_ model: LocalModel) { tasks[model]?.cancel() }
}
