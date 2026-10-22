import Foundation
import NativeAudio

/// A single actor owns all C handles; inference never runs on the UI thread.
actor LocalStreaming {
    static let shared = LocalStreaming()
    private var registry: OpaquePointer?
    private var model: OpaquePointer?
    private var session: OpaquePointer?
    private var selected: LocalModel?
    private var active: UUID?
    private var offset: Int64 = 0
    private var accumulated = ""
    deinit { audiocpp_session_free(session); audiocpp_model_free(model); audiocpp_registry_free(registry) }
    private func check(_ status: audiocpp_status) throws {
        guard status == AUDIOCPP_OK else { throw Failure("本地模型：" + String(cString: audiocpp_last_error())) }
    }
    func prepare(_ choice: LocalModel) throws {
        if selected == choice, session != nil { return }
        guard choice.installed else { throw Failure("请先在设置中下载 \(choice.title)。") }
        unload()
        do {
            try check(audiocpp_registry_create(nil, &registry))
            try choice.family.withCString { family in
                var config = audiocpp_model_config(family_hint: family, config_id: nil, weight_id: nil, model_spec_override: nil)
                try check(audiocpp_model_load(registry, choice.url.path, &config, nil, &model))
            }
            guard audiocpp_model_supports(model, "asr", "streaming") != 0 else { throw Failure("此模型不支持流式识别。") }
            try "metal".withCString { backend in
                var config = audiocpp_backend_config(backend: backend, device: 0, threads: 4)
                try check(audiocpp_session_create(model, "asr", "streaming", &config, nil, &session))
            }
            selected = choice
        } catch { unload(); throw error }
    }
    func unload() {
        audiocpp_session_free(session); session = nil
        audiocpp_model_free(model); model = nil
        audiocpp_registry_free(registry); registry = nil; selected = nil; active = nil
    }
    func start(_ choice: LocalModel, token: UUID) throws {
        try prepare(choice)
        let request = audiocpp_request_create()
        defer { audiocpp_request_free(request) }
        // Qwen is a buffered streaming model. VibeVoice uses its trained chunk/lookahead.
        if choice == .qwen { try check(audiocpp_request_set_option(request, "audio_chunk_seconds", "2")) }
        // The C ABI prepares from this format contract; start_stream discards the placeholder audio.
        var zero: Float = 0
        try check(audiocpp_request_set_audio(request, &zero, 1, 16000, 1))
        try check(audiocpp_stream_start(session, request))
        active = token; offset = 0; accumulated = ""
    }
    func push(_ samples: [Float], token: UUID) throws -> String {
        guard session != nil, active == token else { throw Failure("本地流式会话尚未开始。") }
        var event: OpaquePointer?
        try samples.withUnsafeBufferPointer { buffer in
            try check(audiocpp_stream_push(session, buffer.baseAddress, buffer.count, 16000, 1, offset, &event))
        }
        offset += Int64(samples.count)
        consume(event)
        while true {
            var next: OpaquePointer?
            try check(audiocpp_stream_next_event(session, &next))
            guard let next else { break }
            consume(next)
        }
        return displayText(accumulated)
    }
    private func consume(_ event: OpaquePointer?) {
        guard let event else { return }
        defer { audiocpp_event_free(event) }
        if let result = audiocpp_event_as_result(event) {
            var text: UnsafePointer<CChar>?
            if audiocpp_result_text(result, &text, nil) == AUDIOCPP_OK, let text { accumulated += String(cString: text) }
        }
    }
    func finish(token: UUID) throws -> String {
        guard active == token else { throw CancellationError() }
        defer { active = nil }
        var result: OpaquePointer?
        try check(audiocpp_stream_finish(session, &result))
        defer { audiocpp_result_free(result) }
        var text: UnsafePointer<CChar>?
        if audiocpp_result_text(result, &text, nil) == AUDIOCPP_OK, let text { return displayText(String(cString: text)) }
        return displayText(accumulated)
    }
    func reset(token: UUID) { if session != nil, active == token { _ = audiocpp_stream_reset(session); active = nil } }
    nonisolated func displayText(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?:^|\n)\s*Speaker\s*\d+\s*:\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
