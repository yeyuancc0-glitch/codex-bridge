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
    ]
)
