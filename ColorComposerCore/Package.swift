// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ColorComposerCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ColorComposerCore", targets: ["ColorComposerCore"])
    ],
    targets: [
        .target(
            name: "ColorComposerCore",
            path: "Sources/ColorComposerCore"
        ),
        .testTarget(
            name: "ColorComposerCoreTests",
            dependencies: ["ColorComposerCore"],
            path: "Tests/ColorComposerCoreTests"
        )
    ]
)
