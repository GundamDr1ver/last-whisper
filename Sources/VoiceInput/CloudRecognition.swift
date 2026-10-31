import Foundation

enum CloudRecognition {
    static func request(samples: [Float], model: CloudModel, key: String) throws -> URLRequest {
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw Failure("请填写所选云端模型的 API 密钥。") }
        let url = try model.validatedURL()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let wave = PCM16.wave(samples)
        if url.path.hasSuffix("/audio/transcriptions") {
            let boundary = UUID().uuidString
            request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model.model)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
            body.append(wave); body.append(Data("\r\n--\(boundary)--\r\n".utf8)); request.httpBody = body
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["model": model.model, "stream": false, "messages": [["role": "user", "content": [["type": "input_audio", "input_audio": ["data": "data:audio/wav;base64," + wave.base64EncodedString()]]]]]]
            if model.id == "mimo" { body["asr_options"] = ["language": "auto"] }
            if model.id == "qwen" { body["asr_options"] = ["enable_itn": true] }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
    static func transcribe(_ samples: [Float], model: CloudModel, key: String, session: URLSession = .shared) async throws -> String {
        let data = try await checked(request(samples: samples, model: model, key: key), session: session)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["text"] as? String {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("云端模型返回空文字。") }
            return text
        }
        return try chatText(data)
    }

    static func checked(_ request: URLRequest, session: URLSession = .shared) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let reason: String
            switch code {
            case 401, 403: reason = "密钥无效或没有模型权限"
            case 404: reason = "服务地址或模型不存在"
            case 429: reason = "请求受限或账户额度不足"
            case 400, 422: reason = "模型不接受当前请求格式，请检查服务类型和模型名称"
            default: reason = "服务未正常响应，请稍后重试"
            }
            throw Failure("API 请求失败（HTTP \(code)）：\(reason)。")
        }
    }
    static func chatText(_ data: Data) throws -> String {
        struct Response: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String?; let refusal: String? }; let message: Message; let finish_reason: String? }; let choices: [Choice] }
        let result = try JSONDecoder().decode(Response.self, from: data)
        if let reason = result.choices.first?.finish_reason, reason != "stop" { throw Failure("API 未返回完整结果（\(reason)）。") }
        guard result.choices.first?.message.refusal == nil, let output = result.choices.first?.message.content,
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("API 返回空文字，未通过测试或处理。") }
        return output
    }
}
