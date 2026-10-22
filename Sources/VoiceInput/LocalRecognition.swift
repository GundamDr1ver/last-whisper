import Foundation
import NativeAudio

/// All native handles stay on one actor; model inference never blocks the UI.
actor LocalRecognition {
    static let shared = LocalRecognition()
    private var registry: OpaquePointer?
    private var model: OpaquePointer?
    private var session: OpaquePointer?
    private var selected: LocalModel?
    deinit { audiocpp_session_free(session); audiocpp_model_free(model); audiocpp_registry_free(registry) }
    private func check(_ status: audiocpp_status) throws {
        guard status == AUDIOCPP_OK else { throw Failure("本地识别失败：" + String(cString: audiocpp_last_error())) }
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
            try "metal".withCString { backend in
                var config = audiocpp_backend_config(backend: backend, device: 0, threads: 4)
                try check(audiocpp_session_create(model, "asr", "offline", &config, nil, &session))
            }
            selected = choice
        } catch { unload(); throw error }
    }
    func unload() {
        audiocpp_session_free(session); session = nil
        audiocpp_model_free(model); model = nil
        audiocpp_registry_free(registry); registry = nil; selected = nil
    }
    func transcribe(_ samples: [Float], choice: LocalModel) throws -> String {
        try Task.checkCancellation()
        try prepare(choice)
        guard let request = audiocpp_request_create() else { throw Failure("无法创建识别请求。") }
        defer { audiocpp_request_free(request) }
        try samples.withUnsafeBufferPointer { buffer in try check(audiocpp_request_set_audio(request, buffer.baseAddress, buffer.count, 16000, 1)) }
        var result: OpaquePointer?
        try check(audiocpp_session_run(session, request, &result))
        defer { audiocpp_result_free(result) }
        try Task.checkCancellation()
        var text: UnsafePointer<CChar>?
        try check(audiocpp_result_text(result, &text, nil))
        return (text.map { String(cString: $0) } ?? "").replacingOccurrences(of: #"(?:^|\n)\s*Speaker\s*\d+\s*:\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
