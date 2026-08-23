// swift-tools-version: 6.1

import PackageDescription

// Shared targets compile on every host platform. Their dependency edges must
// stay free of platform-only frameworks; platform bindings live in the
// BridgePlatform* / BridgeIPC* transport targets composed per host below.
let cryptoDependencies: [Target.Dependency] = [
  .product(name: "Crypto", package: "swift-crypto")
]

let bridgeDependencies: [Package.Dependency] = [
  // Temporary pinned fork: upstream 0.12.1 (a0ae212) plus exactly one commit
  // (5d58f77, upstream PR #271) that gates EventSource/FoundationNetworking on
  // canImport so the MCP target compiles for Windows (upstream issue #261).
  // No selection change on Apple/Linux. Drop this fork for an official
  // release as soon as one contains the fix.
  .package(
    url: "https://github.com/LionheartTechnology/swift-sdk.git",
    revision: "5d58f7763e9de3fff5e7785350dfe04c7a315290"
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
    exact: "4.5.1"
  ),
]

let sharedTargets: [Target] = [
  .target(name: "BridgePlatform"),
  .target(name: "BridgeDomain"),
  .target(
    name: "BridgeProcessRuntime",
    dependencies: ["BridgePlatform"]
  ),
  .target(
    name: "BridgeCodexRPC",
    dependencies: ["BridgeProcessRuntime"]
  ),
  .target(
    name: "BridgePersistence",
    dependencies: [
      "BridgeDomain",
      .product(name: "GRDB", package: "GRDB.swift"),
      .product(name: "Logging", package: "swift-log"),
    ] + cryptoDependencies
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
    dependencies: [
      "BridgeDomain",
      "BridgePersistence",
      "BridgeProjects",
    ] + cryptoDependencies
  ),
  .target(
    name: "BridgeGit",
    dependencies: cryptoDependencies
  ),
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
    ] + cryptoDependencies
  ),
  .target(
    name: "BridgeRuntime",
    dependencies: [
      "BridgeCodexRPC",
      "BridgeCoordinator",
      "BridgeDomain",
      "BridgeProjects",
      "BridgeSecurity",
    ] + cryptoDependencies
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
    ] + cryptoDependencies
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
    dependencies: [
      "BridgeProjects",
      "BridgeSecurity",
      "BridgePolicy",
    ] + cryptoDependencies
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
    dependencies: ["BridgeSecurity"] + cryptoDependencies
  ),
  .target(
    name: "BridgeServiceCore",
    dependencies: [
      "BridgeDomain",
      "BridgeProjects",
      "BridgeSecurity",
      .product(name: "GRDB", package: "GRDB.swift"),
    ] + cryptoDependencies
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
    ] + cryptoDependencies
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
    ] + cryptoDependencies
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
    ] + cryptoDependencies
  ),
  .target(
    name: "BridgeDirectCommand",
    dependencies: [
      "BridgeDomain",
      "BridgeProcessRuntime",
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
]

let sharedProducts: [Product] = [
  .library(name: "BridgeDomain", targets: ["BridgeDomain"]),
  .library(name: "BridgePlatform", targets: ["BridgePlatform"]),
]

let sharedTestTargets: [Target] = [
  .testTarget(
    name: "BridgePlatformTests",
    dependencies: ["BridgePlatform"] + cryptoDependencies
  ),
  .testTarget(
    name: "BridgeProcessRuntimeTests",
    dependencies: ["BridgePlatform", "BridgeProcessRuntime"]
  ),
]

#if os(Windows)
  // Windows host: the shared closure verified Windows-clean today, plus the
  // Named Pipe transport unlocked by the pinned MCP SDK fork. Each later
  // porting stage extends this list after its Mac regression passes.
  let windowsTargets: [Target] = [
    .target(name: "BridgeDomain"),
    .target(
      name: "BridgeIPCWindows",
      dependencies: ["BridgePlatform"]
    ),
    .target(
      name: "BridgePlatformWindows",
      dependencies: ["BridgePlatform"]
    ),
    .target(
      name: "BridgeProcessRuntime",
      dependencies: ["BridgePlatform"]
    ),
    .target(
      name: "BridgeCodexRPC",
      dependencies: ["BridgeProcessRuntime"]
    ),
    .target(
      name: "BridgeDirectCommand",
      dependencies: ["BridgeProcessRuntime"],
      path: "Sources/BridgeDirectCommand",
      exclude: [
        "DirectCommandPolicy.swift",
        "DirectCommandSessionManager.swift",
        "DirectSearchArgumentValidator.swift",
      ],
      sources: [
        "DirectCommandOutputBuffer.swift",
        "DirectCommandRunner.swift",
        "DirectGitRunner.swift",
        "DirectProcessLifetime.swift",
        "DirectProcessLifetime+Windows.swift",
      ]
    ),
    .executableTarget(
      name: "WindowsProcessTreeFixture",
      dependencies: ["BridgeProcessRuntime"],
      path: "Tests/WindowsProcessTreeFixture"
    ),
    .target(
      name: "BridgeSecurity",
      dependencies: ["BridgeDomain"] + cryptoDependencies,
      path: "Sources/BridgeSecurity",
      exclude: [
        "KeychainSecretStore.swift",
        "RegisteredRoot.swift",
        "SecureFileReader.swift",
      ]
    ),
    .testTarget(
      name: "BridgeCodexRPCWindowsTests",
      dependencies: ["BridgeCodexRPC", "BridgeProcessRuntime"]
    ),
    .testTarget(
      name: "BridgeDirectCommandWindowsTests",
      dependencies: ["BridgeDirectCommand", "BridgeProcessRuntime"]
    ),
    .testTarget(
      name: "BridgeSecurityWindowsTests",
      dependencies: ["BridgeSecurity"] + cryptoDependencies
    ),
    .testTarget(
      name: "BridgeIPCWindowsTests",
      dependencies: ["BridgeIPCWindows", "BridgePlatform"]
    ),
  ]

  let windowsProducts: [Product] = [
    .library(name: "BridgeCodexRPC", targets: ["BridgeCodexRPC"]),
    .library(name: "BridgeIPCWindows", targets: ["BridgeIPCWindows"]),
    .library(name: "BridgeDirectCommand", targets: ["BridgeDirectCommand"]),
    .library(name: "BridgeProcessRuntime", targets: ["BridgeProcessRuntime"]),
    .library(name: "BridgeSecurity", targets: ["BridgeSecurity"]),
    .executable(
      name: "windows-process-tree-fixture",
      targets: ["WindowsProcessTreeFixture"]
    ),
  ]

  let package = Package(
    name: "BridgeCore",
    platforms: [.macOS(.v14)],
    products: sharedProducts + windowsProducts,
    dependencies: bridgeDependencies,
    targets: [
      .target(name: "BridgePlatform")
    ] + windowsTargets + sharedTestTargets
  )
#else
  // macOS host: full current production closure plus the historical control-plane
  // targets retained until their staged retirement.
  let macOSOnlyTargets: [Target] = [
    .target(
      name: "BridgeSecurity",
      dependencies: ["BridgeDomain"] + cryptoDependencies
    ),
    .target(
      name: "BridgePlatformMacOS",
      dependencies: ["BridgePlatform"]
    ),
    .target(
      name: "BridgeIPCMacOS",
      dependencies: ["BridgeIPC"]
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
      ] + cryptoDependencies
    ),
    .target(
      name: "BridgeServiceHost",
      dependencies: [
        "BridgeCodexRPC",
        "BridgeCodexService",
        "BridgeDirectCommand",
        "BridgeDomain",
        "BridgeIPCMacOS",
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
        "BridgeIPCMacOS",
        "BridgeIPC",
        "BridgeMCP",
      ] + cryptoDependencies
    ),
    .executableTarget(
      name: "CodexBridgeServiceExecutable",
      dependencies: ["BridgeServiceHost"]
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
  ]

  let macOSOnlyProducts: [Product] = [
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
    .library(name: "BridgeIPCMacOS", targets: ["BridgeIPCMacOS"]),
    .executable(name: "codex-bridge-service", targets: ["CodexBridgeServiceExecutable"]),
    .executable(name: "codex-rpc-fixture", targets: ["CodexRPCFixture"]),
    .executable(name: "mcp-inspector-fixture", targets: ["BridgeMCPInspectorFixture"]),
    .executable(name: "bridge-tunnel-fixture", targets: ["BridgeTunnelFixture"]),
    .executable(
      name: "bridge-tunnel-acceptance-fixture",
      targets: ["BridgeTunnelAcceptanceFixture"]
    ),
  ]

  let macOSOnlyTestTargets: [Target] = [
    .testTarget(
      name: "BridgePlatformMacOSTests",
      dependencies: ["BridgePlatform", "BridgePlatformMacOS"]
    ),
    .testTarget(
      name: "BridgeDomainTests",
      dependencies: ["BridgeDomain"]
    ),
    .testTarget(
      name: "BridgeSecurityTests",
      dependencies: ["BridgeSecurity"] + cryptoDependencies
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
      ] + cryptoDependencies
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
      ] + cryptoDependencies
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
      ] + cryptoDependencies
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
      ] + cryptoDependencies
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
      dependencies: [
        "BridgeFiles",
        "BridgeDomain",
        "BridgeProjects",
        "BridgeSecurity",
      ] + cryptoDependencies
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
      dependencies: ["BridgeTunnel"] + cryptoDependencies,
      path: "Tests/BridgeTunnelTests",
      exclude: ["Fixture"]
    ),
    .testTarget(
      name: "BridgeServiceCoreTests",
      dependencies: [
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
      ] + cryptoDependencies
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
      name: "BridgeServiceApplicationTests",
      dependencies: [
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
      ] + cryptoDependencies
    ),
    .testTarget(
      name: "BridgeServiceHostTests",
      dependencies: [
        "BridgeCodexRPC",
        "BridgeDirectCommand",
        "BridgeDomain",
        "BridgeIPCMacOS",
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
      ] + cryptoDependencies
    ),
    .testTarget(
      name: "BridgeServiceAppShellTests",
      dependencies: [
        "BridgeIPCMacOS",
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

  let package = Package(
    name: "BridgeCore",
    platforms: [.macOS(.v14)],
    products: sharedProducts + macOSOnlyProducts,
    dependencies: bridgeDependencies,
    targets: sharedTargets + sharedTestTargets + macOSOnlyTargets + macOSOnlyTestTargets
  )
#endif
