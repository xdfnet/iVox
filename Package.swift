// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iVox",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "iVoxKit",
            dependencies: [],
            swiftSettings: [.unsafeFlags(["-O"])], // 绕开 MLXAudioTTS 在 Swift 6 -O 下的编译器 crash
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
            swiftSettings: [.unsafeFlags(["-O"])], // 绕开 MLXAudioTTS 在 Swift 6 -O 下的编译器 crash
        ),
        .testTarget(
            name: "iVoxTests",
            dependencies: ["iVoxKit"]
        ),
    ]
)
