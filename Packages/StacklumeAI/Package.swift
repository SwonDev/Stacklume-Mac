// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StacklumeAI",
    defaultLocalization: "es",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "StacklumeAI", targets: ["StacklumeAI"])
    ],
    dependencies: [
        .package(path: "../StacklumeCore")
    ],
    targets: [
        .target(
            name: "StacklumeAI",
            dependencies: [
                .product(name: "StacklumeCore", package: "StacklumeCore")
            ]
        )
    ]
)
