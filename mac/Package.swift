// swift-tools-version:5.10
// STTpro for macOS — menu-bar push-to-talk dictation.
//
// Build an app bundle with `scripts/build-app.sh` (uses xcodebuild when full
// Xcode is installed, otherwise SwiftPM from the Command Line Tools).
import PackageDescription

let package = Package(
    name: "STTpro",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "STTpro", targets: ["STTpro"]),
    ],
    targets: [
        // Platform-neutral logic: settings model, providers, history, keychain.
        .target(
            name: "STTproCore",
            path: "Sources/STTproCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // AppKit/SwiftUI menu-bar app: hotkeys, audio, paste, windows.
        .executableTarget(
            name: "STTpro",
            dependencies: ["STTproCore"],
            path: "Sources/STTpro",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "STTproCoreTests",
            dependencies: ["STTproCore"],
            path: "Tests/STTproCoreTests"
        ),
    ]
)
