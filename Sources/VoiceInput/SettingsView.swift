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
    var fingerprint: [String] { [selection.mode.rawValue, selection.local.rawValue, selection.cloudID, String(polish), polishURL, polishModel] + selection.cloudModels.flatMap { [$0.id, $0.title, $0.endpoint, $0.model] } }
    var dirty: Bool { loading && fingerprint != savedFingerprint }
    func load(readKey: @escaping @Sendable (String) -> String = { Keychain.read(account: $0) }) async {
        guard !loading else { return }; loading = true
        selection = .load()
        let config = APIConfiguration.load(keyProvider: { "" })
        polish = config.polish; polishURL = config.polishBaseURL; polishModel = config.polishModel
        savedFingerprint = fingerprint
        for account in ["polish-key"] + selection.cloudModels.map(\.keyAccount) {
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
    func save(defaults: UserDefaults = .standard) {
        if selection.mode == .cloud, (keys[selection.cloud.keyAccount] ?? "").isEmpty { status = "请先填写所选服务商的密钥。"; return }
        if selection.mode == .cloud {
            do { _ = try selection.cloud.validatedURL() } catch { status = error.localizedDescription; return }
        }
        if polish {
            guard !polishModel.isEmpty, !(keys["polish-key"] ?? "").isEmpty else { status = "请填写润色模型和密钥。"; return }
            do { _ = try APIConfiguration(polishBaseURL: polishURL, polishKey: "", polishModel: polishModel, polish: true).request("/chat/completions") }
            catch { status = error.localizedDescription; return }
        }
        defaults.set(polish, forKey: "batchPolishEnabled"); defaults.set(polishURL, forKey: "polishBaseURL"); defaults.set(polishModel, forKey: "polishModel")
        selection.save(defaults)
        savedFingerprint = fingerprint; status = "设置已保存，下次录音生效。"
    }
    func cloudBinding(_ field: WritableKeyPath<CloudModel, String>) -> Binding<String> {
        Binding(get: { self.selection.cloud[keyPath: field] }, set: { value in
            guard let index = self.selection.cloudModels.firstIndex(where: { $0.id == self.selection.cloudID }) else { return }
            self.selection.cloudModels[index][keyPath: field] = value
        })
    }
    func addCloudModel() {
        let model = CloudModel(id: UUID().uuidString, title: "自定义模型", endpoint: "", model: "")
        selection.cloudModels.append(model); selection.cloudID = model.id
    }
    var canRemoveCloudModel: Bool { !CloudModel.presets.contains(where: { $0.id == selection.cloudID }) }
    func removeCloudModel() {
        guard canRemoveCloudModel else { return }
        selection.cloudModels.removeAll { $0.id == selection.cloudID }
        selection.cloudID = selection.cloudModels.first?.id ?? CloudModel.qwen.id
    }
    func test(polishing: Bool = false) async {
        guard !testing else { return }; testing = true; status = "正在测试…"
        defer { testing = false }
        do {
            let output: String
            if polishing {
                let config = APIConfiguration(polishBaseURL: polishURL, polishKey: keys["polish-key"] ?? "", polishModel: polishModel, polish: polish)
                output = try await RemoteAPI.polish("请明天 review 这个 PR，然后确认 API。", config: config)
            } else {
                guard let file = Bundle.module.url(forResource: "api-test", withExtension: "wav", subdirectory: "Resources") else { throw Failure("测试音频缺失。") }
                output = try await CloudRecognition.transcribe(AudioSamples.load(file), model: selection.cloud, key: keys[selection.cloud.keyAccount] ?? "")
            }
            status = "API 通过：" + String(output.prefix(110))
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
        VStack(alignment: .leading, spacing: 10) {
            Text("speakeasy 设置").font(.title2.bold())
            Text("按 F13 开始，再按一次停止并输入。").font(.caption).foregroundStyle(.secondary)
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
                    if draft.selection.mode == .local { ScrollView { localOptions }.scrollIndicators(.automatic) }
                    else { cloudOptions }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(8)
            }.frame(height: 200)
            GroupBox("API 润色") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("启用润色", isOn: $draft.polish)
                    TextField("接口地址", text: $draft.polishURL)
                    HStack { TextField("模型名称", text: $draft.polishModel); SecureField("API 密钥", text: draft.keyBinding("polish-key")) }
                    Button("测试润色 API") { Task { await draft.test(polishing: true) } }.disabled(draft.testing)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("输入密钥会自动保存/更新至系统钥匙串").font(.caption).foregroundStyle(.secondary)
            HStack {
                if draft.testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("保存设置") { draft.save() }.buttonStyle(.borderedProminent).disabled(!draft.dirty || draft.testing || !draft.savingKeys.isEmpty).keyboardShortcut(.defaultAction)
            }
            Text(draft.status)
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

        }
    }
    private var cloudOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("预设", selection: $draft.selection.cloudID) {
                    ForEach(draft.selection.cloudModels) { Text($0.title).tag($0.id) }
                }
                Button("添加") { draft.addCloudModel() }
                if draft.canRemoveCloudModel { Button("删除", role: .destructive) { draft.removeCloudModel() }.disabled(draft.testing) }
            }
            TextField("名称", text: draft.cloudBinding(\.title))
            TextField("接口地址", text: draft.cloudBinding(\.endpoint))
            HStack {
                TextField("模型名称", text: draft.cloudBinding(\.model))
                SecureField("API 密钥", text: draft.keyBinding(draft.selection.cloud.keyAccount))
            }
            Button("测试识别 API") { Task { await draft.test() } }.disabled(draft.testing)
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
