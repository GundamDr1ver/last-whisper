// CoreML input/output handling adapted from paean-ai/silero-vad-swift (MIT).
// Copyright (c) 2026 Pæan™. See SILERO-LICENSE.txt and SILERO-THIRD-PARTY-NOTICES.txt.
import Foundation
import CoreML

struct SpeechDecision: Sendable {
    let ranges: [Range<Int>]
    let peakProbability: Float
    var hasSpeech: Bool { !ranges.isEmpty }
}

/// Temporal evidence prevents a lone click or the short start cue from opening the gate.
enum SpeechEvidence {
    static let stride = 512 // 32 ms at 16 kHz; the model also needs 64 previous context samples.
    static func decide(probabilities: [Float], sampleCount: Int) -> SpeechDecision {
        var ranges: [Range<Int>] = []
        var start: Int?
        var lastVoice = 0
        var highFrames = 0
        var peak: Float = 0
        var runPeak: Float = 0
        func finish() {
            if let start, highFrames >= 4, runPeak >= 0.8 {
                let lower = max(0, start * stride - 3200)
                let upper = min(sampleCount, (lastVoice + 1) * stride + 4800)
                if lower < upper {
                    if let last = ranges.last, lower <= last.upperBound {
                        ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upper)
                    } else { ranges.append(lower..<upper) }
                }
            }
            start = nil; highFrames = 0; runPeak = 0
        }
        for (index, raw) in probabilities.enumerated() {
            let probability = raw.isFinite ? max(0, min(1, raw)) : 0
            peak = max(peak, probability)
            if probability >= 0.6 {
                if start == nil { start = index }
                highFrames += 1; lastVoice = index; runPeak = max(runPeak, probability)
            } else if start != nil, probability >= 0.35 {
                lastVoice = index
            } else if start != nil, index - lastVoice >= 5 { finish() }
        }
        finish()
        return SpeechDecision(ranges: ranges, peakProbability: peak)
    }
}

/// Confined to one actor: the model and recurrent states are never used concurrently.
actor SpeechGate {
    static let shared = SpeechGate()
    private var model: MLModel?
    func prepare() throws {
        guard model == nil else { return }
        guard let url = Bundle.module.url(forResource: "silero_vad", withExtension: "mlmodelc", subdirectory: "Resources") else {
            throw Failure("人声检测模型缺失，本次不会调用识别或润色服务。")
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: url, configuration: config)
    }
    func analyze(_ samples: [Float]) throws -> SpeechDecision {
        guard samples.count >= 2048, samples.contains(where: { $0.isFinite && abs($0) > 0.00001 }) else {
            return SpeechDecision(ranges: [], peakProbability: 0)
        }
        try prepare()
        guard let model else { throw Failure("人声检测尚未就绪，本次不会调用 API。") }
        // Fresh zeroed LSTM state for EACH recording, never inherited from previous speech.
        var hidden = try zeroState()
        var cell = try zeroState()
        let input = try MLMultiArray(shape: [1, 576], dataType: .float32)
        let values = input.dataPointer.bindMemory(to: Float.self, capacity: 576)
        var probabilities: [Float] = []
        for offset in stride(from: 0, to: samples.count, by: SpeechEvidence.stride) {
            // 64 context samples + 512 new samples. Do not skip audio between frames.
            for index in 0..<576 {
                let source = offset - 64 + index
                values[index] = source >= 0 && source < samples.count && samples[source].isFinite ? samples[source] : 0
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": MLFeatureValue(multiArray: input),
                "hidden_state": MLFeatureValue(multiArray: hidden),
                "cell_state": MLFeatureValue(multiArray: cell)
            ])
            let output = try model.prediction(from: provider)
            guard let probability = output.featureValue(for: "vad_output")?.multiArrayValue,
                  let nextH = output.featureValue(for: "new_hidden_state")?.multiArrayValue,
                  let nextC = output.featureValue(for: "new_cell_state")?.multiArrayValue else {
                throw Failure("人声检测失败，本次不会调用识别或润色服务。")
            }
            hidden = nextH; cell = nextC
            probabilities.append(probability[0].floatValue)
        }
        return SpeechEvidence.decide(probabilities: probabilities, sampleCount: samples.count)
    }
    private func zeroState() throws -> MLMultiArray {
        let state = try MLMultiArray(shape: [1, 128], dataType: .float32)
        state.dataPointer.bindMemory(to: Float.self, capacity: 128).initialize(repeating: 0, count: 128)
        return state
    }
}
