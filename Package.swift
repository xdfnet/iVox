// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iVox",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-markdown.git", branch: "main"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "iVoxKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            // 队列落盘用系统自带的 SQLite（不引新依赖）
            linkerSettings: [.linkedLibrary("sqlite3")],
        ),
        .executableTarget(
            name: "iVox",
            dependencies: [
                "iVoxKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
            ],
            resources: [.copy("Resources")],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/iVox/Resources/Info.plist",
                ]),
            ],
        ),
        .testTarget(
            name: "iVoxTests",
            dependencies: ["iVoxKit", "iVox"]
        ),
    ]
)
