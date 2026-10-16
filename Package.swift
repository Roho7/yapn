// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DictationBench",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DictationCore", targets: ["DictationCore"]),
        .executable(name: "bench", targets: ["bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "DictationCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(
            name: "DictationCoreTests",
            dependencies: ["DictationCore"]
        ),
        .executableTarget(
            name: "bench",
            dependencies: [
                "DictationCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
