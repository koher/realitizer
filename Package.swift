// swift-tools-version: 6.3

import PackageDescription

let approachableConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "Realitizer",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "Realitizer", targets: ["Realitizer"]),
        .library(name: "RealitizerRealityKit", targets: ["RealitizerRealityKit"]),
        .library(name: "RealitizerEnvironment", targets: ["RealitizerEnvironment"]),
        .library(name: "RealitizerEnvironmentRealityKit", targets: ["RealitizerEnvironmentRealityKit"]),
        .library(name: "RealitizerPreview", targets: ["RealitizerPreview"]),
    ],
    targets: [
        .target(name: "RealitizerEnvironment", dependencies: ["Realitizer"], swiftSettings: approachableConcurrency),
        .target(name: "RealitizerEnvironmentRealityKit", dependencies: ["Realitizer", "RealitizerRealityKit", "RealitizerEnvironment"],
                resources: [.process("Shaders")], swiftSettings: approachableConcurrency),
        .testTarget(name: "RealitizerEnvironmentTests", dependencies: ["Realitizer", "RealitizerEnvironment"], swiftSettings: approachableConcurrency),
        .testTarget(name: "RealitizerEnvironmentRealityKitTests",
                    dependencies: ["Realitizer", "RealitizerRealityKit", "RealitizerEnvironment", "RealitizerEnvironmentRealityKit"],
                    swiftSettings: approachableConcurrency),
        .target(
            name: "Realitizer",
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "RealitizerRealityKit",
            dependencies: ["Realitizer"],
            resources: [.process("Shaders")],
            swiftSettings: approachableConcurrency
        ),
        .target(
            name: "RealitizerPreview",
            dependencies: ["Realitizer", "RealitizerRealityKit"],
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "RealitizerTests",
            dependencies: ["Realitizer"],
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "RealitizerRealityKitTests",
            dependencies: ["Realitizer", "RealitizerRealityKit", "RealitizerEnvironment"],
            swiftSettings: approachableConcurrency
        ),
        .testTarget(
            name: "RealitizerPreviewTests",
            dependencies: ["Realitizer", "RealitizerRealityKit", "RealitizerPreview"],
            swiftSettings: approachableConcurrency
        ),
    ],
    swiftLanguageModes: [.v6]
)
