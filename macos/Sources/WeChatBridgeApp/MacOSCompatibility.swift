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
        if #available(macOS 13.0, *) {
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
