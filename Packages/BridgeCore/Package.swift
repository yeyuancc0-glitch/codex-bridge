// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "BridgeCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "BridgeDomain", targets: ["BridgeDomain"]),
    .library(name: "BridgeSecurity", targets: ["BridgeSecurity"]),
    .library(name: "BridgeCodexRPC", targets: ["BridgeCodexRPC"]),
    .library(name: "BridgeProjects", targets: ["BridgeProjects"]),
    .library(name: "BridgeGit", targets: ["BridgeGit"]),
    .library(name: "BridgeSupervisor", targets: ["BridgeSupervisor"]),
    .library(name: "BridgeFiles", targets: ["BridgeFiles"]),
    .library(name: "BridgeMCP", targets: ["BridgeMCP"]),
    .library(name: "BridgeTunnel", targets: ["BridgeTunnel"]),
    .library(name: "BridgeServiceCore", targets: ["BridgeServiceCore"]),
    .library(name: "BridgeSkills", targets: ["BridgeSkills"]),
    .library(name: "BridgeLegacyImport", targets: ["BridgeLegacyImport"]),
    .library(name: "BridgeCodexService", targets: ["BridgeCodexService"]),
    .library(name: "BridgeAgentCore", targets: ["BridgeAgentCore"]),
    .library(name: "BridgeOpenCodeACP", targets: ["BridgeOpenCodeACP"]),
    .library(name: "BridgeDeepSeekHarnessACP", targets: ["BridgeDeepSeekHarnessACP"]),
    .library(name: "BridgeAntigravityCLI", targets: ["BridgeAntigravityCLI"]),
    .library(name: "BridgeProcess", targets: ["BridgeProcess"]),
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
      name: "BridgeProjects",
      dependencies: ["BridgeDomain", "BridgeSecurity"]
    ),
    .target(name: "BridgeGit"),
    .target(
      name: "BridgeSupervisor",
      dependencies: ["BridgeCodexRPC", "BridgeSecurity"]
    ),
    .target(
      name: "BridgeFiles",
      dependencies: ["BridgeDomain", "BridgeGit", "BridgeSecurity", "BridgeProjects"]
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
        "BridgeAgentCore",
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
        "BridgeAgentCore",
        "BridgeCodexRPC",
        "BridgeDomain",
        "BridgeProjects",
        "BridgeSecurity",
        "BridgeServiceCore",
        "BridgeSupervisor",
      ]
    ),
    .target(
      name: "BridgeAgentCore",
      dependencies: ["BridgeDomain"]
    ),
    .target(
      name: "BridgeACP",
      dependencies: ["BridgeProcess"]
    ),
    .target(
      name: "BridgeOpenCodeACP",
      dependencies: [
        "BridgeACP",
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeProcess",
      ]
    ),
    .target(
      name: "BridgeDeepSeekHarnessACP",
      dependencies: [
        "BridgeACP",
        "BridgeAgentCore",
        "BridgeDomain",
      ],
      resources: [.process("Resources")]
    ),
    .target(
      name: "BridgeAntigravityCLI",
      dependencies: [
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeProcess",
        "BridgeSecurity",
      ]
    ),
    .target(
      name: "BridgeServiceApplication",
      dependencies: [
        "BridgeAgentCore",
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
    .target(name: "BridgeProcess"),
    .target(
      name: "BridgeDirectCommand",
      dependencies: [
        "BridgeDomain",
        "BridgeProcess",
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
        "BridgeAgentCore",
        "BridgeAntigravityCLI",
        "BridgeCodexRPC",
        "BridgeCodexService",
        "BridgeDirectCommand",
        "BridgeDomain",
        "BridgeDeepSeekHarnessACP",
        "BridgeLegacyImport",
        "BridgeIPC",
        "BridgeMCP",
        "BridgeOpenCodeACP",
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
