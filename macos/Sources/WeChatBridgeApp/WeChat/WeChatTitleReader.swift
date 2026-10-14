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

    private static func readFromAccessibility(pid: pid_t) -> GroupTitleParser.Title? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)

        var queue = [application]
        var index = 0
        var memberCount: Int?
        while index < queue.count && index < 600 {
            let element = queue[index]
            index += 1

            if let identifier = attribute(element, kAXIdentifierAttribute) as? String {
                if identifier == "current_chat_name_label",
                   let name = nonEmpty(attribute(element, kAXValueAttribute) as? String) {
                    return GroupTitleParser.Title(name: name, memberCount: memberCount)
                }
                if identifier == "current_chat_count_label",
                   let value = attribute(element, kAXValueAttribute) as? String {
                    memberCount = Int(value.filter(\.isNumber))
                }
            }

            queue.append(contentsOf: (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
        }
        return nil
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
