// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "BridgeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BridgeDomain", targets: ["BridgeDomain"]),
        .library(name: "BridgeSecurity", targets: ["BridgeSecurity"]),
        .library(name: "BridgeCodexRPC", targets: ["BridgeCodexRPC"]),
        .library(name: "BridgePersistence", targets: ["BridgePersistence"]),
        .library(name: "BridgePolicy", targets: ["BridgePolicy"]),
        .library(name: "BridgeProjects", targets: ["BridgeProjects"]),
        .library(name: "BridgeExecution", targets: ["BridgeExecution"]),
        .library(name: "BridgeMCP", targets: ["BridgeMCP"]),
        .library(name: "BridgeTunnel", targets: ["BridgeTunnel"]),
        .executable(name: "codex-rpc-fixture", targets: ["CodexRPCFixture"]),
        .executable(name: "mcp-inspector-fixture", targets: ["BridgeMCPInspectorFixture"]),
        .executable(name: "bridge-tunnel-fixture", targets: ["BridgeTunnelFixture"]),
        .executable(
            name: "bridge-tunnel-acceptance-fixture",
            targets: ["BridgeTunnelAcceptanceFixture"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        ),
        .package(
            url: "https://github.com/apple/swift-log.git",
            exact: "1.15.0"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.101.3"
        ),
    ],
    targets: [
        .target(name: "BridgeDomain"),
        .target(
            name: "BridgeSecurity",
            dependencies: ["BridgeDomain"]
        ),
        .target(
            name: "BridgeCodexRPC",
            dependencies: [
                "BridgeDomain",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "BridgePersistence",
            dependencies: [
                "BridgeDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "BridgePolicy",
            dependencies: ["BridgeProjects", "BridgeSecurity"]
        ),
        .target(
            name: "BridgeProjects",
            dependencies: ["BridgeDomain", "BridgeSecurity"]
        ),
        .target(
            name: "BridgeExecution",
            dependencies: ["BridgeCodexRPC", "BridgeDomain", "BridgeProjects"]
        ),
        .target(
            name: "BridgeMCP",
            dependencies: [
                "BridgeDomain",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .target(
            name: "BridgeTunnel",
            dependencies: ["BridgeSecurity"]
        ),
        .executableTarget(
            name: "CodexRPCFixture",
            dependencies: ["BridgeCodexRPC"]
        ),
        .executableTarget(
            name: "BridgeMCPInspectorFixture",
            dependencies: ["BridgeMCP"],
            path: "Tests/BridgeMCPInspectorFixture"
        ),
        .executableTarget(
            name: "BridgeTunnelFixture",
            path: "Tests/BridgeTunnelTests/Fixture"
        ),
        .executableTarget(
            name: "BridgeTunnelAcceptanceFixture",
            dependencies: ["BridgeSecurity", "BridgeTunnel"],
            path: "Tests/BridgeTunnelAcceptanceFixture"
        ),
        .testTarget(
            name: "BridgeDomainTests",
            dependencies: ["BridgeDomain"]
        ),
        .testTarget(
            name: "BridgeSecurityTests",
            dependencies: ["BridgeSecurity"]
        ),
        .testTarget(
            name: "BridgeCodexRPCTests",
            dependencies: ["BridgeCodexRPC"]
        ),
        .testTarget(
            name: "BridgePersistenceTests",
            dependencies: ["BridgePersistence"]
        ),
        .testTarget(
            name: "BridgePolicyTests",
            dependencies: ["BridgePolicy"]
        ),
        .testTarget(
            name: "BridgeProjectsTests",
            dependencies: ["BridgeProjects"]
        ),
        .testTarget(
            name: "BridgeExecutionTests",
            dependencies: ["BridgeCodexRPC", "BridgeExecution", "BridgeProjects"]
        ),
        .testTarget(
            name: "BridgeMCPTests",
            dependencies: [
                "BridgeMCP",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "BridgeTunnelTests",
            dependencies: ["BridgeTunnel"],
            path: "Tests/BridgeTunnelTests",
            exclude: ["Fixture"]
        ),
    ]
)
