import Foundation
import AVFoundation

/// The tap converts once and hands off bounded 0.5-second chunks, without disk recordings.
final class StreamingCapture: @unchecked Sendable {
    let stream: AsyncThrowingStream<[Float], Error>
    private let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let lock = NSLock()
    private var pending: [Float] = []
    private var finished = false
    private let onFailure: @Sendable (Error) -> Void
    init(format: AVAudioFormat, onFailure: @escaping @Sendable (Error) -> Void = { _ in }) throws {
        self.onFailure = onFailure
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw Failure("麦克风格式无法转换为识别音频。") }
        self.target = target; self.converter = converter
        var saved: AsyncThrowingStream<[Float], Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { saved = $0 }
        continuation = saved
    }
    func append(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { fail(Failure("无法分配音频缓冲。")); return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if status == .error { fail(error ?? Failure("麦克风音频转换失败。") as NSError); return }
        if let samples = output.floatChannelData?[0] {
            pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
            while pending.count >= 8000 {
                if case .dropped = continuation.yield(Array(pending.prefix(8000))) { fail(Failure("识别速度跟不上录音，已停止以避免遗漏语音；已识别内容保留。")); return }
                pending.removeFirst(8000)
            }
        }
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if !pending.isEmpty, case .dropped = continuation.yield(pending) { fail(Failure("识别缓冲已满，未输入不完整内容。")); return }
        pending.removeAll(); finished = true; continuation.finish()
    }
    func cancel() { lock.lock(); defer { lock.unlock() }; fail(CancellationError()) }
    private func fail(_ error: Error) { guard !finished else { return }; finished = true; pending.removeAll(); continuation.finish(throwing: error); onFailure(error) }
}

enum StreamingRecognition {
    static func run(_ stream: AsyncThrowingStream<[Float], Error>, settings: RecognitionSettings, key: String, update: @escaping @Sendable (String) async -> Void) async throws -> String {
        let token = UUID()
        let qwen = QwenStreaming(update: update)
        let mimo = MiMoStreaming(key: key, update: update)
        var started = false
        var hasSpeech = false
        var trailing = 0
        var preroll: [Float] = []
        do {
            if settings.mode == .local { try await LocalStreaming.shared.start(settings.local, token: token); started = true }
            for try await samples in stream {
                try Task.checkCancellation()
                let speech = try await SpeechGate.shared.analyze(preroll + samples).hasSpeech
                var send: [Float] = []
                if speech {
                    hasSpeech = true
                    send = preroll + samples; preroll.removeAll(); trailing = 32000
                } else if trailing > 0 {
                    send = samples; trailing -= samples.count
                } else { preroll = Array(samples.suffix(8000)) }
                if !send.isEmpty {
                    if !started {
                        if settings.provider == .qwen { try await qwen.start(key: key) }
                        started = true
                    }
                    if settings.mode == .local { await update(try await LocalStreaming.shared.push(send, token: token)) }
                    else if settings.provider == .qwen { try await qwen.push(send) }
                    else { try await mimo.push(send) }
                } else if settings.mode == .cloud, settings.provider == .mimo { try await mimo.boundary() }
            }
            try Task.checkCancellation()
            guard started, hasSpeech else { await LocalStreaming.shared.reset(token: token); await mimo.cancel(); return "" }
            if settings.mode == .local { return try await LocalStreaming.shared.finish(token: token) }
            if settings.provider == .qwen { return try await qwen.finish() }
            return try await mimo.finish()
        } catch {
            await qwen.cancel(); await mimo.cancel()
            if settings.mode == .local { await LocalStreaming.shared.reset(token: token) }
            throw error
        }
    }
}

enum AudioSamples {
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length < 16000 * 60 * 10,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw Failure("测试音频过长或无法读取。") }
        try file.read(into: buffer)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: buffer.format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 32) else { throw Failure("音频格式无法转换。") }
        var used = false; var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if used { state.pointee = .endOfStream; return nil }
            used = true; state.pointee = .haveData; return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { throw error ?? Failure("音频转换失败。") as NSError }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
