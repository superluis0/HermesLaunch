// swift-tools-version: 5.9
import PackageDescription

// HermesLaunch builds as a single executable that we then assemble into a
// macOS .app bundle (see build.sh). SwiftPM is used so we can depend on
// FluidAudio (on-device Parakeet ASR + TTS, runs on the Apple Neural Engine).
let package = Package(
    name: "HermesLaunch",
    platforms: [
        .macOS(.v14)   // FluidAudio requires macOS 14; ScreenCaptureKit audio + CoreML baseline
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .executableTarget(
            name: "HermesLaunch",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: ".",
            // Everything that isn't part of the app binary. The standalone icon
            // generator (make_icon.swift) has its own top-level code and must not
            // be compiled into the app, and the bundle/asset files aren't sources.
            exclude: [
                "make_icon.swift",
                "make_icons.sh",
                "make_screenshots.sh",
                "build.sh",
                "Info.plist",
                "README.md",
                "LICENSE",
                "AppIcon.icns",
                "icon_1024.png",
                "assets",
                "HermesLaunch.iconset",
                "HermesLaunch.app",
            ]
        )
    ]
)
