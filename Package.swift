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
            swiftSettings: [.unsafeFlags(["-O"])], // MLX 依赖用 -Onone（Makefile），自有 target 开 -O 提速
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
            swiftSettings: [.unsafeFlags(["-O"])], // MLX 依赖用 -Onone（Makefile），自有 target 开 -O 提速
        ),
        .testTarget(
            name: "iVoxTests",
            dependencies: ["iVoxKit"]
        ),
    ]
)
