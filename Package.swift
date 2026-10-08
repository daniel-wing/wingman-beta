// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Wingman",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.5"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
        // Automatic updates for the direct-download build (left out of the App Store one).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Wingman",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WingmanTests",
            dependencies: ["Wingman"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
