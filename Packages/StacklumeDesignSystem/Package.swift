// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StacklumeDesignSystem",
    defaultLocalization: "es",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "StacklumeDesignSystem", targets: ["StacklumeDesignSystem"])
    ],
    targets: [
        .target(name: "StacklumeDesignSystem", resources: [.process("Resources")])
    ]
)
