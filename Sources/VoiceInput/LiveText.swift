import AppKit
import ApplicationServices
import Carbon

/// One paste per recording. Capture the caret at stop and never rewrite existing text.
@MainActor
final class DictationDelivery {
    private var target: NSRunningApplication?
    private var focus: AXUIElement?
    private var selection: NSRange?
    private var value: String?
    private var changed = false
    private var monitors: [Any] = []
    private var activation: NSObjectProtocol?
    private let eventTag: Int64 = 0x564F494345
    private var clipboardRestore: Task<Void, Never>?
    private var pendingClipboard: (snapshot: ClipboardSnapshot, change: Int)?

    func capture() throws {
        end()
        guard AXIsProcessTrusted() else { throw Failure("请先授予辅助功能权限。") }
        guard !IsSecureEventInputEnabled(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw Failure("请先点击目标文字框，再按 F13。") }
        target = app
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        focus = focused(application)
        if let focus {
            guard attribute(focus, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { throw Failure("无法向密码框输入。") }
            selection = selected(focus)
            value = attribute(focus, kAXValueAttribute) as? String
        }
        changed = false
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }; return event
        }) { monitors.append(monitor) }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed = true }
        }
    }
    var polishingContext: PolishContext {
        guard !changed, !IsSecureEventInputEnabled(), let target,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return .init() }
        return .init(style: .detect(bundleID: target.bundleIdentifier), precedingText: PolishContext.beforeCaret(value: value, selection: selection))
    }
    private func observe(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != eventTag else { return }
        if event.type == .keyDown && [UInt16(kVK_F13), UInt16(kVK_F5)].contains(event.keyCode) { return }
        changed = true
    }
    func deliver(_ text: String) async throws {
        try Task.checkCancellation()
        guard !changed, AXIsProcessTrusted(), !IsSecureEventInputEnabled(), let target, !target.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { throw Failure("识别期间输入位置已改变，取消自动输入。") }
        let application = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let current = focused(application)
        if let focus {
            guard let current, CFEqual(current, focus) else { throw Failure("目标文字框已改变，取消自动输入。") }
            if let selection { guard selected(focus) == selection else { throw Failure("光标已改变，取消自动输入。") } }
            if let value { guard attribute(focus, kAXValueAttribute) as? String == value else { throw Failure("文字已被编辑，取消自动输入。") } }
        }
        if let current, attribute(current, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { throw Failure("无法向密码框输入。") }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { throw Failure("无法发送输入事件。") }
        let clipboard = NSPasteboard.general
        let saved: ClipboardSnapshot
        if let pendingClipboard, clipboard.changeCount == pendingClipboard.change { saved = pendingClipboard.snapshot }
        else { saved = ClipboardSnapshot(clipboard) }
        clipboardRestore?.cancel()
        pendingClipboard = nil
        clipboard.clearContents()
        guard clipboard.setString(text, forType: .string) else { throw Failure("无法准备输入文字。") }
        let ownChange = clipboard.changeCount
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: eventTag)
            event.postToPid(target.processIdentifier)
        }
        // Restoration must not keep dictation busy after the text is already pasted.
        pendingClipboard = (saved, ownChange)
        clipboardRestore = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            guard let self, self.pendingClipboard?.change == ownChange else { return }
            if clipboard.changeCount == ownChange { saved.restore(to: clipboard) }
            self.pendingClipboard = nil
            self.clipboardRestore = nil
        }
    }
    func end() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil; target = nil; focus = nil; selection = nil; value = nil
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    private func focused(_ application: AXUIElement) -> AXUIElement? {
        guard let result = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    private func selected(_ element: AXUIElement) -> NSRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
