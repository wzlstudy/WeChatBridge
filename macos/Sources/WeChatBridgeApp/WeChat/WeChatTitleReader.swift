import AppKit
import ApplicationServices
import CoreGraphics
import WeChatBridgeCore
import Foundation
import Vision

enum WeChatTitleReaderError: Error, LocalizedError {
    case permission
    case noWindow
    case screenshotFailed
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .permission: L10n.text("需要屏幕录制权限才能识别微信群名。")
        case .noWindow: L10n.text("没有找到可见的微信聊天窗口。")
        case .screenshotFailed: L10n.text("无法读取微信标题栏。")
        case .recognitionFailed: L10n.text("没有识别出微信群名。")
        }
    }
}

enum WeChatTitleReader {
    /// WeChat exposes the selected chat through Accessibility. Read that first:
    /// it names the current conversation directly instead of guessing which
    /// window and strip contain it, and it works without Screen Recording.
    /// The image fallback exists for a build that does not publish those labels
    /// and is never written to disk.
    static func read() throws -> GroupTitleParser.Title? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.tencent.xinWeChat"
        ).first else { throw WeChatTitleReaderError.noWindow }

        if let title = readFromAccessibility(pid: app.processIdentifier) {
            return title
        }
        return try readFromWindow(app)
    }

    /// The Accessibility read behind `read()`.
    ///
    /// The label is not unique — every chat-list row carries the same
    /// identifier — so returning the first match in tree order is a coin toss
    /// on which row the walk reaches first. Measured 2026-10-15: a batch came
    /// back filed under `©、QS`, a label the tree handed over ahead of the
    /// header's. The header lives in the window on screen, above every row of
    /// that window's list, so candidates are narrowed to the focused window and
    /// then ranked by their frame; the member count comes from the label that
    /// shares the header's own row.
    private static func readFromAccessibility(pid: pid_t) -> GroupTitleParser.Title? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)

        var queue = [application]
        var index = 0
        var names: [(text: String, frame: CGRect?)] = []
        var counts: [(value: Int, frame: CGRect?)] = []
        while index < queue.count && index < 600 {
            let element = queue[index]
            index += 1

            if let identifier = attribute(element, kAXIdentifierAttribute) as? String {
                if identifier == "current_chat_name_label",
                   let name = nonEmpty(attribute(element, kAXValueAttribute) as? String) {
                    names.append((name, frame(of: element)))
                }
                if identifier == "current_chat_count_label",
                   let value = attribute(element, kAXValueAttribute) as? String,
                   let count = Int(value.filter(\.isNumber)) {
                    counts.append((count, frame(of: element)))
                }
            }

            queue.append(contentsOf: (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
        }

        let window = focusedWindowFrame(of: application)
        let inWindow = { (frame: CGRect?) -> Bool in
            guard let window, let frame else { return false }
            return window.contains(frame)
        }
        // An app that answers with no window frame is left on the whole set:
        // narrowing by nothing would drop every candidate instead.
        let windowNames = names.filter { inWindow($0.frame) }
        let pool = windowNames.isEmpty ? names : windowNames
        let windowCounts = counts.filter { inWindow($0.frame) }
        let countPool = windowCounts.isEmpty ? counts : windowCounts
        guard let header = pool.enumerated().min(by: { lhs, rhs in
            switch (lhs.element.frame?.minY, rhs.element.frame?.minY) {
            case let (left?, right?):
                return left == right ? lhs.offset < rhs.offset : left < right
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        })?.element else { return nil }

        return GroupTitleParser.Title(
            name: header.text,
            memberCount: nearestCount(to: header.frame?.minY, in: countPool)
        )
    }

    /// The frame of the window the app calls key — the one whose conversation
    /// the user is looking at. Nil for an app that answers with nothing.
    private static func focusedWindowFrame(of application: AXUIElement) -> CGRect? {
        guard let focused = attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return frame(of: focused as! AXUIElement)
    }

    /// The count label that shares the header's row.
    ///
    /// The chat list carries one of these per row as well, so a count whose row
    /// is further away than a row is tall belongs to another chat and is
    /// dropped rather than attached to this name.
    private static func nearestCount(
        to minY: CGFloat?,
        in counts: [(value: Int, frame: CGRect?)]
    ) -> Int? {
        guard !counts.isEmpty else { return nil }
        guard let minY else { return counts[0].value }
        // Two list rows are ~45 pt apart (64 against 99 in the strip), so this
        // cannot reach the next one.
        let rowHeight: CGFloat = 30
        return counts
            .compactMap { count -> (value: Int, gap: CGFloat)? in
                guard let other = count.frame?.minY else { return (count.value, 0) }
                return (count.value, abs(other - minY))
            }
            .min { $0.gap < $1.gap }
            .flatMap { $0.gap <= rowHeight ? $0.value : nil }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    /// Fallback for WeChat builds or permissions where the Accessibility labels
    /// are unavailable. The crop is tall enough for WeChat 4's chat header,
    /// which sits below the old 52 pt strip.
    private static func readFromWindow(_ app: NSRunningApplication) throws -> GroupTitleParser.Title? {
        guard CGPreflightScreenCaptureAccess() else { throw WeChatTitleReaderError.permission }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { throw WeChatTitleReaderError.noWindow }

        var best: (id: CGWindowID, area: CGFloat, width: CGFloat)?
        for entry in windows {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pid == app.processIdentifier,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width >= 320, height >= 240
            else { continue }
            let area = width * height
            if best == nil || area > best!.area {
                best = (number.uint32Value, area, width)
            }
        }
        guard let best else { throw WeChatTitleReaderError.noWindow }

        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            best.id,
            [.boundsIgnoreFraming, .bestResolution]
        ) else { throw WeChatTitleReaderError.screenshotFailed }

        let scale = CGFloat(image.width) / max(best.width, 1)
        let titleHeight = min(CGFloat(image.height), max(1, 140 * scale))
        let crop = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(image.width),
            height: titleHeight
        )
        guard let titleImage = image.cropping(to: crop),
              let lines = recognize(titleImage, scale: scale),
              let title = GroupTitleParser.parse(lines, windowWidth: best.width)
        else { throw WeChatTitleReaderError.recognitionFailed }
        return title
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Every line comes back with the place it occupied in the window, in
    /// points: the strip holds the chat list as well as the conversation
    /// header, and only the geometry tells them apart (see
    /// `GroupTitleParser`).
    private static func recognize(_ image: CGImage, scale: CGFloat) -> [GroupTitleParser.Line]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return nil
        }
        let width = CGFloat(image.width) / max(scale, 1)
        let height = CGFloat(image.height) / max(scale, 1)
        let results: [VNRecognizedTextObservation] = request.results ?? []
        return results.compactMap { (observation: VNRecognizedTextObservation) -> GroupTitleParser.Line? in
            guard let text: String = observation.topCandidates(1).first?.string else { return nil }
            let box: CGRect = observation.boundingBox
            // Vision measures from the bottom-left; the parser measures from
            // the top-left corner of the window.
            return GroupTitleParser.Line(
                text: text,
                minX: box.minX * width,
                minY: (1 - box.maxY) * height
            )
        }
    }
}
