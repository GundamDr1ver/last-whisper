import Foundation

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
        let data = try await RemoteAPI.checked(request(samples: samples, model: model, key: key), session: session)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["text"] as? String {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("云端模型返回空文字。") }
            return text
        }
        return try RemoteAPI.chatText(data)
    }
}
