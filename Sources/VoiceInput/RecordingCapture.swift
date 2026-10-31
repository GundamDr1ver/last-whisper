import Foundation
import AVFoundation

/// Convert microphone audio once; write privately on disk until recording stops.
final class RecordingCapture: @unchecked Sendable {
    let url: URL
    private var file: AVAudioFile?
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let lock = NSLock()
    private var accepting = false
    private var finished = false
    private let onFailure: @Sendable (Error) -> Void
    init(format: AVAudioFormat, url: URL, onFailure: @escaping @Sendable (Error) -> Void = { _ in }) throws {
        self.url = url; self.onFailure = onFailure
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw Failure("麦克风音频格式无法转换。") }
        self.target = target; self.converter = converter
        file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
    }
    func begin() { lock.lock(); defer { lock.unlock() }; accepting = true }
    func append(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, accepting else { return }
        do {
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw Failure("无法分配录音缓冲。") }
            var supplied = false; var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if status == .error { throw error ?? Failure("录音转换失败。") as NSError }
            try file?.write(from: output)
        } catch { finished = true; file = nil; onFailure(error) }
    }
    func finish() { lock.lock(); defer { lock.unlock() }; finished = true; file = nil }
}

enum AudioSamples {
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return [] }
        guard file.length <= 16000 * 60 * 60 * 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw Failure("录音过长或无法读取。") }
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

enum RecordingRecognition {
    static func transcribe(_ samples: [Float], settings: RecognitionSettings, key: String = "", session: URLSession = .shared) async throws -> String {
        let decision = try await SpeechGate.shared.analyze(samples)
        guard let first = decision.ranges.first, let last = decision.ranges.last else { return "" }
        let speech = Array(samples[first.lowerBound..<last.upperBound])
        try Task.checkCancellation()
        if settings.mode == .local { return try await LocalRecognition.shared.transcribe(speech, choice: settings.local) }
        return try await CloudRecognition.transcribe(speech, model: settings.cloud, key: key, session: session)
    }
}

enum PCM16 {
    static func encode(_ samples: [Float]) -> Data {
        var result = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-32768, min(32767, Int((sample.isFinite ? sample : 0) * 32767)))).littleEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        return result
    }
    static func wave(_ samples: [Float]) -> Data {
        let pcm = encode(samples)
        var data = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        number(UInt32(pcm.count + 36)); data.append(Data("WAVEfmt ".utf8)); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(16000)); number(UInt32(32000))
        number(UInt16(2)); number(UInt16(16)); data.append(Data("data".utf8)); number(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}
