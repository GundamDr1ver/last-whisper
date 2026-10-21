import Foundation
import AVFoundation
@preconcurrency import WhisperKit
import CoreML
import Combine

@MainActor
final class WhisperModelStatus: ObservableObject {
    static let shared = WhisperModelStatus()
    @Published var message = "正在准备 Whisper Large v3 Turbo…"
    @Published var ready = false
}

enum WhisperAssets {
    static let variant = "openai_whisper-large-v3-v20240930_turbo"
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["VOICEINPUT_MODEL_ROOT"] { return URL(fileURLWithPath: override) }
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app", app.deletingLastPathComponent().lastPathComponent == "build" {
            return app.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Models")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceInput/Models")
    }
}

actor WhisperRuntime {
    static let shared = WhisperRuntime()
    private var model: WhisperKit?
    private var loading: Task<Void, Error>?
    private var decoding = false
    func prepare() async throws {
        if model != nil { return }
        if let loading { try await loading.value; return }
        let task = Task<Void, Error> {
            let root = WhisperAssets.root
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var folder = root.appendingPathComponent(WhisperAssets.variant)
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path) {
                folder = try await WhisperKit.download(variant: WhisperAssets.variant, downloadBase: root) { progress in
                    Task { @MainActor in WhisperModelStatus.shared.message = String(format: "下载 Whisper 模型 %.0f%%", progress.fractionCompleted * 100) }
                }
            }
            await MainActor.run { WhisperModelStatus.shared.message = "正在加载 Whisper，首次设备编译可能需要几分钟…" }
            let configuration = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: root.appendingPathComponent("tokenizer"), computeOptions: ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine), verbose: false, prewarm: true, load: true, download: false)
            let kit = try await WhisperKit(configuration)
            self.model = kit
        }
        loading = task
        do {
            try await task.value; loading = nil
            await MainActor.run { WhisperModelStatus.shared.message = "Whisper Large v3 Turbo 已就绪 · 本机运行"; WhisperModelStatus.shared.ready = true }
        } catch {
            loading = nil
            await MainActor.run { WhisperModelStatus.shared.message = "Whisper 加载失败：\(error.localizedDescription)"; WhisperModelStatus.shared.ready = false }
            throw error
        }
    }
    func transcribe(file: URL) async throws -> String {
        let original = try AudioProcessor.loadAudioAsFloatArray(fromPath: file.path)
        let decision = try await SpeechGate.shared.analyze(original)
        guard decision.hasSpeech, let first = decision.ranges.first, let last = decision.ranges.last else { return "" }
        // Trim only leading/trailing noise; preserve pauses and all audio between spoken phrases.
        let samples = Array(original[first.lowerBound..<last.upperBound])
        try await prepare()
        while decoding { try await Task.sleep(for: .milliseconds(20)) }
        decoding = true
        defer { decoding = false }
        guard let model else { throw Failure("Whisper 尚未加载。") }
        let options = DecodingOptions(language: nil, temperature: 0, temperatureFallbackCount: 2,
            detectLanguage: true, skipSpecialTokens: true, withoutTimestamps: true,
            suppressBlank: true, compressionRatioThreshold: 2.4, logProbThreshold: -1,
            noSpeechThreshold: 0.6, concurrentWorkerCount: 1, chunkingStrategy: .vad)
        // No artificial vocabulary prompt or repeated truncation of the same utterance.
        let audio = samples.count < 19200 ? samples + Array(repeating: 0, count: 19200 - samples.count) : samples
        let results = try await model.transcribe(audioArray: audio, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
