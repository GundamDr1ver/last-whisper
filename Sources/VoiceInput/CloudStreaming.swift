import Foundation

struct StreamingTranscript {
    private(set) var order: [String] = []
    private(set) var items: [String: String] = [:]
    private var completed = Set<String>()
    mutating func update(id: String, text: String, final: Bool) {
        if !order.contains(id) { order.append(id) }
        guard final || !completed.contains(id) else { return }
        items[id] = text
        if final { completed.insert(id) }
    }
    var text: String { order.compactMap { items[$0] }.joined(separator: " ") }
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

actor QwenStreaming {
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiver: Task<Void, Error>?
    private var transcript = StreamingTranscript()
    private var ready = false
    private var failure: Error?
    private let update: @Sendable (String) async -> Void
    init(update: @escaping @Sendable (String) async -> Void) { self.update = update }
    static func request(key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime")!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        request.timeoutInterval = 20
        return request
    }
    func start(key: String) async throws {
        guard !key.isEmpty else { throw Failure("请在设置中填写 Qwen ASR 密钥。") }
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration); self.session = session
        let socket = session.webSocketTask(with: Self.request(key: key)); self.socket = socket
        socket.resume()
        receiver = Task {
            do { try await receive() }
            catch { failure = error; throw error }
        }
        try await send(["type": "session.update", "session": ["input_audio_format": "pcm", "sample_rate": 16000, "input_audio_transcription": [:], "turn_detection": ["type": "server_vad", "threshold": 0.2, "silence_duration_ms": 600]]])
        let deadline = Date().addingTimeInterval(20)
        while !ready {
            if let failure { cancel(); throw failure }
            guard Date() < deadline else { cancel(); throw Failure("Qwen 连接超时，请检查密钥与网络。") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private func send(_ event: [String: Any]) async throws {
        guard let socket else { throw Failure("Qwen 流式连接已关闭。") }
        var event = event; event["event_id"] = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: event)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func receive() async throws {
        guard let socket else { return }
        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message { case .string(let text): data = Data(text.utf8); case .data(let bytes): data = bytes; @unknown default: continue }
            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = event["type"] as? String else { throw Failure("Qwen 返回了无法识别的流式事件。") }
            switch type {
            case "session.updated": ready = true
            case "conversation.item.input_audio_transcription.text", "conversation.item.input_audio_transcription.completed":
                guard let id = event["item_id"] as? String else { throw Failure("Qwen 转写缺少片段 ID。") }
                let final = type.hasSuffix(".completed")
                let text = final ? event["transcript"] as? String ?? "" : (event["text"] as? String ?? "") + (event["stash"] as? String ?? "")
                transcript.update(id: id, text: text, final: final)
                await update(transcript.text)
            case "session.finished": return
            case "error", "conversation.item.input_audio_transcription.failed": throw Failure("Qwen 识别失败，请检查密钥权限、额度和服务区域。")
            default: break
            }
        }
        throw CancellationError()
    }
    func push(_ samples: [Float]) async throws {
        if let failure { throw failure }
        // Keep each wire message small, including when the input gate releases its preroll.
        for offset in stride(from: 0, to: samples.count, by: 3200) {
            try await send(["type": "input_audio_buffer.append", "audio": PCM16.encode(Array(samples[offset..<min(offset + 3200, samples.count)])).base64EncodedString()])
        }
    }
    func finish() async throws -> String {
        try await send(["type": "session.finish"])
        let timeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(30))
            await self?.cancel()
        }
        defer { timeout.cancel(); cancel() }
        try await receiver?.value
        if let failure { throw failure }
        return transcript.text
    }
    func cancel() { receiver?.cancel(); socket?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel(); socket = nil; session = nil }
}

actor MiMoStreaming {
    private let key: String
    private let update: @Sendable (String) async -> Void
    private let session = URLSession(configuration: .ephemeral)
    private var pending: [Float] = []
    private var committed = ""
    init(key: String, update: @escaping @Sendable (String) async -> Void) { self.key = key; self.update = update }
    static func request(samples: [Float], key: String) throws -> URLRequest {
        guard !key.isEmpty else { throw Failure("请在设置中填写 MiMo ASR 密钥。") }
        var request = URLRequest(url: URL(string: "https://api.xiaomimimo.com/v1/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "mimo-v2.5-asr", "stream": true, "asr_options": ["language": "auto"], "messages": [["role": "user", "content": [["type": "input_audio", "input_audio": ["data": "data:audio/wav;base64," + PCM16.wave(samples).base64EncodedString()]]]]]])
        return request
    }
    func push(_ samples: [Float]) async throws {
        pending += samples
        if pending.count >= 64000 { try await flush() }
    }
    func boundary() async throws { try await flush() }
    private func flush() async throws {
        guard !pending.isEmpty else { return }
        let samples = pending; pending.removeAll(keepingCapacity: true)
        let (bytes, response) = try await session.bytes(for: Self.request(samples: samples, key: key))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure("MiMo 识别请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)），请检查密钥与额度。")
        }
        var draft = ""; var complete = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { complete = true; break }
            guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw Failure("MiMo 流式响应格式异常。") }
            if object["error"] != nil { throw Failure("MiMo 返回了识别错误。") }
            if let choice = (object["choices"] as? [[String: Any]])?.first {
                if let content = (choice["delta"] as? [String: Any])?["content"] as? String { draft += content; await update(committed + draft) }
                if let reason = choice["finish_reason"] as? String {
                    guard reason == "stop" else { throw Failure("MiMo 未返回完整转写。") }
                    complete = true
                }
            }
        }
        guard complete, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("MiMo 流式识别中断或返回空文字。") }
        committed += draft + " "
        await update(committed)
    }
    func finish() async throws -> String { try await flush(); session.invalidateAndCancel(); return committed.trimmingCharacters(in: .whitespacesAndNewlines) }
    func cancel() { session.invalidateAndCancel(); pending.removeAll() }
}
