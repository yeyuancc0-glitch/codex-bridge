import BridgeAgentCore
import Foundation

public struct AntigravityCLILaunchBuilder: Sendable {
  public let maximumFrameBytes: Int
  public let maximumStandardErrorBytes: Int
  public let maximumLifetime: Duration
  public let sandboxExecutablePath: String

  public init(
    maximumFrameBytes: Int = 1_048_576,
    maximumStandardErrorBytes: Int = 256 * 1_024,
    maximumLifetime: Duration = .seconds(24 * 60 * 60),
    sandboxExecutablePath: String = "/usr/bin/sandbox-exec"
  ) {
    self.maximumFrameBytes = max(1, maximumFrameBytes)
    self.maximumStandardErrorBytes = max(1, maximumStandardErrorBytes)
    self.maximumLifetime = maximumLifetime
    self.sandboxExecutablePath = sandboxExecutablePath
  }

  public func make(
    installation: AgentInstallation,
    request: AgentExecutionRequest,
    runDirectory: String,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> AntigravityCLILaunchConfiguration {
    guard installation.providerID == .antigravity else {
      throw AgentRuntimeError.invalidRequest("installation.providerID")
    }
    let expectedStrategy: AgentWorkspaceStrategy =
      request.mutationIntent == .readOnly ? .sharedProject : .exclusiveProject
    guard request.workspaceStrategy == expectedStrategy else {
      throw AgentRuntimeError.invalidRequest("request.workspaceStrategy")
    }
    let executable = try AntigravityCLILaunchRuntime.resolveExecutable(installation.executablePath)
    let projectRoot = try AntigravityCLILaunchRuntime.canonicalExistingDirectory(
      request.projectRoot,
      field: "request.projectRoot"
    )
    let runtime = try AntigravityCLILaunchRuntime.preparePrivateDirectory(runDirectory)
    let environment = try AntigravityCLILaunchRuntime.environment(
      executable: executable,
      runDirectory: runtime,
      source: sourceEnvironment
    )
    var providerArgv = [
      executable,
      "--sandbox",
    ]
    if request.toolApprovalPolicy == .autoApprove {
      providerArgv.append("--dangerously-skip-permissions")
    }
    providerArgv.append(
      contentsOf: [
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
      ])
    let readOnly = request.mutationIntent == .readOnly
    providerArgv.append(contentsOf: ["--mode", readOnly ? "plan" : "accept-edits"])
    if let sessionID = request.requestedSessionID {
      providerArgv.append(contentsOf: ["--conversation", sessionID])
    }
    if let model = request.model {
      providerArgv.append(contentsOf: ["--model", model])
    }
    if let effort = request.effort {
      guard ["low", "medium", "high"].contains(effort) else {
        throw AgentRuntimeError.invalidRequest("request.effort")
      }
      providerArgv.append(contentsOf: ["--effort", effort])
    }

    guard FileManager.default.isExecutableFile(atPath: sandboxExecutablePath) else {
      throw AgentRuntimeError.processUnavailable
    }
    providerArgv.append(contentsOf: ["--add-dir", projectRoot])
    let profile = try AntigravityCLILaunchRuntime.sandboxProfile(
      projectRoot: projectRoot,
      runDirectory: runtime,
      allowsWorkspaceWrites: !readOnly
    )
    let argv = [sandboxExecutablePath, "-p", profile, "--"] + providerArgv
    return AntigravityCLILaunchConfiguration(
      process: AntigravityCLIProcessConfiguration(
        argv: argv,
        workingDirectory: projectRoot,
        environment: environment,
        maximumFrameBytes: maximumFrameBytes,
        maximumStandardErrorBytes: maximumStandardErrorBytes,
        maximumLifetime: maximumLifetime,
        standardInputTimeout: .seconds(2)
      ),
      runDirectory: runtime,
      resolvedExecutablePath: executable,
      readOnlySandboxed: readOnly
    )
  }

  public func commandEnvironment(
    executablePath: String,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> [String: String] {
    let executable = try AntigravityCLILaunchRuntime.resolveExecutable(executablePath)
    return try AntigravityCLILaunchRuntime.environment(
      executable: executable,
      runDirectory: sourceEnvironment["TMPDIR"] ?? NSTemporaryDirectory(),
      source: sourceEnvironment,
      prepareTemporaryDirectory: false
    )
  }

  public static func removeRunDirectory(_ path: String) {
    guard !path.isEmpty else { return }
    try? FileManager.default.removeItem(atPath: path)
  }
}
