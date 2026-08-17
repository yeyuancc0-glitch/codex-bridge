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
        .library(name: "BridgeCoordinator", targets: ["BridgeCoordinator"]),
        .library(name: "BridgeGit", targets: ["BridgeGit"]),
        .library(name: "BridgeReporting", targets: ["BridgeReporting"]),
        .library(name: "BridgeSupervisor", targets: ["BridgeSupervisor"]),
        .library(name: "BridgeRepositories", targets: ["BridgeRepositories"]),
        .library(name: "BridgeRuntime", targets: ["BridgeRuntime"]),
        .library(name: "BridgePipeline", targets: ["BridgePipeline"]),
        .library(name: "BridgeApplication", targets: ["BridgeApplication"]),
        .library(name: "BridgeVerification", targets: ["BridgeVerification"]),
        .library(name: "BridgeFiles", targets: ["BridgeFiles"]),
        .library(name: "BridgePresentation", targets: ["BridgePresentation"]),
        .library(name: "BridgeAppModel", targets: ["BridgeAppModel"]),
        .library(name: "BridgeAppShell", targets: ["BridgeAppShell"]),
        .library(name: "BridgeMCP", targets: ["BridgeMCP"]),
        .library(name: "BridgeTunnel", targets: ["BridgeTunnel"]),
        .library(name: "BridgeServiceCore", targets: ["BridgeServiceCore"]),
        .library(name: "BridgeCodexService", targets: ["BridgeCodexService"]),
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
            name: "BridgeCoordinator",
            dependencies: ["BridgeDomain", "BridgePersistence", "BridgeProjects"]
        ),
        .target(name: "BridgeGit"),
        .target(name: "BridgeReporting"),
        .target(
            name: "BridgeSupervisor",
            dependencies: ["BridgeCodexRPC", "BridgeSecurity"]
        ),
        .target(
            name: "BridgeRepositories",
            dependencies: [
                "BridgeDomain",
                "BridgePersistence",
                "BridgeSecurity",
                "BridgeProjects",
                "BridgeExecution",
                "BridgeReporting",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "BridgeRuntime",
            dependencies: [
                "BridgeCodexRPC",
                "BridgeCoordinator",
                "BridgeDomain",
                "BridgeProjects",
                "BridgeSecurity",
            ]
        ),
        .target(
            name: "BridgePipeline",
            dependencies: [
                "BridgeCoordinator",
                "BridgeDomain",
                "BridgeGit",
                "BridgePersistence",
                "BridgeProjects",
                "BridgeReporting",
                "BridgeRepositories",
                "BridgeSecurity",
                "BridgeSupervisor",
                "BridgeVerification",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "BridgeApplication",
            dependencies: [
                "BridgeCodexRPC",
                "BridgeCoordinator",
                "BridgeDomain",
                "BridgeFiles",
                "BridgeMCP",
                "BridgePersistence",
                "BridgeProjects",
                "BridgeReporting",
                "BridgeRepositories",
                "BridgeSecurity",
            ]
        ),
        .target(
            name: "BridgeVerification",
            dependencies: ["BridgeProjects", "BridgeSecurity", "BridgePolicy"]
        ),
        .target(
            name: "BridgeFiles",
            dependencies: ["BridgeDomain", "BridgeSecurity", "BridgeProjects"]
        ),
        .target(name: "BridgePresentation"),
        .target(
            name: "BridgeAppModel",
            dependencies: ["BridgePresentation"]
        ),
        .target(
            name: "BridgeAppShell",
            dependencies: [
                "BridgeApplication",
                "BridgeAppModel",
                "BridgeCodexRPC",
                "BridgeCoordinator",
                "BridgeDomain",
                "BridgeGit",
                "BridgeMCP",
                "BridgePipeline",
                "BridgePersistence",
                "BridgePresentation",
                "BridgeProjects",
                "BridgeRepositories",
                "BridgeReporting",
                "BridgeRuntime",
                "BridgeSecurity",
                "BridgeSupervisor",
                "BridgeTunnel",
                "BridgeVerification",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .target(
            name: "BridgeMCP",
            dependencies: [
                "BridgeDomain",
                "BridgeSecurity",
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
        .target(
            name: "BridgeServiceCore",
            dependencies: [
                "BridgeDomain",
                "BridgeProjects",
                "BridgeSecurity",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "BridgeCodexService",
            dependencies: [
                "BridgeCodexRPC",
                "BridgeDomain",
                "BridgeProjects",
                "BridgeSecurity",
                "BridgeServiceCore",
            ]
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
            name: "BridgeCoordinatorTests",
            dependencies: ["BridgeCoordinator", "BridgePersistence"]
        ),
        .testTarget(
            name: "BridgeGitTests",
            dependencies: ["BridgeGit"]
        ),
        .testTarget(
            name: "BridgeReportingTests",
            dependencies: ["BridgeReporting"]
        ),
        .testTarget(
            name: "BridgeSupervisorTests",
            dependencies: ["BridgeCodexRPC", "BridgeSecurity", "BridgeSupervisor"]
        ),
        .testTarget(
            name: "BridgeRepositoriesTests",
            dependencies: [
                "BridgeRepositories",
                "BridgePersistence",
                "BridgeDomain",
                "BridgeSecurity",
                "BridgeProjects",
                "BridgeExecution",
                "BridgeReporting",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "BridgeRuntimeTests",
            dependencies: [
                "BridgeRuntime",
                "BridgeCodexRPC",
                "BridgeCoordinator",
                "BridgeDomain",
                "BridgeProjects",
                "BridgeSecurity",
            ]
        ),
        .testTarget(
            name: "BridgePipelineTests",
            dependencies: [
                "BridgePipeline",
                "BridgeCoordinator",
                "BridgeDomain",
                "BridgeGit",
                "BridgePersistence",
                "BridgeProjects",
                "BridgeReporting",
                "BridgeRepositories",
                "BridgeSecurity",
                "BridgeSupervisor",
                "BridgeVerification",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "BridgeApplicationTests",
            dependencies: [
                "BridgeApplication",
                "BridgeCodexRPC",
                "BridgeCoordinator",
                "BridgeDomain",
                "BridgeFiles",
                "BridgeMCP",
                "BridgePersistence",
                "BridgeProjects",
                "BridgeReporting",
                "BridgeRepositories",
                "BridgeSecurity",
            ]
        ),
        .testTarget(
            name: "BridgeVerificationTests",
            dependencies: [
                "BridgeVerification",
                "BridgeDomain",
                "BridgeProjects",
                "BridgeSecurity",
            ]
        ),
        .testTarget(
            name: "BridgeFilesTests",
            dependencies: ["BridgeFiles", "BridgeDomain", "BridgeProjects", "BridgeSecurity"]
        ),
        .testTarget(
            name: "BridgePresentationTests",
            dependencies: ["BridgePresentation"]
        ),
        .testTarget(
            name: "BridgeAppModelTests",
            dependencies: ["BridgeAppModel", "BridgePresentation"]
        ),
        .testTarget(
            name: "BridgeAppShellTests",
            dependencies: [
                "BridgeAppShell",
                "BridgeApplication",
                "BridgeAppModel",
                "BridgeCodexRPC",
                "BridgeCoordinator",
                "BridgeDomain",
                "BridgeGit",
                "BridgeMCP",
                "BridgePipeline",
                "BridgePersistence",
                "BridgePresentation",
                "BridgeProjects",
                "BridgeRepositories",
                "BridgeRuntime",
                "BridgeSecurity",
                "BridgeTunnel",
                "BridgeVerification",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "BridgeMCPTests",
            dependencies: [
                "BridgeMCP",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
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
        .testTarget(
            name: "BridgeServiceCoreTests",
            dependencies: [
                "BridgeDomain",
                "BridgeProjects",
                "BridgeServiceCore",
                "BridgeSecurity",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "BridgeCodexServiceTests",
            dependencies: [
                "BridgeCodexRPC",
                "BridgeCodexService",
                "BridgeDomain",
                "BridgeProjects",
                "BridgeSecurity",
                "BridgeServiceCore",
            ]
        ),
    ]
)
