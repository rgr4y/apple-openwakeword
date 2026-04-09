// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "apple-stt-wyoming",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AppleSTT",
            path: "Sources/AppleSTT",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=minimal"])
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("Network"),
            ]
        )
    ]
)
