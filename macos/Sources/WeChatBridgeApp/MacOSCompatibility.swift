import AppKit
import SwiftUI

enum SettingsKeyCommand: Equatable {
    case up
    case down
    case left
    case right
    case activate
    case space
}

extension View {
    @ViewBuilder
    func settingsScrollBounceBasedOnSize() -> some View {
        if #available(macOS 13.3, *) {
            self.scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }

    @ViewBuilder
    func settingsTopScrollAnchor() -> some View {
        if #available(macOS 14.0, *) {
            self.defaultScrollAnchor(.top)
        } else {
            self
        }
    }

    /// The hover signal a settings row highlights itself on.
    ///
    /// `onContinuousHover`'s coordinate-space overload is macOS 14; below that
    /// the enter event carries the same signal, because both rows that use this
    /// read the pointer from `NSEvent.mouseLocation` themselves rather than from
    /// the callback.
    @ViewBuilder
    func settingsPointerHover(_ action: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onContinuousHover { phase in
                guard case .active = phase else { return }
                action()
            }
        } else {
            self.onHover { hovering in
                guard hovering else { return }
                action()
            }
        }
    }

    /// `List` chrome that only exists from Ventura on: the row rules and the
    /// scroll view's own background. Monterey's list draws neither in the plain
    /// style, so there is nothing to hide there.
    @ViewBuilder
    func settingsListRowSeparatorHidden() -> some View {
        if #available(macOS 13.0, *) {
            self.listRowSeparator(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func settingsScrollContentBackgroundHidden() -> some View {
        if #available(macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func settingsDefaultFocus<Value: Hashable>(
        _ binding: FocusState<Value>.Binding,
        _ value: Value
    ) -> some View {
        if #available(macOS 13.0, *) {
            self.defaultFocus(binding, value)
        } else {
            self
        }
    }

    @ViewBuilder
    func settingsFocusEffectDisabled() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }

    func settingsKeyCommands(
        isActive: Bool,
        perform handler: @escaping (SettingsKeyCommand) -> Bool
    ) -> some View {
        modifier(SettingsKeyCommandModifier(isActive: isActive, handler: handler))
    }
}

private struct SettingsKeyCommandModifier: ViewModifier {
    let isActive: Bool
    let handler: (SettingsKeyCommand) -> Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.upArrow) { handler(.up) ? .handled : .ignored }
                .onKeyPress(.downArrow) { handler(.down) ? .handled : .ignored }
                .onKeyPress(.leftArrow) { handler(.left) ? .handled : .ignored }
                .onKeyPress(.rightArrow) { handler(.right) ? .handled : .ignored }
                .onKeyPress(.return) { handler(.activate) ? .handled : .ignored }
                .onKeyPress(.space) { handler(.space) ? .handled : .ignored }
        } else {
            content.background {
                LegacySettingsKeyMonitor(isActive: isActive, handler: handler)
                    .frame(width: 0, height: 0)
            }
        }
    }
}

private struct LegacySettingsKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    let handler: (SettingsKeyCommand) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: isActive, handler: handler)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(isActive: isActive, handler: handler)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private weak var view: NSView?
        private var monitor: Any?
        private var isActive: Bool
        private var handler: (SettingsKeyCommand) -> Bool

        init(isActive: Bool, handler: @escaping (SettingsKeyCommand) -> Bool) {
            self.isActive = isActive
            self.handler = handler
        }

        func attach(to view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isActive,
                      let window = self.view?.window,
                      event.window === window,
                      window.isKeyWindow,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let command = Self.command(for: event)
                else { return event }
                return self.handler(command) ? nil : event
            }
        }

        func update(isActive: Bool, handler: @escaping (SettingsKeyCommand) -> Bool) {
            self.isActive = isActive
            self.handler = handler
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            view = nil
        }

        private static func command(for event: NSEvent) -> SettingsKeyCommand? {
            switch event.keyCode {
            case 126: return .up
            case 125: return .down
            case 123: return .left
            case 124: return .right
            case 36, 76: return .activate
            case 49: return .space
            default: return nil
            }
        }
    }
}

/// The settings fonts as AppKit sees them.
///
/// Monterey has no `ViewThatFits`, so the two panes that fold a row when it runs
/// out of width measure the labels themselves — and a measurement is only worth
/// anything in the font the row is drawn in. These are the twins of
/// `SettingsControlMetrics.font` and `Typo.paneCaption`; keep them in step.
enum SettingsTypeMetrics {
    static let controlFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    static let captionFont = NSFont.systemFont(ofSize: 12)

    /// The width a label needs, rounded up the way text layout rounds.
    static func width(of text: String, in font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The width a `SettingsActionButtonStyle` button takes: the same font, the
    /// same insets and the same floor the style itself applies.
    static func actionButtonWidth(_ title: String) -> CGFloat {
        max(SettingsControlMetrics.actionWidth,
            width(of: title, in: controlFont) + 2 * SettingsControlMetrics.inset)
    }
}

/// `ViewThatFits(in: .horizontal)`, for a row whose caller knows what its wide
/// arrangement needs.
///
/// Ventura lays both arrangements out and keeps the first that fits; Monterey
/// cannot, so the pane is measured instead and the wide arrangement is taken
/// while the width it states is available. The measurement is a two-argument
/// reading of controls whose widths are already fixed.
struct SettingsFittingRow<Wide: View, Narrow: View>: View {
    let wideMinimumWidth: CGFloat
    private let wide: () -> Wide
    private let narrow: () -> Narrow

    /// Until the pane has been measured the wide arrangement is assumed: a
    /// settings pane is written against the window's floor width, and a fold
    /// that appears only after measuring is a fold nobody sees.
    @State private var available: CGFloat = .greatestFiniteMagnitude

    init(
        wideMinimumWidth: CGFloat,
        @ViewBuilder wide: @escaping () -> Wide,
        @ViewBuilder narrow: @escaping () -> Narrow
    ) {
        self.wideMinimumWidth = wideMinimumWidth
        self.wide = wide
        self.narrow = narrow
    }

    var body: some View {
        Group {
            if #available(macOS 13.0, *) {
                ViewThatFits(in: .horizontal) {
                    wide()
                    narrow()
                }
            } else if available >= wideMinimumWidth {
                wide()
            } else {
                narrow()
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { available = proxy.size.width }
                    .onChange(of: proxy.size.width) { value in available = value }
            }
        }
    }
}

/// A settings field that holds several lines.
///
/// Ventura's `TextField` grows with its text (`axis: .vertical` with a line
/// limit); Monterey's field is single-line and its `TextEditor` paints a
/// background of its own, so a borderless `NSTextView` stands in: same surround,
/// same line window, same growth.
struct SettingsMultilineField: View {
    let title: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 5...9

    var body: some View {
        if #available(macOS 13.0, *) {
            TextField(title, text: $text, axis: .vertical)
                .lineLimit(lines)
                .textFieldStyle(SettingsTextFieldStyle(multiline: true))
        } else {
            LegacyMultilineField(text: $text, lines: lines)
        }
    }
}

private struct LegacyMultilineField: View {
    @Binding var text: String
    let lines: ClosedRange<Int>

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @State private var focused = false
    @State private var width: CGFloat = 0

    /// The vertical padding `SettingsTextFieldStyle(multiline: true)` draws with.
    private static let verticalPadding: CGFloat = 6

    var body: some View {
        LegacyTextEditor(text: $text, focused: $focused, isEnabled: isEnabled)
            .frame(height: editorHeight)
            .padding(.horizontal, SettingsControlMetrics.inset)
            .padding(.vertical, Self.verticalPadding)
            .frame(minHeight: SettingsControlMetrics.height)
            .background(hovering && isEnabled ? Theme.hover : Theme.sunken,
                        in: RoundedRectangle(cornerRadius: SettingsControlMetrics.radius))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsControlMetrics.radius)
                    .strokeBorder(focused ? Theme.ink : Theme.inputStroke,
                                  lineWidth: focused ? Stroke.focus : Stroke.hairline)
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .opacity(isEnabled ? 1 : 0.45)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { value in width = value }
                }
            }
    }

    /// The height the text actually takes inside the window the caller asked
    /// for, so the field grows as it is typed and scrolls once it is full.
    private var editorHeight: CGFloat {
        let font = SettingsTypeMetrics.controlFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let wrappingWidth = max(width - 2 * SettingsControlMetrics.inset, 1)
        let measured: CGFloat
        if text.isEmpty {
            measured = lineHeight
        } else {
            measured = ceil((text as NSString).boundingRect(
                with: NSSize(width: wrappingWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            ).height)
        }
        return min(max(measured, CGFloat(lines.lowerBound) * lineHeight),
                   CGFloat(lines.upperBound) * lineHeight)
    }
}

/// The text view behind `LegacyMultilineField`.
private struct LegacyTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var isEnabled: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focused: $focused)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = SettingsTypeMetrics.controlFont
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // A prompt is text to be pasted into somebody else's field verbatim:
        // curly quotes and dashes substituted on the way in would arrive there.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isEditable = isEnabled
        textView.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.isEditable = isEnabled
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let focused: Binding<Bool>

        init(text: Binding<String>, focused: Binding<Bool>) {
            self.text = text
            self.focused = focused
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            focused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            focused.wrappedValue = false
        }
    }
}

