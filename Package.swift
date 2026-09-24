// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AgentWatch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentWatch", targets: ["AgentWatch"]),
        .executable(name: "agentwatch-report", targets: ["agentwatch-report"]),
    ],
    targets: [
        .target(name: "AgentWatchCore"),
        .executableTarget(name: "agentwatch-report", dependencies: ["AgentWatchCore"]),
        .executableTarget(name: "AgentWatch", dependencies: ["AgentWatchCore"]),
        .testTarget(name: "AgentWatchCoreTests", dependencies: ["AgentWatchCore"]),
    ]
)
