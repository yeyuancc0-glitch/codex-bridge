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
    .library(name: "BridgeServiceAppCore", targets: ["BridgeServiceAppCore"]),
    .library(name: "BridgeServiceAppShell", targets: ["BridgeServiceAppShell"]),
    .library(name: "BridgeWindowsShell", targets: ["BridgeWindowsShell"]),
    .executable(name: "codex-bridge-service", targets: ["CodexBridgeServiceExecutable"]),
    .executable(
      name: "codex-bridge-windows-app",
      targets: ["CodexBridgeWindowsApp"]
    ),
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
    .package(
      url: "https://github.com/apple/swift-crypto.git",
      exact: "3.12.0"
    ),
  ],
  targets: [
    .target(name: "BridgeDomain"),
    .target(
      name: "BridgeSecurity",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(name: "BridgeCodexRPC"),
    .target(
      name: "BridgeProjects",
      dependencies: ["BridgeDomain", "BridgeSecurity"]
    ),
    .target(
      name: "BridgeGit",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
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
      dependencies: [
        "BridgeSecurity",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeServiceCore",
      dependencies: [
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeProjects",
        "BridgeSecurity",
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Crypto", package: "swift-crypto"),
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
        .product(name: "Crypto", package: "swift-crypto"),
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
        .product(name: "Crypto", package: "swift-crypto"),
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
        .product(name: "Crypto", package: "swift-crypto"),
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
        .product(name: "Crypto", package: "swift-crypto"),
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
        .product(name: "Crypto", package: "swift-crypto"),
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
        "BridgeServiceAppCore",
      ]
    ),
    .target(
      name: "BridgeServiceAppCore",
      dependencies: [
        "BridgeIPC",
        "BridgeMCP",
      ]
    ),
    .target(
      name: "BridgeWindowsShell",
      dependencies: [
        "BridgeIPC",
        "BridgeServiceAppCore",
      ]
    ),
    .executableTarget(
      name: "CodexBridgeServiceExecutable",
      dependencies: ["BridgeServiceHost"]
    ),
    .executableTarget(
      name: "CodexBridgeWindowsApp",
      dependencies: [
        "BridgeWindowsShell",
        "BridgeIPC",
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
      name: "BridgeProjectsTests",
      dependencies: ["BridgeProjects"]
    ),
    .testTarget(
      name: "BridgeGitTests",
      dependencies: ["BridgeGit"]
    ),
    .testTarget(
      name: "BridgeSupervisorTests",
      dependencies: ["BridgeCodexRPC", "BridgeSecurity", "BridgeSupervisor"]
    ),
    .testTarget(
      name: "BridgeFilesTests",
      dependencies: ["BridgeFiles", "BridgeDomain", "BridgeProjects", "BridgeSecurity"]
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
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeProjects",
        "BridgeSkills",
        "BridgeServiceCore",
        "BridgeSecurity",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "BridgeLegacyImportTests",
      dependencies: [
        "BridgeDomain",
        "BridgeLegacyImport",
        "BridgeProjects",
        "BridgeSecurity",
        "BridgeServiceCore",
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
        "BridgeSupervisor",
      ]
    ),
    .testTarget(
      name: "BridgeOpenCodeACPTests",
      dependencies: [
        "BridgeACP",
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeOpenCodeACP",
      ]
    ),
    .testTarget(
      name: "BridgeACPTests",
      dependencies: ["BridgeACP"]
    ),
    .testTarget(
      name: "BridgeDeepSeekHarnessACPTests",
      dependencies: [
        "BridgeACP",
        "BridgeAgentCore",
        "BridgeCodexService",
        "BridgeDeepSeekHarnessACP",
        "BridgeDomain",
        "BridgeProjects",
        "BridgeServiceCore",
      ]
    ),
    .testTarget(
      name: "BridgeAntigravityCLITests",
      dependencies: [
        "BridgeAgentCore",
        "BridgeAntigravityCLI",
        "BridgeDomain",
        "BridgeProcess",
      ]
    ),
    .testTarget(
      name: "BridgeServiceApplicationTests",
      dependencies: [
        "BridgeAgentCore",
        "BridgeCodexRPC",
        "BridgeCodexService",
        "BridgeDirectCommand",
        "BridgeDomain",
        "BridgeMCP",
        "BridgeProjects",
        "BridgeSecurity",
        "BridgeServiceApplication",
        "BridgeServiceCore",
        .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
    .testTarget(
      name: "BridgeServiceHostTests",
      dependencies: [
        "BridgeCodexRPC",
        "BridgeDirectCommand",
        "BridgeDomain",
        "BridgeIPC",
        "BridgeLegacyImport",
        "BridgeMCP",
        "BridgeProjects",
        "BridgeSecurity",
        "BridgeServiceApplication",
        "BridgeServiceHost",
        "BridgeServiceCore",
        "BridgeTunnel",
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
    .testTarget(
      name: "BridgeServiceAppShellTests",
      dependencies: [
        "BridgeIPC",
        "BridgeMCP",
        "BridgeServiceAppShell",
      ]
    ),
    .testTarget(
      name: "BridgeDirectCommandTests",
      dependencies: [
        "BridgeDirectCommand",
        "BridgeDomain",
        "BridgeProjects",
        "BridgeSecurity",
        "BridgeServiceCore",
      ]
    ),
  ]
)
