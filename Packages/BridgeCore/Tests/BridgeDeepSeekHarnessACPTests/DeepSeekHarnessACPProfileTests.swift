import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPProfileTests: XCTestCase {
  func testLockedNodeRange() {
    XCTAssertTrue(DeepSeekHarnessACPProfile.isCompatibleNodeVersion("v22.19.0"))
    XCTAssertTrue(DeepSeekHarnessACPProfile.isCompatibleNodeVersion("22.23.1"))
    XCTAssertTrue(DeepSeekHarnessACPProfile.isCompatibleNodeVersion("v24.0.0"))
    XCTAssertFalse(DeepSeekHarnessACPProfile.isCompatibleNodeVersion("v22.18.9"))
    XCTAssertFalse(DeepSeekHarnessACPProfile.isCompatibleNodeVersion("v23.0.0"))
  }

  func testRegistrationDiscoveryReturnsFourCanonicalArtifactsWithoutReadingEnvironmentFiles()
    throws
  {
    let root = try makeTemporaryDirectory(prefix: "deepseek-source")
    let profile = try makeTemporaryDirectory(prefix: "deepseek-profile")
    addTeardownBlock {
      try? FileManager.default.removeItem(atPath: root)
      try? FileManager.default.removeItem(atPath: profile)
    }
    let node = URL(fileURLWithPath: root).appendingPathComponent("node").path
    let executable = URL(fileURLWithPath: root).appendingPathComponent("dsh-acp-demo").path
    let manifest = URL(fileURLWithPath: root).appendingPathComponent("package.json").path
    let lock = URL(fileURLWithPath: root).appendingPathComponent("pnpm-lock.yaml").path
    let configuration = URL(fileURLWithPath: profile).appendingPathComponent("cordis.yml").path
    try makeModuleResolutionDirectory(sourceRoot: root)
    try Data("#!/bin/sh\necho v22.19.0\n".utf8).write(to: URL(fileURLWithPath: node))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: node
    )
    try Data("#!/\(node)\n".utf8).write(to: URL(fileURLWithPath: executable))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable
    )
    try Data(
      "{\"version\":\"0.1.1-rc.2\",\"packageManager\":\"pnpm@11.7.0\",\"engines\":{\"node\":\"^22.19.0 || >=24.0.0\"}}"
        .utf8
    ).write(to: URL(fileURLWithPath: manifest))
    try Data("packages:\n  /@agentclientprotocol/sdk@0.25.1:\n    resolution: {}\n".utf8)
      .write(to: URL(fileURLWithPath: lock))
    try DeepSeekHarnessACPProfile.bundledConfigurationTemplate()
      .write(to: URL(fileURLWithPath: configuration))

    let artifacts = try DeepSeekHarnessACPProfile.resolveArtifacts(
      executablePath: executable,
      configurationPath: configuration,
      sourceEnvironment: ["PATH": "/usr/bin:/bin"]
    )
    XCTAssertEqual(Set(artifacts.keys), Set(AgentInstallationArtifactRole.allCases))
    XCTAssertEqual(artifacts[.runtimeManifest], manifest)
    XCTAssertEqual(artifacts[.dependencyLock], lock)
    XCTAssertEqual(artifacts[.launchConfiguration], configuration)
    XCTAssertFalse(artifacts.values.contains { $0.hasSuffix(".env") })
  }

  func testDependencyLockRequiresExactSDKVersion() throws {
    let fixture = try makeProfileFixture(
      prefix: "deepseek-sdk-prefix",
      lockVersion: "0.25.10"
    )
    addTeardownBlock { fixture.remove() }

    XCTAssertThrowsError(
      try DeepSeekHarnessACPProfile.resolveArtifacts(
        executablePath: fixture.executable,
        configurationPath: fixture.configuration,
        sourceEnvironment: ["PATH": "/usr/bin:/bin"]
      )
    ) { error in
      XCTAssertEqual(
        error as? DeepSeekHarnessACPError,
        .artifactInvalid("dependency_lock.acp_sdk")
      )
    }
  }

  func testRegistrationDiscoveryResolvesEnvNodeShebangWithoutFreezingEnvTool() throws {
    let fixture = try makeProfileFixture(prefix: "deepseek-env-node")
    addTeardownBlock { fixture.remove() }
    try Data("#!/usr/bin/env node\n".utf8).write(
      to: URL(fileURLWithPath: fixture.executable)
    )

    let artifacts = try DeepSeekHarnessACPProfile.resolveArtifacts(
      executablePath: fixture.executable,
      configurationPath: fixture.configuration,
      sourceEnvironment: ["PATH": fixture.root]
    )

    let node = try XCTUnwrap(artifacts[.nodeInterpreter])
    XCTAssertEqual(URL(fileURLWithPath: node).lastPathComponent, "node")
    XCTAssertNotEqual(node, "/usr/bin/env")
  }

  func testNodeVersionProbeHasABoundedTimeout() throws {
    let fixture = try makeProfileFixture(
      prefix: "deepseek-node-timeout",
      nodeScript: "#!/bin/sh\nwhile :; do :; done\n"
    )
    addTeardownBlock { fixture.remove() }
    let start = ContinuousClock.now

    XCTAssertThrowsError(
      try DeepSeekHarnessACPProfile.resolveArtifacts(
        executablePath: fixture.executable,
        configurationPath: fixture.configuration,
        sourceEnvironment: ["PATH": "/usr/bin:/bin"]
      )
    ) { error in
      XCTAssertEqual(error as? DeepSeekHarnessACPError, .processUnavailable)
    }
    XCTAssertLessThan(start.duration(to: .now), .seconds(8))
  }

  func testRuntimeProfileStagesManagedTemplateWithWorkspaceModuleResolution() throws {
    let fixture = try makeProfileFixture(prefix: "deepseek-runtime-profile")
    let runDirectory = try makeTemporaryDirectory(prefix: "deepseek-runtime")
    addTeardownBlock {
      fixture.remove()
      try? FileManager.default.removeItem(atPath: runDirectory)
    }
    let stagedConfiguration = try DeepSeekHarnessACPLaunchBuilder().prepareRuntimeProfile(
      sourceRoot: fixture.root,
      runDirectory: runDirectory
    )

    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: stagedConfiguration)),
      try DeepSeekHarnessACPProfile.bundledConfigurationTemplate()
    )
    XCTAssertTrue(stagedConfiguration.hasPrefix(runDirectory + "/profile/"))
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: URL(fileURLWithPath: runDirectory)
          .appendingPathComponent("profile/node_modules").path
      ),
      URL(fileURLWithPath: fixture.root)
        .appendingPathComponent("node_modules/.pnpm/node_modules").path
    )
  }

  private func makeProfileFixture(
    prefix: String,
    lockVersion: String = "0.25.1",
    nodeScript: String = "#!/bin/sh\necho v22.19.0\n"
  ) throws -> ProfileFixture {
    let root = try makeTemporaryDirectory(prefix: "\(prefix)-source")
    let profile = try makeTemporaryDirectory(prefix: "\(prefix)-profile")
    let node = URL(fileURLWithPath: root).appendingPathComponent("node").path
    let executable = URL(fileURLWithPath: root).appendingPathComponent("dsh-acp-demo").path
    try Data(nodeScript.utf8).write(to: URL(fileURLWithPath: node))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node)
    try Data("#!\(node)\n".utf8).write(to: URL(fileURLWithPath: executable))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable
    )
    try Data(
      "{\"version\":\"0.1.1-rc.2\",\"packageManager\":\"pnpm@11.7.0\",\"engines\":{\"node\":\"^22.19.0 || >=24.0.0\"}}"
        .utf8
    ).write(to: URL(fileURLWithPath: root).appendingPathComponent("package.json"))
    try Data(
      "packages:\n  /@agentclientprotocol/sdk@\(lockVersion):\n    resolution: {}\n".utf8
    ).write(to: URL(fileURLWithPath: root).appendingPathComponent("pnpm-lock.yaml"))
    try makeModuleResolutionDirectory(sourceRoot: root)
    let configuration = URL(fileURLWithPath: profile).appendingPathComponent("cordis.yml")
    try DeepSeekHarnessACPProfile.bundledConfigurationTemplate().write(to: configuration)
    return ProfileFixture(
      root: root,
      profile: profile,
      executable: executable,
      configuration: configuration.path
    )
  }

  private func makeTemporaryDirectory(prefix: String) throws -> String {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(
      atPath: path,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return path
  }

  private func makeModuleResolutionDirectory(sourceRoot: String) throws {
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: sourceRoot)
        .appendingPathComponent("node_modules/.pnpm/node_modules"),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }
}

private struct ProfileFixture {
  let root: String
  let profile: String
  let executable: String
  let configuration: String

  func remove() {
    try? FileManager.default.removeItem(atPath: root)
    try? FileManager.default.removeItem(atPath: profile)
  }
}
