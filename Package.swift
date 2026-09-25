// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AgentHUD",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentHUD", targets: ["AgentHUD"]),
        .executable(name: "agenthud-report", targets: ["agenthud-report"]),
    ],
    targets: [
        .target(name: "AgentHUDCore"),
        .executableTarget(name: "agenthud-report", dependencies: ["AgentHUDCore"]),
        .executableTarget(name: "AgentHUD", dependencies: ["AgentHUDCore"]),
        .testTarget(name: "AgentHUDCoreTests", dependencies: ["AgentHUDCore"]),
    ]
)
