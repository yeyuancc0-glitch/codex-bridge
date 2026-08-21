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
    .library(name: "BridgeSkills", targets: ["BridgeSkills"]),
    .library(name: "BridgeLegacyImport", targets: ["BridgeLegacyImport"]),
    .library(name: "BridgeCodexService", targets: ["BridgeCodexService"]),
    .library(name: "BridgeServiceApplication", targets: ["BridgeServiceApplication"]),
    .library(name: "BridgeDirectCommand", targets: ["BridgeDirectCommand"]),
    .library(name: "BridgeIPC", targets: ["BridgeIPC"]),
    .library(name: "BridgeServiceHost", targets: ["BridgeServiceHost"]),
    .library(name: "BridgeServiceAppShell", targets: ["BridgeServiceAppShell"]),
    .executable(name: "codex-bridge-service", targets: ["CodexBridgeServiceExecutable"]),
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
    .target(name: "BridgeSecurity"),
    .target(name: "BridgeCodexRPC"),
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
      dependencies: ["BridgeCodexRPC", "BridgeDomain", "BridgeProjects", "BridgeSecurity"]
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
      dependencies: ["BridgeDomain", "BridgeGit", "BridgeSecurity", "BridgeProjects"]
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
        "BridgeFiles",
        "BridgeSkills",
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
      name: "BridgeSkills",
      dependencies: ["BridgeSecurity"]
    ),
    .target(
      name: "BridgeLegacyImport",
      dependencies: [
        "BridgeDomain",
        "BridgeProjects",
        "BridgeServiceCore",
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
        "BridgeSupervisor",
      ]
    ),
    .target(
      name: "BridgeServiceApplication",
      dependencies: [
        "BridgeCodexRPC",
        "BridgeCodexService",
        "BridgeDirectCommand",
        "BridgeDomain",
        "BridgeFiles",
        "BridgeMCP",
        "BridgeProjects",
        "BridgeSecurity",
        "BridgeServiceCore",
        "BridgeSkills",
      ]
    ),
    .target(
      name: "BridgeDirectCommand",
      dependencies: [
        "BridgeDomain",
        "BridgeProjects",
        "BridgeSecurity",
        "BridgeServiceCore",
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .target(
      name: "BridgeIPC",
      dependencies: ["BridgeMCP"]
    ),
    .target(
      name: "BridgeServiceHost",
      dependencies: [
        "BridgeCodexRPC",
        "BridgeCodexService",
        "BridgeDirectCommand",
        "BridgeDomain",
        "BridgeLegacyImport",
        "BridgeIPC",
        "BridgeMCP",
        "BridgeProjects",
        "BridgeSecurity",
        "BridgeServiceApplication",
        "BridgeServiceCore",
        "BridgeTunnel",
      ]
    ),
    .target(
      name: "BridgeServiceAppShell",
      dependencies: [
        "BridgeIPC",
        "BridgeMCP",
      ]
    ),
    .executableTarget(
      name: "CodexBridgeServiceExecutable",
      dependencies: ["BridgeServiceHost"]
    ),
  ]
)
