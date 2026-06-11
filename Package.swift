// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HubProto",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "HubProto", path: "Sources/HubProto")
    ]
)
