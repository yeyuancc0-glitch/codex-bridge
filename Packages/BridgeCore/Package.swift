// swift-tools-version: 6.1

import PackageDescription

var testTargets: [Target] = [
  .testTarget(
    name: "BridgeDomainTests",
    dependencies: ["BridgeDomain"]
  ),
  .testTarget(
    name: "BridgeAgentCoreTests",
    dependencies: ["BridgeAgentCore", "BridgeServiceCore"]
  ),
  .testTarget(
    name: "BridgeServiceAppCoreTests",
    dependencies: ["BridgeIPC", "BridgeMCP", "BridgeServiceAppCore"]
  ),
]

var macOSOnlyProducts: [Product] = []
var macOSOnlyTargets: [Target] = []

#if !os(Windows)
  testTargets += [
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
  macOSOnlyProducts = [
    .library(name: "BridgeServiceAppShell", targets: ["BridgeServiceAppShell"]),
    .executable(name: "bridge-tunnel-fixture", targets: ["BridgeTunnelFixture"]),
    .executable(
      name: "bridge-tunnel-acceptance-fixture",
      targets: ["BridgeTunnelAcceptanceFixture"]
    ),
    .executable(name: "mcp-inspector-fixture", targets: ["BridgeMCPInspectorFixture"]),
  ]
  macOSOnlyTargets = [
    .target(
      name: "BridgeServiceAppShell",
      dependencies: [
        "BridgeIPC",
        "BridgeMCP",
        "BridgeServiceAppCore",
      ]
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
    .executableTarget(
      name: "BridgeMCPInspectorFixture",
      dependencies: ["BridgeMCP"],
      path: "Tests/BridgeMCPInspectorFixture"
    ),
  ]
#endif

#if os(Windows)
  testTargets += [
    .testTarget(
      name: "BridgeServiceHostWindowsTests",
      dependencies: ["BridgeIPC", "BridgeServiceHost"],
      path: "Tests/BridgeServiceHostWindowsTests"
    ),
    .testTarget(
      name: "BridgeSecurityTests",
      dependencies: ["BridgeSecurity"],
      path: "Tests/BridgeSecurityTests",
      exclude: [
        "KeychainSecretStoreTests.swift",
        "PathSecurityTests.swift",
        "SecureFileArtifactSnapshotTests.swift",
      ]
    ),
    .testTarget(
      name: "BridgeCodexRPCTests",
      dependencies: ["BridgeCodexRPC"],
      path: "Tests/BridgeCodexRPCTests",
      exclude: [
        "AccountMethodsTests.swift",
        "CodexApprovalWireDecoderTests.swift",
        "FakeAppServerTests.swift",
        "RPCValueTests.swift",
        "ThreadCatalogMethodsTests.swift",
        "TypedCodexMethodsTests.swift",
      ]
    ),
    .testTarget(
      name: "BridgeCodexServiceWindowsTests",
      dependencies: ["BridgeCodexService"],
      path: "Tests/BridgeCodexServiceWindowsTests"
    ),
    .testTarget(
      name: "BridgeServiceApplicationWindowsTests",
      dependencies: ["BridgeIPC", "BridgeServiceApplication"],
      path: "Tests/BridgeServiceApplicationWindowsTests"
    ),
    .testTarget(
      name: "BridgeServiceCoreWindowsTests",
      dependencies: [
        "BridgeServiceCore",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Tests/BridgeServiceCoreTests",
      sources: ["ServiceStoreSchemaV15MigrationTests.swift"]
    ),
    .testTarget(
      name: "BridgeDirectCommandWindowsTests",
      dependencies: ["BridgeDirectCommand"],
      path: "Tests/BridgeDirectCommandWindowsTests"
    ),
  ]
#endif

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
    .library(name: "BridgeWindowsShell", targets: ["BridgeWindowsShell"]),
    .executable(name: "codex-bridge-service", targets: ["CodexBridgeServiceExecutable"]),
    .executable(
      name: "codex-bridge-windows-app",
      targets: ["CodexBridgeWindowsApp"]
    ),
    .executable(name: "codex-rpc-fixture", targets: ["CodexRPCFixture"]),
  ] + macOSOnlyProducts,
  dependencies: [
    // Vendored MCP swift-sdk 0.12.1: upstream excludes the EventSource
    // dependency on Windows while importing it unconditionally, which breaks
    // windows builds; the vendored copy guards the import. Revisit when
    // upstream ships Windows support.
    .package(path: "../../Vendor/swift-sdk"),
    .package(
      url: "https://github.com/groue/GRDB.swift.git",
      exact: "7.11.1"
    ),
    .package(
      url: "https://github.com/apple/swift-log.git",
      exact: "1.15.0"
    ),
    // Upstream 2.101.3 plus one Windows-only wakeup change. Windows package
    // identities and shutdown paths require a loopback TCP pair instead of
    // the upstream AF_UNIX pair. Drop the fork after upstream ships it.
    .package(
      url: "https://github.com/yeyuancc0-glitch/swift-nio.git",
      revision: "1a69138cb7f2e63de709c9716e0348ffd6522ac7"
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
        "BridgeAgentCore",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "BridgeCodexRPC",
      dependencies: ["BridgeAgentCore", "BridgeSecurity"]
    ),
    .target(
      name: "BridgeProjects",
      dependencies: ["BridgeAgentCore", "BridgeDomain", "BridgeSecurity"]
    ),
    .target(
      name: "BridgeGit",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .target(
      name: "BridgeSupervisor",
      dependencies: ["BridgeCodexRPC", "BridgeSecurity"]
    ),
    .target(
      name: "BridgeFiles",
      dependencies: [
        "BridgeAgentCore",
        "BridgeDomain",
        "BridgeGit",
        "BridgeSecurity",
        "BridgeProjects",
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
      dependencies: ["BridgeAgentCore", "BridgeSecurity"]
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
        "BridgeProcess",
        "BridgeSecurity",
        .product(name: "Crypto", package: "swift-crypto"),
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
        "BridgeAgentCore",
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
        "BridgeMCP",
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
  ] + macOSOnlyTargets + testTargets
)
