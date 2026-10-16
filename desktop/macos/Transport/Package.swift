// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RocamUSB",
    platforms: [.macOS(.v13)],
    products: [.library(name: "RocamUSB", targets: ["RocamUSB"])],
    targets: [
        .target(name: "RocamUSB"),
        .testTarget(name: "RocamUSBTests", dependencies: ["RocamUSB"]),
    ]
)
