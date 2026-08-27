import BridgeAgentCore
import CryptoKit
import Darwin
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

  func testRegistrationAcceptsCatalogDeclaredByIndependentProfile() throws {
    let fixture = try makeProfileFixture(prefix: "deepseek-custom-catalog")
    addTeardownBlock { fixture.remove() }
    try profileConfiguration(
      modelIDs: ["private-backend/model-v1", "another-api/model-v2"],
      defaultModelID: "private-backend/model-v1",
      reasoningEffort: "high"
    ).write(to: URL(fileURLWithPath: fixture.configuration))

    let artifacts = try DeepSeekHarnessACPProfile.resolveArtifacts(
      executablePath: fixture.executable,
      configurationPath: fixture.configuration,
      sourceEnvironment: ["PATH": "/usr/bin:/bin"]
    )

    XCTAssertEqual(artifacts[.launchConfiguration], fixture.configuration)
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

  func testRuntimeProfileUsesWorkspaceWriteModeWithoutDangerFullAccess() throws {
    let fixture = try makeProfileFixture(prefix: "deepseek-runtime-write-mode")
    let runDirectory = try makeTemporaryDirectory(prefix: "deepseek-runtime-write-mode")
    addTeardownBlock {
      fixture.remove()
      try? FileManager.default.removeItem(atPath: runDirectory)
    }

    let stagedConfiguration = try DeepSeekHarnessACPLaunchBuilder().prepareRuntimeProfile(
      sourceRoot: fixture.root,
      runDirectory: runDirectory,
      mutationIntent: .workspaceWrite
    )
    let value = try String(contentsOfFile: stagedConfiguration, encoding: .utf8)

    XCTAssertTrue(value.contains("    mode: workspace-write"))
    XCTAssertFalse(value.contains("danger-full-access"))
  }

  func testLaunchEnvironmentMatchesWorkspaceWriteMode() throws {
    let fixture = try makeProfileFixture(prefix: "deepseek-launch-write-mode")
    let runDirectory = try makeTemporaryDirectory(prefix: "deepseek-launch-write-mode")
    addTeardownBlock {
      fixture.remove()
      try? FileManager.default.removeItem(atPath: runDirectory)
    }
    let installation = try AgentInstallation(
      id: .init(rawValue: "launch-write-installation"),
      providerID: .deepSeekHarness,
      executablePath: fixture.executable,
      artifacts: try [
        artifact(
          role: .launchConfiguration,
          path: fixture.configuration,
          data: try Data(contentsOf: URL(fileURLWithPath: fixture.configuration))
        ),
        artifact(
          role: .runtimeManifest,
          path: URL(fileURLWithPath: fixture.root).appendingPathComponent("package.json").path,
          data: Data(
            ("{\"version\":\"0.1.1-rc.2\",\"packageManager\":\"pnpm@11.7.0\","
              + "\"engines\":{\"node\":\"^22.19.0 || >=24.0.0\"}}").utf8
          )
        ),
        artifact(
          role: .dependencyLock,
          path: URL(fileURLWithPath: fixture.root).appendingPathComponent("pnpm-lock.yaml").path,
          data: Data(
            "packages:\n  /@agentclientprotocol/sdk@0.25.1:\n    resolution: {}\n".utf8
          )
        ),
        artifact(
          role: .nodeInterpreter,
          path: URL(fileURLWithPath: fixture.root).appendingPathComponent("node").path,
          data: Data("#!/bin/sh\necho v22.19.0\n".utf8)
        ),
      ]
    )
    let launch = try DeepSeekHarnessACPLaunchBuilder().make(
      installation: installation,
      projectRoot: fixture.root,
      runDirectory: runDirectory,
      mutationIntent: .workspaceWrite,
      networkAllowed: false,
      sourceEnvironment: ["PATH": "/usr/bin:/bin"]
    )

    XCTAssertEqual(launch.process.environment["DSH_PERMISSION_MODE"], "workspace-write")
    let value = try String(contentsOfFile: launch.process.argv[3], encoding: .utf8)
    XCTAssertTrue(value.contains("    mode: workspace-write"))
    XCTAssertFalse(value.contains("danger-full-access"))
  }

  func testRuntimeProfileAppliesDeclaredModelAndEffortOnlyToPrivateCopy() throws {
    let fixture = try makeProfileFixture(prefix: "deepseek-runtime-selection")
    let runDirectory = try makeTemporaryDirectory(prefix: "deepseek-runtime-selection")
    addTeardownBlock {
      fixture.remove()
      try? FileManager.default.removeItem(atPath: runDirectory)
    }
    let profile = try profileConfiguration(
      modelIDs: ["deepseek-v4-pro", "kimi-k2.6"],
      defaultModelID: "deepseek-v4-pro"
    )
    let bundled = try DeepSeekHarnessACPProfile.bundledConfigurationTemplate()
    let stagedConfiguration = try DeepSeekHarnessACPLaunchBuilder().prepareRuntimeProfile(
      sourceRoot: fixture.root,
      runDirectory: runDirectory,
      configurationData: profile,
      modelID: "kimi-k2.6",
      reasoningEffort: "high"
    )

    let staged = try String(contentsOfFile: stagedConfiguration, encoding: .utf8)
    XCTAssertTrue(staged.contains("reasoningEffort: high"))
    XCTAssertTrue(staged.contains("- id: deepseek-v4-pro"))
    XCTAssertTrue(staged.contains("- id: kimi-k2.6"))
    XCTAssertTrue(staged.contains("model: kimi-k2.6"))
    XCTAssertEqual(try DeepSeekHarnessACPProfile.bundledConfigurationTemplate(), bundled)
  }

  func testRuntimeProfileAcceptsBoundedEndpointDiscoveredModel() throws {
    let fixture = try makeProfileFixture(prefix: "deepseek-runtime-dynamic-selection")
    let runDirectory = try makeTemporaryDirectory(prefix: "deepseek-runtime-dynamic-selection")
    addTeardownBlock {
      fixture.remove()
      try? FileManager.default.removeItem(atPath: runDirectory)
    }

    let path = try DeepSeekHarnessACPLaunchBuilder().prepareRuntimeProfile(
      sourceRoot: fixture.root,
      runDirectory: runDirectory,
      modelID: "gateway/model-v2",
      reasoningEffort: "high"
    )
    let value = try String(contentsOfFile: path, encoding: .utf8)
    XCTAssertTrue(value.contains("model: gateway/model-v2"))
  }

  func testRuntimeProfileRejectsMalformedDynamicModelID() throws {
    let template = try DeepSeekHarnessACPProfile.bundledConfigurationTemplate()
    XCTAssertThrowsError(
      try DeepSeekHarnessACPModelCatalog.resolvedSelection(
        configuration: template,
        template: template,
        modelID: "gateway model",
        reasoningEffort: "high"
      )
    ) { error in
      XCTAssertEqual(error as? AgentRuntimeError, .modelUnavailable("gateway model"))
    }
  }

  func testProfileCatalogAllowsBoundedThirdPartyModelsWithoutChangingSecurityPolicy() throws {
    let configuration = try profileConfiguration(
      modelIDs: ["deepseek-v4-pro", "vendor/model-v1"],
      defaultModelID: "vendor/model-v1",
      reasoningEffort: "low"
    )
    let template = try DeepSeekHarnessACPProfile.bundledConfigurationTemplate()

    let models = try DeepSeekHarnessACPModelCatalog.descriptors(
      configuration: configuration,
      template: template,
      selectedModelID: "vendor/model-v1"
    )

    XCTAssertEqual(models.map(\.id), ["deepseek-v4-pro", "vendor/model-v1"])
    XCTAssertEqual(models[1].supportedReasoningEfforts, ["off", "low", "high", "max"])
    XCTAssertEqual(models[1].defaultReasoningEffort, "low")
  }

  func testDisabledThinkingProfileOnlyAdvertisesOff() throws {
    let configuration = try profileConfiguration(
      modelIDs: ["private-reasoner"],
      defaultModelID: "private-reasoner",
      reasoningEffort: "off",
      thinking: "disabled"
    )
    let models = try DeepSeekHarnessACPModelCatalog.descriptors(
      configuration: configuration,
      template: DeepSeekHarnessACPProfile.bundledConfigurationTemplate()
    )

    XCTAssertEqual(models[0].supportedReasoningEfforts, ["off"])
    XCTAssertEqual(models[0].defaultReasoningEffort, "off")
  }

  func testProfileCatalogRejectsChangesOutsideManagedModelFields() throws {
    let template = try DeepSeekHarnessACPProfile.bundledConfigurationTemplate()
    var value = try XCTUnwrap(String(data: template, encoding: .utf8))
    value = value.replacingOccurrences(of: "    mode: read-only", with: "    mode: full-access")

    XCTAssertThrowsError(
      try DeepSeekHarnessACPModelCatalog.descriptors(
        configuration: Data(value.utf8),
        template: template
      )
    ) { error in
      XCTAssertEqual(error as? DeepSeekHarnessACPError, .templateMismatch)
    }
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

  private func profileConfiguration(
    modelIDs: [String],
    defaultModelID: String,
    reasoningEffort: String = "max",
    thinking: String = "enabled"
  ) throws -> Data {
    var value = try XCTUnwrap(
      String(data: DeepSeekHarnessACPProfile.bundledConfigurationTemplate(), encoding: .utf8)
    )
    let models = modelIDs.map { "      - id: \($0)" }.joined(separator: "\n")
    value = value.replacingOccurrences(
      of: "      - id: deepseek-v4-pro",
      with: models
    )
    value = value.replacingOccurrences(
      of: "    model: deepseek-v4-pro",
      with: "    model: \(defaultModelID)"
    )
    value = value.replacingOccurrences(
      of: "    reasoningEffort: max",
      with: "    reasoningEffort: \(reasoningEffort)"
    )
    value = value.replacingOccurrences(
      of: "    thinking: enabled",
      with: "    thinking: \(thinking)"
    )
    return Data(value.utf8)
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

private func artifact(
  role: AgentInstallationArtifactRole,
  path: String,
  data: Data
) throws -> AgentInstallationArtifact {
  var metadata = stat()
  guard lstat(path, &metadata) == 0 else { throw POSIXError(.ENOENT) }
  let modificationTime =
    Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000
    + Int64(metadata.st_mtimespec.tv_nsec)
  let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  return AgentInstallationArtifact(
    role: role,
    canonicalPath: path,
    device: UInt64(metadata.st_dev),
    inode: UInt64(metadata.st_ino),
    fileSize: UInt64(metadata.st_size),
    modificationTimeNanoseconds: modificationTime,
    sha256: digest
  )
}
