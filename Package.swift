// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XboxAgentRemote",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "XboxAgentRemote", targets: ["XboxAgentRemote"])],
    targets: [
        .target(name: "RemoteCore"),
        .executableTarget(name: "XboxAgentRemote", dependencies: ["RemoteCore"]),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"])
    ],
    swiftLanguageVersions: [.v5]
)
