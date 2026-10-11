// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StacklumePersistence",
    defaultLocalization: "es",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "StacklumePersistence", targets: ["StacklumePersistence"])
    ],
    dependencies: [
        .package(path: "../StacklumeCore")
    ],
    targets: [
        .target(
            name: "StacklumePersistence",
            dependencies: [
                .product(name: "StacklumeCore", package: "StacklumeCore")
            ]
        ),
        .testTarget(
            name: "StacklumePersistenceTests",
            dependencies: ["StacklumePersistence"]
        )
    ]
)
