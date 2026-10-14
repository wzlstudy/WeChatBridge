import AppKit

@main
enum WeChatBridgeLoginItemMain {
    @MainActor
    static func main() async {
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}
