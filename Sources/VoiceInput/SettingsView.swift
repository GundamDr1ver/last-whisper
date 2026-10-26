import SwiftUI
import AppKit

@MainActor final class SettingsDraft: ObservableObject {
    @Published var selection = RecognitionSettings.load()
    @Published var status = ""
    @Published private(set) var savedSelection = RecognitionSettings.load()
    var dirty: Bool { selection != savedSelection }
    func load(defaults: UserDefaults = .standard) {
        selection = .load(defaults)
        savedSelection = selection
    }
    func save(defaults: UserDefaults = .standard) {
        selection.save(defaults)
        savedSelection = selection
        status = "设置已保存，下次录音生效。"
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
            GroupBox("模型选择") {
                ScrollView { localOptions.padding(8) }
                    .scrollIndicators(.automatic)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(height: 200)
            HStack {
                Spacer()
                Button("保存设置") { draft.save() }.buttonStyle(.borderedProminent).disabled(!draft.dirty).keyboardShortcut(.defaultAction)
            }
            Text(draft.status)
                .font(.caption).foregroundStyle(draft.status.contains("失败") ? Color.orange : Color.secondary).lineLimit(3).frame(height: 44, alignment: .topLeading)
        }
        .textFieldStyle(.roundedBorder)
        .task { if !preview { draft.load() } }
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
