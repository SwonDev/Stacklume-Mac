// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StacklumeMetadata",
    defaultLocalization: "es",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "StacklumeMetadata", targets: ["StacklumeMetadata"])
    ],
    dependencies: [
        .package(path: "../StacklumeCore")
    ],
    targets: [
        .target(
            name: "StacklumeMetadata",
            dependencies: [
                .product(name: "StacklumeCore", package: "StacklumeCore")
            ]
        ),
        .testTarget(
            name: "StacklumeMetadataTests",
            dependencies: ["StacklumeMetadata"]
        )
    ]
)
