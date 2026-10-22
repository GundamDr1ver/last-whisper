import Foundation

// A separate executable keeps Whisper's ggml symbols isolated from audio.cpp.
enum WhisperRecognition {
    static var executable: URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/whisper-cli")
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".native/whisper-cli")
    }
    static func arguments(model: URL, audio: URL, output: URL) -> [String] {
        ["-m", model.path, "-f", audio.path, "-l", "auto", "-t", "4", "-otxt", "-of", output.path, "-np"]
    }
    static func transcribe(_ samples: [Float], model: URL) throws -> String {
        try Task.checkCancellation()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceInput-whisper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("recording.wav"), output = root.appendingPathComponent("transcript")
        try PCM16.wave(samples).write(to: audio)
        let log = root.appendingPathComponent("error.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(model: model, audio: audio, output: output)
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw Failure("Whisper 识别超时，请缩短录音后重试。") }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw Failure("Whisper 识别失败：" + String(detail.suffix(500)))
        }
        try Task.checkCancellation()
        let text = try String(contentsOf: output.appendingPathExtension("txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure("Whisper 未返回识别文字。") }
        return text
    }
}
