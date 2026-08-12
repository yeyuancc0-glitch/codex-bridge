// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "AppServerProbe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppServerProbeCore", targets: ["AppServerProbeCore"]),
        .executable(name: "app-server-probe", targets: ["AppServerProbe"]),
        .executable(name: "app-server-probe-self-test", targets: ["AppServerProbeSelfTest"]),
    ],
    targets: [
        .target(name: "AppServerProbeCore"),
        .executableTarget(
            name: "AppServerProbe",
            dependencies: ["AppServerProbeCore"]
        ),
        .executableTarget(
            name: "AppServerProbeSelfTest",
            dependencies: ["AppServerProbeCore"]
        ),
        .testTarget(
            name: "AppServerProbeCoreTests",
            dependencies: ["AppServerProbeCore"]
        ),
    ]
)
