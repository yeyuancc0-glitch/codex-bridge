import BridgeAgentCore
import BridgeDomain
import BridgeProcess
import Foundation
import XCTest

@testable import BridgeAntigravityCLI

final class AntigravityCLIProviderTests: XCTestCase {
  func testModelsParsesANSIOutputDeduplicatesAndRejectsUnsafeSlugs() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-model-project")
    let home = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-model-home")
    defer {
      try? FileManager.default.removeItem(atPath: projectRoot)
      try? FileManager.default.removeItem(atPath: home)
    }
    let output =
      "\u{001B}[32mgemini-pro Gemini Pro\u{001B}[0m\n"
      + "gemini-pro Duplicate\n"
      + "bad:model Bad Namespace\n"
      + "gemini-flash\n"
      + "\n"
    let commandRunner = RecordingAntigravityCommandRunner(
      result: AntigravityCLICommandResult(
        standardOutput: BoundedProcessOutput(
          head: output,
          tail: output,
          byteCount: output.utf8.count,
          truncated: false
        ),
        standardError: BoundedProcessOutput(
          head: "",
          tail: "",
          byteCount: 0,
          truncated: false
        ),
        termination: .exited(0),
        timedOut: false
      )
    )
    let provider = try AntigravityCLIProvider(
      configuration: AntigravityCLIProviderConfiguration(
        commandRunner: commandRunner,
        sourceEnvironment: ["HOME": home, "TMPDIR": projectRoot]
      )
    )
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "agy-models"),
      providerID: .antigravity,
      executablePath: "/bin/echo"
    )

    let models = try await provider.models(
      installation: installation,
      projectRoot: projectRoot
    )

    XCTAssertEqual(models.map(\.id), ["gemini-pro", "gemini-flash"])
    XCTAssertEqual(models.map(\.displayName), ["Gemini Pro", "gemini-flash"])
    XCTAssertEqual(models.first?.supportedReasoningEfforts, ["low", "medium", "high"])
    let calls = await commandRunner.calls()
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls[0].argv, ["/bin/echo", "models"])
    XCTAssertEqual(calls[0].workingDirectory, projectRoot)
    XCTAssertNil(calls[0].environment["UNRELATED_SETTING"])
  }

  func testProbeRunsVersionAndReturnsBoundInstallation() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-probe-project")
    let home = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-probe-home")
    defer {
      try? FileManager.default.removeItem(atPath: projectRoot)
      try? FileManager.default.removeItem(atPath: home)
    }
    let version = "agy version 1.1.21\n"
    let commandRunner = RecordingAntigravityCommandRunner(
      result: AntigravityCLICommandResult(
        standardOutput: BoundedProcessOutput(
          head: version,
          tail: version,
          byteCount: version.utf8.count,
          truncated: false
        ),
        standardError: BoundedProcessOutput(head: "", tail: "", byteCount: 0, truncated: false),
        termination: .exited(0),
        timedOut: false
      )
    )
    let provider = try AntigravityCLIProvider(
      configuration: AntigravityCLIProviderConfiguration(
        launchBuilder: AntigravityCLILaunchBuilder(sandboxExecutablePath: "/bin/echo"),
        commandRunner: commandRunner,
        sourceEnvironment: ["HOME": home, "TMPDIR": projectRoot]
      )
    )
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "agy-probe"),
      providerID: .antigravity,
      executablePath: "/bin/echo"
    )

    let result = await provider.probe(
      try AgentProbeRequest(installation: installation, projectRoot: projectRoot)
    )

    XCTAssertTrue(result.available)
    XCTAssertFalse(result.reviewRequired)
    XCTAssertEqual(result.installation.version, "1.1.21")
    XCTAssertEqual(result.installation.protocolRevision, "stream-json-v1")
    XCTAssertEqual(result.installation.executablePath, "/bin/echo")
    XCTAssertTrue(result.capabilities.advertised.contains(.sessionContinue))
    XCTAssertFalse(result.capabilities.observed.contains(.sessionContinue))
    XCTAssertEqual(result.capabilities.effective, [.workspaceRead])
    XCTAssertFalse(result.capabilities.effective.contains(.textDelta))
    let calls = await commandRunner.calls()
    XCTAssertEqual(calls.map(\.argv), [["/bin/echo", "--version"]])
  }

  func testProbeMarksUnsupportedVersionForReview() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(
      prefix: "agy-version-project")
    let home = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-version-home")
    defer {
      try? FileManager.default.removeItem(atPath: projectRoot)
      try? FileManager.default.removeItem(atPath: home)
    }
    let version = "agy version 1.2.0\n"
    let commandRunner = RecordingAntigravityCommandRunner(
      result: AntigravityCLICommandResult(
        standardOutput: BoundedProcessOutput(
          head: version,
          tail: version,
          byteCount: version.utf8.count,
          truncated: false
        ),
        standardError: BoundedProcessOutput(head: "", tail: "", byteCount: 0, truncated: false),
        termination: .exited(0),
        timedOut: false
      )
    )
    let provider = try AntigravityCLIProvider(
      configuration: AntigravityCLIProviderConfiguration(
        launchBuilder: AntigravityCLILaunchBuilder(sandboxExecutablePath: "/bin/echo"),
        commandRunner: commandRunner,
        sourceEnvironment: ["HOME": home, "TMPDIR": projectRoot]
      )
    )
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "agy-version"),
      providerID: .antigravity,
      executablePath: "/bin/echo"
    )

    let result = await provider.probe(
      try AgentProbeRequest(installation: installation, projectRoot: projectRoot)
    )

    XCTAssertFalse(result.available)
    XCTAssertTrue(result.reviewRequired)
    XCTAssertTrue(result.unavailableReason?.contains("incompatible") == true)
  }

  func testStartRejectsWriteAndNetworkRequestsBeforeLaunching() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(
      prefix: "agy-admission-project")
    let home = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-admission-home")
    let runtime = FileManager.default.temporaryDirectory
      .appendingPathComponent("agy-admission-runtime-\(UUID().uuidString)", isDirectory: true).path
    defer {
      try? FileManager.default.removeItem(atPath: projectRoot)
      try? FileManager.default.removeItem(atPath: home)
      try? FileManager.default.removeItem(atPath: runtime)
    }
    let provider = try AntigravityCLIProvider(
      configuration: AntigravityCLIProviderConfiguration(
        launchBuilder: AntigravityCLILaunchBuilder(sandboxExecutablePath: "/bin/echo"),
        runtimeBaseDirectory: runtime,
        sourceEnvironment: ["HOME": home, "TMPDIR": projectRoot]
      )
    )
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "agy-admission"),
      providerID: .antigravity,
      executablePath: "/bin/echo"
    )
    let writeRequest = try AgentExecutionRequest(
      taskID: TaskID(rawValue: "task-agy-write"),
      projectID: ProjectID(rawValue: "project-agy-write"),
      projectRoot: projectRoot,
      prompt: "Write a file",
      mutationIntent: .workspaceWrite,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false
    )
    let networkRequest = try AgentExecutionRequest(
      taskID: TaskID(rawValue: "task-agy-network"),
      projectID: ProjectID(rawValue: "project-agy-network"),
      projectRoot: projectRoot,
      prompt: "Use the network",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: true
    )

    do {
      _ = try await provider.start(writeRequest, installation: installation)
      XCTFail("Expected workspace-write to be rejected")
    } catch {
      XCTAssertEqual(error as? AgentRuntimeError, .capabilityUnavailable(.workspaceWriteInPlace))
    }
    do {
      _ = try await provider.start(networkRequest, installation: installation)
      XCTFail("Expected network access to be rejected")
    } catch {
      XCTAssertEqual(error as? AgentRuntimeError, .invalidRequest("request.networkAccessRequested"))
    }
  }

  func testStartRejectsCapabilitiesNotObservedByVersionProbe() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(
      prefix: "agy-capability-project")
    let home = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-capability-home")
    let runtime = FileManager.default.temporaryDirectory
      .appendingPathComponent("agy-capability-runtime-\(UUID().uuidString)", isDirectory: true).path
    defer {
      try? FileManager.default.removeItem(atPath: projectRoot)
      try? FileManager.default.removeItem(atPath: home)
      try? FileManager.default.removeItem(atPath: runtime)
    }
    let provider = try AntigravityCLIProvider(
      configuration: AntigravityCLIProviderConfiguration(
        launchBuilder: AntigravityCLILaunchBuilder(sandboxExecutablePath: "/bin/echo"),
        runtimeBaseDirectory: runtime,
        sourceEnvironment: ["HOME": home, "TMPDIR": projectRoot]
      )
    )
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "agy-capability"),
      providerID: .antigravity,
      executablePath: "/bin/echo"
    )

    for (taskSuffix, sessionID, model, effort, expected) in [
      ("continue", "conversation-1", nil, nil, AgentCapability.sessionContinue),
      ("model", nil, "gemini-pro", nil, AgentCapability.modelSelection),
      ("effort", nil, nil, "high", AgentCapability.effortSelection),
    ] {
      let request = try AgentExecutionRequest(
        taskID: TaskID(rawValue: "task-agy-\(taskSuffix)"),
        projectID: ProjectID(rawValue: "project-agy-capability"),
        projectRoot: projectRoot,
        prompt: "Inspect",
        requestedSessionID: sessionID,
        model: model,
        effort: effort,
        mutationIntent: .readOnly,
        workspaceStrategy: .sharedProject,
        networkAccessRequested: false
      )
      do {
        _ = try await provider.start(request, installation: installation)
        XCTFail("Expected unobserved capability to be rejected")
      } catch {
        XCTAssertEqual(error as? AgentRuntimeError, .capabilityUnavailable(expected))
      }
    }
  }
}
