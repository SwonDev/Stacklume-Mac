// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StacklumeCore",
    defaultLocalization: "es",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "StacklumeCore", targets: ["StacklumeCore"])
    ],
    targets: [
        .target(name: "StacklumeCore", resources: [.process("Resources")]),
        .testTarget(name: "StacklumeCoreTests", dependencies: ["StacklumeCore"])
    ]
)
