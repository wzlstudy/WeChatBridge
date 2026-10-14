// swift-tools-version: 6.0
import PackageDescription

// WeChatBridge ships a menu bar app, a legacy login-item helper, and the
// `com.apple.share-services` extension in one bundle. SwiftPM has no notion of
// an `.appex` or a nested helper app, so `Scripts/make-app.sh` assembles them.
let package = Package(
    name: "WeChatBridge",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "WeChatBridge", targets: ["WeChatBridgeApp"]),
        .executable(name: "WeChatBridgeShare", targets: ["WeChatBridgeShare"]),
        .executable(name: "WeChatBridgeLoginItem", targets: ["WeChatBridgeLoginItem"]),
        .library(name: "WeChatBridgeCore", targets: ["WeChatBridgeCore"]),
    ],
    dependencies: [
        // Only the app links it. The extensions never update anything, and a
        // framework inside an appex would be a second copy to sign and notarise.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.6"),
    ],
    targets: [
        // Built with `-application-extension` on purpose: the shared inbox code
        // runs inside the share extension, and the compiler is the only thing
        // that reliably catches an API that is unavailable there.
        .target(
            name: "WeChatBridgeCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-application-extension"]),
            ]
        ),
        .executableTarget(
            name: "WeChatBridgeApp",
            dependencies: [
                "WeChatBridgeCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // An app extension has no `main`: dyld enters at `NSExtensionMain`,
        // which reads `NSExtensionPrincipalClass` from the appex Info.plist.
        // Xcode expresses this as `-e _NSExtensionMain`; SwiftPM needs the same
        // flag spelled out, plus an (empty) main.swift so the target still
        // satisfies SwiftPM's executable rule.
        .executableTarget(
            name: "WeChatBridgeShare",
            dependencies: ["WeChatBridgeCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-application-extension"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                    "-Xlinker", "-application_extension",
                ])
            ]
        ),
        .executableTarget(
            name: "WeChatBridgeLoginItem",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WeChatBridgeDeliveryTests",
            dependencies: ["WeChatBridgeApp", "WeChatBridgeCore"],
            path: "Tests",
            exclude: ["WeChatBridgeCoreTests", "WeChatBridgeAppTests"],
            sources: ["DeliveryNotifierTests.swift", "KnowledgeDeliveryTests.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WeChatBridgeCoreTests",
            dependencies: ["WeChatBridgeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WeChatBridgeAppTests",
            dependencies: ["WeChatBridgeApp", "WeChatBridgeCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
