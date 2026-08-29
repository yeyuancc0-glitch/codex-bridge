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
    let versionAndHelp =
      """
      agy version 1.1.21
      --mode Set the agent execution mode (accept-edits, plan)
      --conversation Resume a previous conversation by ID
      --model Model for the current CLI session
      --effort Reasoning effort for the current CLI session (low|medium|high)
      --sandbox Run in a sandbox with terminal restrictions enabled
      --input-format stream-json reads one NDJSON message per line and runs a turn for each
      --output-format stream-json
      """
    let commandRunner = RecordingAntigravityCommandRunner(
      result: AntigravityCLICommandResult(
        standardOutput: BoundedProcessOutput(
          head: versionAndHelp,
          tail: versionAndHelp,
          byteCount: versionAndHelp.utf8.count,
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
    XCTAssertTrue(result.capabilities.observed.contains(.sessionContinue))
    XCTAssertTrue(result.capabilities.effective.contains(.workspaceRead))
    XCTAssertTrue(result.capabilities.effective.contains(.sessionContinue))
    XCTAssertTrue(result.capabilities.effective.contains(.modelSelection))
    XCTAssertTrue(result.capabilities.effective.contains(.effortSelection))
    XCTAssertTrue(result.capabilities.effective.contains(.steer))
    XCTAssertTrue(result.capabilities.effective.contains(.workspaceWriteInPlace))
    XCTAssertFalse(result.capabilities.effective.contains(.textDelta))
    let calls = await commandRunner.calls()
    XCTAssertEqual(calls.map(\.argv), [["/bin/echo", "--version"], ["/bin/echo", "--help"]])
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

  func testStartBuildsWorkspaceWriteWithProviderNativeNetworkAccess() async throws {
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
    let transport = ScriptedAntigravityTransport()
    let provider = try AntigravityCLIProvider(
      configuration: AntigravityCLIProviderConfiguration(
        launchBuilder: AntigravityCLILaunchBuilder(sandboxExecutablePath: "/bin/echo"),
        runtimeBaseDirectory: runtime,
        sourceEnvironment: ["HOME": home, "TMPDIR": projectRoot],
        transportFactory: { _ in
          Task {
            try? await transport.emit(
              AntigravityCLITestSupport.initializationFrame(
                cwd: projectRoot,
                model: "gemini-test"
              )
            )
          }
          return transport
        }
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
      workspaceStrategy: .exclusiveProject,
      networkAccessRequested: true
    )

    let writeHandle = try await provider.start(writeRequest, installation: installation)
    XCTAssertTrue(writeHandle.capabilities.effective.contains(.workspaceWriteInPlace))
    for _ in 0..<100 {
      let frames = await transport.sentFramesValue()
      if !frames.isEmpty { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let sentFrames = await transport.sentFramesValue()
    let firstFrame = try XCTUnwrap(sentFrames.first)
    let firstPrompt = try JSONDecoder().decode(AntigravityUserMessage.self, from: firstFrame)
      .message.content
    XCTAssertEqual(firstPrompt, "Write a file")
    if let shutdown = writeHandle.control.shutdown {
      await shutdown()
    }
  }

  func testStartUsesSelectionAndContinuationCapabilitiesAfterAdmission() async throws {
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
    let transport = ScriptedAntigravityTransport()
    let provider = try AntigravityCLIProvider(
      configuration: AntigravityCLIProviderConfiguration(
        launchBuilder: AntigravityCLILaunchBuilder(sandboxExecutablePath: "/bin/echo"),
        runtimeBaseDirectory: runtime,
        sourceEnvironment: ["HOME": home, "TMPDIR": projectRoot],
        transportFactory: { _ in
          Task {
            try? await transport.emit(
              AntigravityCLITestSupport.initializationFrame(
                conversationID: "conversation-1",
                cwd: projectRoot,
                permissionMode: "always-proceed",
                model: "gemini-test",
                tools: [
                  "read_file", "run_command", "search_web", "read_url_content",
                  "mcp__server__tool", "delegate_subagent",
                ]
              )
            )
          }
          return transport
        }
      )
    )
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "agy-capability"),
      providerID: .antigravity,
      executablePath: "/bin/echo"
    )
    let request = try AgentExecutionRequest(
      taskID: TaskID(rawValue: "task-agy-capability"),
      projectID: ProjectID(rawValue: "project-agy-capability"),
      projectRoot: projectRoot,
      prompt: "Inspect",
      requestedSessionID: "conversation-1",
      model: "gemini-test",
      effort: "high",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false
    )

    let handle = try await provider.start(request, installation: installation)
    XCTAssertTrue(handle.capabilities.effective.contains(.sessionContinue))
    XCTAssertTrue(handle.capabilities.effective.contains(.modelSelection))
    XCTAssertTrue(handle.capabilities.effective.contains(.effortSelection))
    XCTAssertTrue(handle.capabilities.effective.contains(.shell))
    XCTAssertTrue(handle.capabilities.effective.contains(.webSearch))
    XCTAssertTrue(handle.capabilities.effective.contains(.webFetch))
    XCTAssertTrue(handle.capabilities.effective.contains(.mcpClient))
    XCTAssertTrue(handle.capabilities.effective.contains(.subagents))
    XCTAssertTrue(handle.capabilities.effective.contains(.childRuns))
    if let shutdown = handle.control.shutdown {
      await shutdown()
    }
  }
}
