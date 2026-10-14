import AppKit
import WeChatBridgeCore
import Foundation
import ServiceManagement

/// The user-facing "open at login" switch.
///
/// Use the app service on Ventura and newer, and a bundled login helper on
/// Monterey. In either case the switch reflects the registration read from
/// ServiceManagement rather than the last value the user selected.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var lastError: String?

    private static let legacyHelperIdentifier = "com.xiangming.wechatbridge.LoginItem"
    private static let legacyStateKey = "loginItem.legacyEnabled"

    init() { refresh() }

    func refresh() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            isEnabled = status == .enabled
            needsApproval = status == .requiresApproval
        } else {
            isEnabled = Self.legacyLoginItemEnabled
            needsApproval = false
        }
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                lastError = error.localizedDescription
            }
        } else {
            if SMLoginItemSetEnabled(Self.legacyHelperIdentifier as CFString, enabled) {
                UserDefaults.standard.set(enabled, forKey: Self.legacyStateKey)
            } else {
                lastError = L10n.text("无法更改登录启动设置。")
            }
        }
        refresh()
    }

    private static var legacyLoginItemEnabled: Bool {
        guard let jobs = SMCopyAllJobDictionaries(kSMDomainUserLaunchd)?.takeRetainedValue() as? [[String: Any]] else {
            return UserDefaults.standard.bool(forKey: legacyStateKey)
        }
        return jobs.contains { ($0["Label"] as? String) == legacyHelperIdentifier }
    }

    static func openLoginItemsSettings() {
        let settingsURL: String
        if #available(macOS 13.0, *) {
            settingsURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        } else {
            settingsURL = "x-apple.systempreferences:com.apple.preference.users?loginItems"
        }
        guard let url = URL(string: settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    static func openExtensionsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") else { return }
        NSWorkspace.shared.open(url)
    }
}
