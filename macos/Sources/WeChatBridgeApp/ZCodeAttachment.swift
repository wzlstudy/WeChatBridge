import AppKit
import ApplicationServices
import WeChatBridgeCore

/// ZCode's composer only takes a ⌘V while it holds the focus itself.
///
/// A forward to ZCode on 2026-10-15 recorded 已送达 and left the composer empty
/// with the archive sitting on the clipboard — the user's own ⌘V a moment later
/// attached it. That is the shape `AutoPaste.focusTextInput` was written for on
/// WeSight, one step further along: activating an Electron app restores its
/// window, not the DOM focus inside the page, and a keystroke posted at that
/// moment is swallowed without throwing. ZCode is Electron (Electron
/// Framework.framework ships in the app), and AX focus alone did not hold — the
/// same reason `DoubaoAttachment` drives Doubao's web composer through its own
/// controls instead of a bare paste.
///
/// So this path stops trusting the keystroke. It clicks the composer, pastes,
/// and then looks in ZCode's accessibility tree for the files it asked for; a
/// paste that cannot be seen there is tried once more and then reported as a
/// failure. The 记录 row has to say 未送达 when nothing arrived — claiming
/// delivery in silence is exactly what made this bug take a round trip to find.
enum ZCodeAttachment {
    enum Failure: Error, LocalizedError {
        case composer
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .composer:
                return L10n.text("没有在 ZCode 窗口里找到输入框。")
            case .rejected(let names):
                return L10n.format("ZCode 没有接住文件“%@”。", names)
            }
        }
    }

    /// After the click, so the renderer has moved its DOM focus, and between the
    /// two attempts, so a window that was still settling has had a moment.
    private static let settle: UInt64 = 400_000_000

    /// How long an attachment chip may take to appear in the tree. Longer than
    /// the click's settle: the renderer has to accept the drop first.
    private static let attachmentTimeout: TimeInterval = 3

    /// Pastes the plan into ZCode — the prompt first when 入口 attached one,
    /// then the files — and proves the files arrived.
    @MainActor
    static func send(bundleIdentifier: String, plan: [PastePayload]) async throws {
        guard AutoPaste.isTrusted,
              let application = NSRunningApplication.runningApplications(
                  withBundleIdentifier: bundleIdentifier
              ).first
        else { throw AutoPaste.Failure.notTrusted }

        let root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)

        for payload in plan {
            guard case .text(let text) = payload else { continue }
            try focusComposer(in: root)
            try await paste(.text(text))
        }

        guard let urls = plan.compactMap({ payload -> [URL]? in
            if case .files(let urls) = payload { return urls }
            return nil
        }).last, !urls.isEmpty else { return }

        try await attach(urls, in: root)
    }

    /// One click-and-paste, then a second if the first left no trace.
    ///
    /// The retry is not politeness: the first ⌘V arrives while ZCode is still
    /// taking the foreground, and a click that lands during that animation can
    /// be dropped along with it.
    private static func attach(_ urls: [URL], in root: AXUIElement) async throws {
        let baseline = counts(of: urls, in: root)
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: settle) }
            try focusComposer(in: root)
            try await paste(.files(urls))
            if await waitForAttachments(urls, exceeding: baseline, in: root) { return }
        }
        throw Failure.rejected(urls.map(\.lastPathComponent).joined(separator: "、"))
    }

    private static func paste(_ payload: PastePayload) async throws {
        guard FilePasteboard.write(payload) else { throw AutoPaste.Failure.eventCreationFailed }
        try AutoPaste.pressCommandV()
        try? await Task.sleep(nanoseconds: settle)
    }

    /// Puts the keyboard into the composer, by click rather than by attribute.
    ///
    /// `AXFocused` is still set — it costs nothing and is what a native field
    /// would need — but the click is the one that works on a web composer: it
    /// goes through the app's own hit testing, so whatever the page considers
    /// focusable is what ends up focused. Bottom-most editable element wins,
    /// for the reason `AutoPaste.focusTextInput` gives: every one of these
    /// destinations is a chat and its composer sits at the bottom.
    private static func focusComposer(in root: AXUIElement) throws {
        guard let window = focusedWindow(of: root),
              let composer = nodes(in: window)
                  .filter(isEditable)
                  .max(by: { $0.frame.maxY < $1.frame.maxY })
        else { throw Failure.composer }

        AXUIElementSetAttributeValue(
            composer.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        try click(composer.frame)
    }

    private static func isEditable(_ node: Node) -> Bool {
        (node.role == kAXTextAreaRole || node.role == kAXTextFieldRole)
            && node.isEnabled
            && node.frame.width > 0
            && node.frame.height > 0
    }

    /// How many nodes already carry each file's name.
    ///
    /// Counted, not looked up once: the same name can be on screen before this
    /// paste — a previous attempt, or the chat's own history — and only an
    /// increase proves this one landed.
    private static func counts(of urls: [URL], in root: AXUIElement) -> [String: Int] {
        let all = nodes(in: root)
        return urls.reduce(into: [:]) { counts, url in
            counts[url.lastPathComponent] = all.filter { mentions($0, url) }.count
        }
    }

    /// A chat row or an attachment chip names the file; a chip that truncates
    /// it still carries the stem.
    private static func mentions(_ node: Node, _ url: URL) -> Bool {
        let name = url.lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return node.strings.contains { string in
            string.contains(name) || (!stem.isEmpty && string.contains(stem))
        }
    }

    private static func waitForAttachments(
        _ urls: [URL],
        exceeding baseline: [String: Int],
        in root: AXUIElement
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(attachmentTimeout)
        while Date() < deadline {
            let current = counts(of: urls, in: root)
            let arrived = urls.allSatisfy { url in
                let name = url.lastPathComponent
                return (current[name] ?? 0) > (baseline[name] ?? 0)
            }
            if arrived { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    // MARK: - Accessibility

    private struct Node {
        let element: AXUIElement
        let role: String
        let strings: [String]
        let children: [AXUIElement]
        let frame: CGRect
        let isEnabled: Bool

        init(_ element: AXUIElement) {
            self.element = element
            role = Node.value(element, kAXRoleAttribute) as? String ?? ""
            strings = [
                Node.value(element, kAXTitleAttribute),
                Node.value(element, kAXValueAttribute),
                Node.value(element, kAXDescriptionAttribute),
                Node.value(element, kAXHelpAttribute),
            ].compactMap { $0 as? String }.filter { !$0.isEmpty }
            children = Node.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            isEnabled = Node.value(element, kAXEnabledAttribute) as? Bool ?? true
            var origin = CGPoint.zero
            var size = CGSize.zero
            if let position = Node.value(element, kAXPositionAttribute),
               CFGetTypeID(position) == AXValueGetTypeID() {
                AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            }
            if let dimensions = Node.value(element, kAXSizeAttribute),
               CFGetTypeID(dimensions) == AXValueGetTypeID() {
                AXValueGetValue(dimensions as! AXValue, .cgSize, &size)
            }
            frame = CGRect(origin: origin, size: size)
        }

        private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success
                ? value
                : nil
        }
    }

    /// Breadth-first with a cap, like every other walk in this file's siblings:
    /// an Electron renderer is a large tree and a slow answer is ordinary.
    private static func nodes(in root: AXUIElement) -> [Node] {
        var queue = [root]
        var result: [Node] = []
        var index = 0
        while index < queue.count && result.count < 2_500 {
            let node = Node(queue[index])
            index += 1
            result.append(node)
            queue.append(contentsOf: node.children)
        }
        return result
    }

    /// The window the app calls key, or its first window for an app that
    /// answers with nothing yet.
    private static func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement],
              !windows.isEmpty else { return nil }
        if let focused = attribute(application, kAXFocusedWindowAttribute),
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return (focused as! AXUIElement)
        }
        return windows[0]
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func click(_ frame: CGRect) throws {
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            )
        else { throw AutoPaste.Failure.eventCreationFailed }

        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        usleep(50_000)
        up.post(tap: .cghidEventTap)
    }
}
