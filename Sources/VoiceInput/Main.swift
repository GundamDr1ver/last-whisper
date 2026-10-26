import SwiftUI
import AppKit
import AVFoundation
import Carbon
import Combine

@main
struct VoiceInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { SettingsView().frame(width: 560, height: 400).padding(24) }.defaultLaunchBehavior(.suppressed)
        MenuBarExtra {
            StatusMenu(model: delegate.model)
        } label: {
            StatusIcon(model: delegate.model)
        }
    }
}

struct StatusIcon: View {
    @ObservedObject var model: DictationModel
    var body: some View {
        Image(nsImage: SpeakeasyBrand.menuIcon)
            .renderingMode(.template)
            .foregroundStyle(model.recording ? Color.red : Color.primary)
            .opacity(model.busy ? 0.55 : 1)
            .accessibilityLabel(model.recording ? "speakeasy：正在录音" : "speakeasy")
    }
}

struct StatusMenu: View {
    @ObservedObject var model: DictationModel
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Text(model.message)
        if !model.timingSummary.isEmpty { Text(model.timingSummary).font(.caption) }
        Divider()
        Button(model.recording ? "停止录音 · F13" : "开始录音 · F13") { model.toggle() }.disabled(model.busy)
        Divider()
        Button("设置…") { NSApp.activate(ignoringOtherApps: true); openSettings() }.keyboardShortcut(",")
        Button("授权辅助功能…") { model.requestAccessibility() }
        Divider()
        Button("退出 speakeasy") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = DictationModel()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var panel: NSPanel?
    private var observation: AnyCancellable?
    private var dismissTask: Task<Void, Never>?
    private var readyToQuit = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--ui-smoke") {
            renderSettingsPreview()
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--download-smoke") {
            Task { await runDownloadSmoke(); NSApp.terminate(nil) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--recognition-smoke") {
            Task { @MainActor in await model.runRecognitionSmoke(); NSApp.terminate(nil) }
            return
        }
        Task { try? await SpeechGate.shared.prepare() }
        model.prepareMicrophoneHardware()
        Task { @MainActor in await model.prepareLocalModel() }
        NotificationCenter.default.addObserver(forName: .recognitionSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model.prepareLocalModel() }
        }
        registerHotKey()
        observation = model.$phase.receive(on: RunLoop.main).sink { [weak self] phase in
            self?.updatePanel(phase)
        }
    }
    private func runDownloadSmoke() async {
        actor Counter {
            var count = 0
            func add() { count += 1 }
        }
        let counter = Counter()
        var report: [String: Any] = [:]
        do {
            var components = URLComponents(url: LocalModel.qwen.downloadURL, resolvingAgainstBaseURL: false)!
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "probe", value: UUID().uuidString)]
            var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
            let (file, response) = try await ModelFileTransfer(expectedBytes: 1048576, update: { _ in Task { await counter.add() } }).download(request)
            defer { try? FileManager.default.removeItem(at: file) }
            try await Task.sleep(for: .milliseconds(100))
            let count = await counter.count
            let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            report = ["http": (response as? HTTPURLResponse)?.statusCode ?? 0, "progressCallbacks": count, "bytes": bytes, "success": count > 0 && bytes == 1048576]
        } catch { report = ["success": false, "error": error.localizedDescription] }
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOICEINPUT_DOWNLOAD_REPORT"] ?? "/private/tmp/voiceinput-download-check.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
    }
    private func renderSettingsPreview() {
        let directory = ProcessInfo.processInfo.environment["VOICEINPUT_UI_REPORT"] ?? "/private/tmp"
        do {
            let draft = SettingsDraft()
            let view = NSHostingView(rootView: SettingsView(draft: draft, preview: true).frame(width: 560, height: 400).padding(24).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 608, height: 448), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.orderFront(nil)
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings-local.png"))
                }
            }
        }
    }
    private func updatePanel(_ phase: DictationModel.Phase) {
        dismissTask?.cancel()
        guard phase != .idle else {
            guard panel?.isVisible == true else { return }
            dismissTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                guard self?.model.phase == .idle else { return }
                self?.panel?.orderOut(nil)
            }
            return
        }
        if panel == nil {
            let window = SubtitlePanel(contentRect: NSRect(x: 0, y: 0, width: 86, height: 32), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isFloatingPanel = true
            window.level = .floating
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AudioActivityView(model: model))
            window.delegate = self
            panel = window
            let saved = UserDefaults.standard.string(forKey: "subtitleFrame").map(NSRectFromString)
            if let saved, NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSRect(origin: saved.origin, size: window.frame.size)) }) {
                window.setFrameOrigin(saved.origin)
            } else if let frame = (NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main)?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: frame.midX - 43, y: frame.minY + 70))
            }
        }
        if panel?.isVisible != true {
            let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
            if let panel, !NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }) {
                let saved = UserDefaults.standard.string(forKey: "subtitleFrame").map(NSRectFromString)
                if let saved, NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSRect(origin: saved.origin, size: panel.frame.size)) }) {
                    panel.setFrameOrigin(saved.origin)
                } else if let frame = screen?.visibleFrame {
                    panel.setFrameOrigin(NSPoint(x: frame.midX - 43, y: frame.minY + 70))
                }
            }
            // Show the preview without taking focus from the destination input field.
            panel?.orderFrontRegardless()
        }
    }
    func windowDidMove(_ notification: Notification) {
        if let panel { UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "subtitleFrame") }
    }
    func registerHotKey() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in delegate.model.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let result = RegisterEventHotKey(UInt32(kVK_F13), 0, EventHotKeyID(signature: 0x564F4943, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { model.message = "F13 已被占用，请通过菜单栏开始录音。" }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToQuit { return .terminateNow }
        model.shutdown()
        Task {
            await LocalRecognition.shared.unload()
            readyToQuit = true
            sender.terminate(nil)
        }
        // Return before awaiting cleanup: terminateLater nests AppKit's loop inside a MainActor job.
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        dismissTask?.cancel()
        model.shutdown()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class DictationModel: ObservableObject {
    enum Phase { case idle, preparing, recording, processing }
    @Published var phase: Phase = .idle
    @Published var text = ""
    @Published var message = "按 F13 开始，再按一次停止。"
    @Published var needsAttention = false
    @Published var audioLevel: Double = 0
    @Published var timingSummary = ""
    private var preparedEngine: AVAudioEngine?
    private let startCue = RecordingCue.start.sound
    private let stopCue = RecordingCue.stop.sound
    private let delivery = DictationDelivery()
    private var engine: AVAudioEngine?
    private var capture: RecordingCapture?
    private var recognitionTask: Task<String, Error>?
    private var settings = RecognitionSettings()
    private var session = UUID()
    var busy: Bool { phase == .preparing || phase == .processing }
    var recording: Bool { phase == .recording }
    func toggle() {
        if phase == .recording { Task { await stop() } }
        else if phase == .idle { Task { await start() } }
    }
    func start() async {
        guard phase == .idle else { return }
        needsAttention = false; text = ""; timingSummary = ""
        message = "正在准备麦克风…"; phase = .preparing
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let id = UUID(); session = id; settings = .load()
        let microphone: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = true
        case .notDetermined: microphone = await AVCaptureDevice.requestAccess(for: .audio)
        default: microphone = false
        }
        guard microphone else { message = "请允许麦克风权限。"; needsAttention = true; phase = .idle; return }
        do {
            guard AXIsProcessTrusted() else { throw Failure("请先授予辅助功能权限。") }
            guard !IsSecureEventInputEnabled(), let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw Failure("请先点击目标文字框，再按 F13。") }
            if !settings.local.installed { throw Failure("请先在设置中完成模型下载。") }
            let engine = preparedEngine ?? AVAudioEngine(); preparedEngine = engine
            let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure("没有可用的麦克风。") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceInput-" + id.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let capture: RecordingCapture
            do {
                capture = try RecordingCapture(format: format, url: directory.appendingPathComponent("recording.wav")) { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.session == id, self.phase == .recording else { return }
                        self.failRecording(error)
                    }
                }
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
            self.capture = capture
            let timing = CaptureStartTiming(requestedAt: requestedAt)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                capture.append(buffer)
                if let seconds = timing.receiveFirstBuffer() {
                    Task { @MainActor [weak self] in
                        guard let self, self.session == id, self.phase == .recording else { return }
                        self.timingSummary = String(format: "开录 %.0f 毫秒", seconds * 1000)
                        if self.stopCue?.isPlaying == true { self.stopCue?.stop() }; self.startCue?.volume = RecordingCue.playbackVolume; self.startCue?.play()
                        // Keep the system cue out of the recording; speech begins after the ready tone.
                        try? await Task.sleep(for: .seconds((self.startCue?.duration ?? 0) + 0.03))
                        guard self.session == id, self.phase == .recording else { return }
                        capture.begin()
                    }
                }
                if let samples = buffer.floatChannelData?[0] {
                    let count = Int(buffer.frameLength)
                    var energy: Float = 0
                    for i in 0..<count { energy += samples[i] * samples[i] }
                    let level = min(1, Double(sqrt(energy / Float(max(1, count)))) * 12)
                    Task { @MainActor [weak self] in if self?.session == id { self?.audioLevel = level } }
                }
            }
            self.engine = engine; engine.prepare(); try engine.start()
            phase = .recording; message = "正在录音 · 再按 F13 停止并输入"
        } catch { failRecording(error) }
    }
    func prepareMicrophoneHardware() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let prepared = AVAudioEngine(); _ = prepared.inputNode.outputFormat(forBus: 0); preparedEngine = prepared
    }
    func prepareLocalModel() async {
        guard phase == .idle else { return }
        let settings = RecognitionSettings.load()
        guard settings.local.installed else {
            if settings.local == .qwen, ModelDownloads.shared.messages[.qwen] == nil { ModelDownloads.shared.download(.qwen) }
            message = ModelDownloads.shared.messages[settings.local] ?? "请先完成模型下载。"; return
        }
        do {
            try await LocalRecognition.shared.prepare(settings.local)
            if phase == .idle { message = "已就绪 · 按 F13 开始" }
        } catch { if phase == .idle { message = error.localizedDescription; needsAttention = true } }
    }
    func stop() async {
        guard phase == .recording, let capture else { return }
        phase = .processing
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        capture.finish()
        if startCue?.isPlaying == true { startCue?.stop() }; stopCue?.volume = RecordingCue.playbackVolume; stopCue?.play(); audioLevel = 0
        let id = session; let started = Date(); let choice = settings
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            guard let self, self.session == id, self.phase == .processing else { return }
            self.failRecording(Failure("识别超时，请检查模型后重试。"))
        }
        defer {
            timeout.cancel()
            if session == id { recognitionTask = nil; cleanup(); delivery.end(); phase = .idle }
        }
        do {
            try delivery.capture()
            message = "正在识别…"
            let task = Task.detached {
                let samples = try AudioSamples.load(capture.url)
                return try await RecordingRecognition.transcribe(samples, settings: choice)
            }
            recognitionTask = task
            let raw = try await task.value
            guard session == id else { return }
            text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { message = "未检测到有效语音，未输入文字。"; return }
            try await delivery.deliver(text)
            timingSummary += String(format: " · 处理 %.2f 秒", Date().timeIntervalSince(started))
            message = "已输入"
        } catch {
            guard session == id else { return }
            recognitionTask?.cancel(); needsAttention = true; message = error.localizedDescription
            preserveResult()
        }
    }
    private func preserveResult() {
        if !text.isEmpty { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); message += " 识别文字已保留在剪贴板。" }
    }
    private func cleanup() {
        capture?.finish()
        if let url = capture?.url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        capture = nil
    }
    private func failRecording(_ error: Error, preserve: Bool = true) {
        session = UUID(); recognitionTask?.cancel(); recognitionTask = nil
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }; engine = nil
        startCue?.stop(); cleanup(); audioLevel = 0; needsAttention = true; message = error.localizedDescription
        delivery.end(); phase = .idle; if preserve { preserveResult() }
    }
    func shutdown() { failRecording(CancellationError(), preserve: false) }
    func requestAccessibility() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
    func runRecognitionSmoke() async {
        var report: [String: Any] = ["noAPIRequests": true, "noMicrophone": true, "noTextInjection": true]
        do {
            guard let file = Bundle.module.url(forResource: "api-test", withExtension: "wav", subdirectory: "Resources") else { throw Failure("测试音频缺失。") }
            let samples = try AudioSamples.load(file)
            var results: [[String: Any]] = []
            for model in LocalModel.allCases where model.installed {
                let tick = Date()
                let text = try await RecordingRecognition.transcribe(samples, settings: .init(local: model))
                results.append(["model": model.title, "text": text, "seconds": Date().timeIntervalSince(tick)])
            }
            report["models"] = results; report["success"] = !results.isEmpty && results.allSatisfy { !($0["text"] as? String ?? "").isEmpty }
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOICEINPUT_SMOKE_REPORT"] ?? "/private/tmp/voiceinput-recognition-smoke.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
    }
}

struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

// A small non-activating audio indicator; it never takes the target editor focus.
final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct AudioActivityView: View {
    @ObservedObject var model: DictationModel
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: model.phase == .idle)) { context in
            HStack(spacing: 4) {
                ForEach(0..<7) { index in
                    let pulse = (sin(context.date.timeIntervalSinceReferenceDate * 7 + Double(index)) + 1) / 2
                    Capsule().fill(model.recording ? Color.white : .orange).frame(width: 4, height: 4 + 18 * max(0.15, model.audioLevel) * pulse)
                }
            }.frame(width: 86, height: 32).background(.black.opacity(0.5), in: Capsule())
        }.allowsHitTesting(false)
    }
}

/// Play the original macOS dictation cues without resampling or gain enhancement.
enum RecordingCue: String {
    case start = "recording-start"
    case stop = "recording-stop"
    static let playbackVolume: Float = 0.75
    var url: URL? {
        let native = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/AssistantServices.framework/Versions/A/Resources/" + (self == .start ? "dt-begin.caf" : "dt-confirm.caf"))
        if FileManager.default.fileExists(atPath: native.path) { return native }
        return Bundle.module.url(forResource: rawValue, withExtension: "wav", subdirectory: "Resources")
    }
    var sound: AVAudioPlayer? {
        guard let url, let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.volume = Self.playbackVolume
        player.prepareToPlay()
        return player
    }
}
