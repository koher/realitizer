// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "RealitizerConsumer",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "RealitizerConsumer", targets: ["RealitizerConsumer"])],
    dependencies: [.package(name: "Realitizer", path: "../..")],
    targets: [
        .target(name: "RealitizerConsumer", dependencies: [
            .product(name: "Realitizer", package: "Realitizer"),
            .product(name: "RealitizerRealityKit", package: "Realitizer"),
            .product(name: "RealitizerPreview", package: "Realitizer"),
            .product(name: "RealitizerEnvironment", package: "Realitizer"),
            .product(name: "RealitizerEnvironmentRealityKit", package: "Realitizer")
        ]),
        .testTarget(name: "RealitizerConsumerTests", dependencies: ["RealitizerConsumer"])
    ]
)
