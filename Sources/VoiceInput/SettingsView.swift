import SwiftUI
import AppKit

private actor KeychainWrites {
    static let shared = KeychainWrites()
    func save(_ value: String, account: String, writer: @Sendable (String, String) -> Bool) -> Bool { writer(value, account) }
}

@MainActor final class SettingsDraft: ObservableObject {
    @Published var selection = RecognitionSettings.load()
    @Published var polish = false
    @Published var polishURL = ""
    @Published var polishModel = ""
    @Published var keys: [String: String] = [:]
    @Published var status = ""
    @Published var testing = false
    @Published private(set) var savingKeys: Set<String> = []
    @Published private(set) var savedFingerprint: [String] = []
    private let writeKey: @Sendable (String, String) -> Bool
    init(writeKey: @escaping @Sendable (String, String) -> Bool = { Keychain.save($0, account: $1) }) { self.writeKey = writeKey }
    private var keyTasks: [String: Task<Void, Never>] = [:]
    private var loading = false
    var fingerprint: [String] { [selection.mode.rawValue, selection.local.rawValue, selection.provider.rawValue, String(polish), polishURL, polishModel] }
    var dirty: Bool { fingerprint != savedFingerprint }
    func load(readKey: @escaping @Sendable (String) -> String = { Keychain.read(account: $0) }) async {
        guard !loading else { return }; loading = true
        selection = .load()
        let config = APIConfiguration.load(keyProvider: { "" })
        polish = config.polish; polishURL = config.polishBaseURL; polishModel = config.polishModel
        savedFingerprint = fingerprint
        for account in ["polish-key"] + CloudProvider.allCases.map(\.keyAccount) {
            let value = await Task.detached { readKey(account) }.value
            if keys[account] == nil { keys[account] = value }
        }
    }
    func keyBinding(_ account: String) -> Binding<String> {
        Binding(get: { self.keys[account] ?? "" }, set: { self.editKey($0, account: account) })
    }
    func editKey(_ value: String, account: String) {
        keys[account] = value
        keyTasks[account]?.cancel()
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { savingKeys.remove(account); status = "密钥尚未填写；已存密钥不会因清空输入框而删除。"; return }
        savingKeys.insert(account)
        keyTasks[account] = Task {
            do { try await Task.sleep(for: .milliseconds(650)); try Task.checkCancellation() } catch { return }
            let ok = await KeychainWrites.shared.save(value, account: account, writer: writeKey)
            guard self.keys[account]?.trimmingCharacters(in: .whitespacesAndNewlines) == value else { return }
            self.savingKeys.remove(account)
            self.status = ok ? "密钥已自动保存。" : "密钥保存失败，请允许系统钥匙串访问后重新输入。"
        }
    }
    func save() {
        if selection.mode == .cloud, (keys[selection.provider.keyAccount] ?? "").isEmpty { status = "请先填写所选服务商的密钥。"; return }
        if selection.mode == .local, polish {
            guard !polishModel.isEmpty, !(keys["polish-key"] ?? "").isEmpty else { status = "请填写润色模型和密钥。"; return }
            do { _ = try APIConfiguration(polishBaseURL: polishURL, polishKey: "", polishModel: polishModel, polish: true).request("/chat/completions") }
            catch { status = error.localizedDescription; return }
        }
        let defaults = UserDefaults.standard
        defaults.set(polish, forKey: "batchPolishEnabled"); defaults.set(polishURL, forKey: "polishBaseURL"); defaults.set(polishModel, forKey: "polishModel")
        selection.save()
        savedFingerprint = fingerprint; status = "设置已保存，下次录音生效。"
    }
    func test() async {
        guard !testing else { return }; testing = true; status = "正在测试…"
        defer { testing = false }
        do {
            if selection.mode == .local {
                let config = APIConfiguration(polishBaseURL: polishURL, polishKey: keys["polish-key"] ?? "", polishModel: polishModel, polish: polish)
                let output = try await RemoteAPI.polish("请明天 review 这个 PR，然后确认 API。", config: config)
                status = "API 通过：" + String(output.prefix(110))
            } else {
                guard let file = Bundle.module.url(forResource: "api-test", withExtension: "wav", subdirectory: "Resources") else { throw Failure("测试音频缺失。") }
                let samples = try AudioSamples.load(file)
                let provider = selection.provider; let key = keys[provider.keyAccount] ?? ""
                let qwen = QwenStreaming(update: { _ in }); let mimo = MiMoStreaming(key: key, update: { _ in })
                do {
                    if provider == .qwen { try await qwen.start(key: key); try await qwen.push(samples); status = "API 通过：" + String(try await qwen.finish().prefix(110)) }
                    else { try await mimo.push(samples); status = "API 通过：" + String(try await mimo.finish().prefix(110)) }
                } catch { await qwen.cancel(); await mimo.cancel(); throw error }
            }
        } catch { status = "测试失败：" + error.localizedDescription }
    }
}

struct SettingsView: View {
    @StateObject private var draft = SettingsDraft()
    @ObservedObject private var downloads = ModelDownloads.shared
    @State private var trusted = AXIsProcessTrusted()
    private let preview: Bool
    @MainActor init(draft: SettingsDraft? = nil, preview: Bool = false) {
        _draft = StateObject(wrappedValue: draft ?? SettingsDraft()); self.preview = preview
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最后的轻语设置").font(.title2.bold())
            Text("F13 开始／停止。讲话时显示字幕，停止后一次性输入。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Label(trusted ? "自动输入权限已授权" : "请授予自动输入权限", systemImage: trusted ? "checkmark.shield" : "exclamationmark.shield")
                Spacer()
                Button("请求权限") {
                    trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                }.disabled(trusted)
                Button("系统设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
            }.font(.caption).frame(height: 30)
            Picker("模型选择", selection: $draft.selection.mode) {
                ForEach(RecognitionMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            GroupBox {
                Group {
                    if draft.selection.mode == .local { localOptions }
                    else { cloudOptions }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(8)
            }.frame(height: 350)
            HStack {
                Button("测试 API") { Task { await draft.test() } }.disabled(draft.testing)
                if draft.testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("保存设置") { draft.save() }.buttonStyle(.borderedProminent).disabled(!draft.dirty || draft.testing || !draft.savingKeys.isEmpty).keyboardShortcut(.defaultAction)
            }
            Text(draft.status.isEmpty ? "输入密钥会自动保存/更新至系统钥匙串" : draft.status)
                .font(.caption).foregroundStyle(draft.status.contains("失败") ? Color.orange : Color.secondary).lineLimit(3).frame(height: 44, alignment: .topLeading)
        }
        .textFieldStyle(.roundedBorder)
        .task { if !preview { await draft.load() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in trusted = AXIsProcessTrusted() }
    }
    private var localOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(LocalModel.allCases, id: \.self) { model in
                HStack(spacing: 10) {
                    Button { draft.selection.local = model } label: {
                        Image(systemName: draft.selection.local == model ? "largecircle.fill.circle" : "circle")
                    }.buttonStyle(.plain).disabled(!model.installed).accessibilityLabel("选择 " + model.title)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.title).font(.callout)
                        Text(downloads.messages[model] ?? model.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if let progress = downloads.progress[model] {
                        CircularDownloadProgress(value: progress)
                        Button("取消") { downloads.cancel(model) }.font(.caption)
                    } else if model.installed {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(downloads.messages[model]?.hasPrefix("下载失败") == true ? "重试" : "下载") { downloads.download(model) }
                    }
                }.frame(height: 44)
            }
            HStack {
                Text("StreamSpeech").font(.callout)
                Spacer()
                Text("研究模型，暂不支持本机中英听写").font(.caption).foregroundStyle(.secondary)
            }.frame(height: 24)
            Divider()
            Toggle("API 润色（默认关闭）", isOn: $draft.polish)
            TextField("润色服务地址", text: $draft.polishURL)
            HStack { TextField("润色模型", text: $draft.polishModel); SecureField("润色 API 密钥", text: draft.keyBinding("polish-key")) }
            Text("本地识别不上传音频。开启润色后，仅将最终文字发送至润色服务。").font(.caption).foregroundStyle(.secondary)
            Text("输入密钥会自动保存/更新至系统钥匙串").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var cloudOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("预设", selection: $draft.selection.provider) {
                ForEach(CloudProvider.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(draft.selection.provider.model).font(.caption.monospaced()).foregroundStyle(.secondary)
            SecureField("API 密钥", text: draft.keyBinding(draft.selection.provider.keyAccount))
            Text("输入密钥会自动保存/更新至系统钥匙串").font(.caption).foregroundStyle(.secondary)
            Text(draft.selection.provider == .qwen ? "使用百炼中国内地（北京）区域的 API 密钥。音频实时上传，识别草稿持续更新。" : "MiMo 当前接口接受音频片段，按片段流式返回文字；每段约 4 秒，停顿时提前提交。不会反复上传整段录音。")
                .font(.callout).foregroundStyle(.secondary)
            Text("云端模型直接识别音频，不额外调用润色服务。测试会发送固定测试录音，并可能产生费用。").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct CircularDownloadProgress: View {
    let value: Double
    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.2), lineWidth: 3)
            Circle().trim(from: 0, to: value).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
        }.frame(width: 20, height: 20).accessibilityLabel("下载 \(Int(value * 100))%")
    }
}
