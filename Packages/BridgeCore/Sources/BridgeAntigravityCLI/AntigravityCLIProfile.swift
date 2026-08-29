import BridgeAgentCore
import BridgeProcess
import Foundation

public enum AntigravityCLIProfiles {
  /// Uses the user's Antigravity CLI home, settings, and cached credentials.
  /// Desktop and CLI authentication are not assumed to be interchangeable.
  public static let desktopShared = AgentProfileID(rawValue: "desktop-shared")
}

public struct AntigravityCLISemanticVersion: Comparable, Equatable, Sendable {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(major: Int, minor: Int, patch: Int) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public init?(_ output: String) {
    let candidates = output.split { !$0.isNumber && $0 != "." }
    guard
      let candidate = candidates.first(where: {
        $0.split(separator: ".", omittingEmptySubsequences: false).count == 3
      })
    else { return nil }
    let components = candidate.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
      let major = Int(components[0]),
      let minor = Int(components[1]),
      let patch = Int(components[2]),
      major >= 0,
      minor >= 0,
      patch >= 0
    else { return nil }
    self.init(major: major, minor: minor, patch: patch)
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.major != rhs.major { return lhs.major < rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
    return lhs.patch < rhs.patch
  }

  public var stringValue: String { "\(major).\(minor).\(patch)" }
}

public struct AntigravityCLICompatibility: Equatable, Sendable {
  public let minimumVersion: AntigravityCLISemanticVersion
  public let maximumExclusiveVersion: AntigravityCLISemanticVersion

  public init(
    minimumVersion: AntigravityCLISemanticVersion = .init(major: 1, minor: 1, patch: 21),
    maximumExclusiveVersion: AntigravityCLISemanticVersion = .init(major: 1, minor: 2, patch: 0)
  ) {
    self.minimumVersion = minimumVersion
    self.maximumExclusiveVersion = maximumExclusiveVersion
  }

  public func accepts(_ version: AntigravityCLISemanticVersion) -> Bool {
    version >= minimumVersion && version < maximumExclusiveVersion
  }
}

struct AntigravityCLIHelpFacts: Equatable, Sendable {
  let supportsStreamJSON: Bool
  let supportsPlanMode: Bool
  let supportsAcceptEditsMode: Bool
  let supportsConversation: Bool
  let supportsModel: Bool
  let supportsEffort: Bool
  let supportsQueuedTurns: Bool
  let supportsSandbox: Bool

  var observedCapabilities: Set<AgentCapability> {
    var result: Set<AgentCapability> = []
    if supportsStreamJSON {
      result.insert(.sessionCreate)
      result.insert(.toolLifecycle)
      result.insert(.usage)
    }
    if supportsPlanMode && supportsStreamJSON {
      result.insert(.workspaceRead)
    }
    if supportsAcceptEditsMode && supportsStreamJSON {
      result.insert(.workspaceWriteInPlace)
    }
    if supportsConversation {
      result.insert(.sessionContinue)
    }
    if supportsModel {
      result.insert(.modelSelection)
    }
    if supportsEffort {
      result.insert(.effortSelection)
    }
    if supportsQueuedTurns {
      result.insert(.steer)
    }
    return result
  }

  static func parse(_ output: String) -> Self {
    let plain = output.replacingOccurrences(
      of: "\u{001B}\\[[0-9;]*m",
      with: "",
      options: .regularExpression
    )
    let lines = plain.split(separator: "\n", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    let inputLine = lines.first(where: { $0.contains("--input-format") }) ?? ""
    let outputLine = lines.first(where: { $0.contains("--output-format") }) ?? ""
    let modeLine = lines.first(where: { $0.contains("--mode") }) ?? ""
    let effortLine = lines.first(where: { $0.contains("--effort") }) ?? ""
    let streamJSON = inputLine.contains("stream-json") && outputLine.contains("stream-json")
    let queuedTurns = inputLine.contains("runs a turn for each")
    return Self(
      supportsStreamJSON: streamJSON,
      supportsPlanMode: modeLine.contains("plan"),
      supportsAcceptEditsMode: modeLine.contains("accept-edits"),
      supportsConversation: lines.contains(where: { $0.contains("--conversation") }),
      supportsModel: lines.contains(where: { $0.contains("--model") }),
      supportsEffort: effortLine.contains("--effort")
        && ["low", "medium", "high"].allSatisfy(effortLine.contains),
      supportsQueuedTurns: streamJSON && queuedTurns,
      supportsSandbox: lines.contains(where: { $0.contains("--sandbox") })
    )
  }
}

public struct AntigravityCLICommandResult: Equatable, Sendable {
  public let standardOutput: BoundedProcessOutput
  public let standardError: BoundedProcessOutput
  public let termination: ManagedProcessTermination
  public let timedOut: Bool

  public init(
    standardOutput: BoundedProcessOutput,
    standardError: BoundedProcessOutput,
    termination: ManagedProcessTermination,
    timedOut: Bool
  ) {
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.termination = termination
    self.timedOut = timedOut
  }
}

public protocol AntigravityCLICommandRunning: Sendable {
  func run(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String],
    timeout: Duration
  ) async throws -> AntigravityCLICommandResult
}

public struct AntigravityCLICommandRunner: AntigravityCLICommandRunning, Sendable {
  public let maximumOutputBytes: Int

  public init(maximumOutputBytes: Int = 1_048_576) {
    self.maximumOutputBytes = max(1, maximumOutputBytes)
  }

  public func run(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String],
    timeout: Duration
  ) async throws -> AntigravityCLICommandResult {
    let output = BoundedProcessOutputCollector(maximumBytes: maximumOutputBytes)
    let error = BoundedProcessOutputCollector(maximumBytes: maximumOutputBytes)
    let process: ManagedStdioProcess
    do {
      process = try ManagedStdioProcess(
        argv: argv,
        workingDirectory: workingDirectory,
        environment: environment,
        mergeStandardError: false,
        onStandardOutput: { output.append($0) },
        onStandardError: { error.append($0) }
      )
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
    process.closeStdin()
    let result = await ManagedProcessRunner(defaultTimeout: timeout).monitor(process: process)
    return AntigravityCLICommandResult(
      standardOutput: output.snapshot(),
      standardError: error.snapshot(),
      termination: result.termination,
      timedOut: result.timedOut
    )
  }
}
