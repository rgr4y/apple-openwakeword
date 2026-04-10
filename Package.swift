// swift-tools-version: 5.9
import PackageDescription
import Foundation

let infoPlistPath = URL(fileURLWithPath: #file).deletingLastPathComponent()
    .appendingPathComponent("Sources/AppleSTT/Info.plist").path

let package = Package(
    name: "apple-stt-wyoming",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AppleSTT",
            path: "Sources/AppleSTT",
            exclude: ["Info.plist"],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=minimal"]),
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Speech"),
                .linkedFramework("Network"),
                .unsafeFlags(["-Xlinker", "-sectcreate",
                              "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist",
                              "-Xlinker", infoPlistPath]),
            ]
        )
    ]
)
