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
    ],
    targets: [
        .target(
            name: "iVoxKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .executableTarget(
            name: "iVox",
            dependencies: [
                "iVoxKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "iVoxTests",
            dependencies: ["iVoxKit"]
        ),
    ]
)
