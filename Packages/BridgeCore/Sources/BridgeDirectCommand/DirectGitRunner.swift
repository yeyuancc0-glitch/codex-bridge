import BridgeProcessRuntime
import Foundation

public enum DirectGitError: Error, Equatable, Sendable {
  case invalidArgument
  case notGitRepository
  case launchFailed
  case timedOut
}

public enum DirectGitCommitError: Error, Equatable, Sendable {
  case gitFailed(String)
}

public struct DirectGitResult: Equatable, Sendable {
  public let exitCode: Int32
  public let output: DirectCommandOutputBuffer

  public init(exitCode: Int32, output: DirectCommandOutputBuffer) {
    self.exitCode = exitCode
    self.output = output
  }
}

/// Runs one bounded, non-interactive git command inside the project root and
/// captures bounded head/tail output. Used by the controlled Direct Git
/// commit path so that no shell is involved and no history rewrite is possible.
public struct DirectGitRunner: Sendable {
  public static var gitPath: String {
    (try? resolveGitPath()) ?? missingGitPath
  }

  public static func resolveGitPath() throws -> String {
    guard let resolved = GitExecutableResolver().resolve() else {
      throw DirectGitError.launchFailed
    }
    return resolved.path
  }

  public let defaultTimeout: Duration

  public init(defaultTimeout: Duration = .seconds(60)) {
    self.defaultTimeout = defaultTimeout
  }

  public func run(
    argv: [String],
    workingDirectory: String,
    timeout: Duration? = nil,
    environment overrides: [String: String]? = nil
  ) async throws -> DirectGitResult {
    guard let executable = argv.first, !executable.isEmpty, argv.count <= 128 else {
      throw DirectGitError.invalidArgument
    }
    return try await Task.detached(priority: .userInitiated) {
      var environment = Self.gitEnvironment()
      if let overrides {
        environment.merge(overrides) { _, replacement in replacement }
      }
      environment["GIT_TERMINAL_PROMPT"] = "0"
      environment["GCM_INTERACTIVE"] = "Never"
      let collector = DirectCommandOutputCollector(maximumBytes: 256 * 1_024)
      let process: DirectProcessLifetime
      do {
        process = try DirectProcessLifetime(
          argv: argv,
          workingDirectory: workingDirectory,
          environment: environment,
          usePTY: false,
          output: collector
        )
      } catch {
        throw DirectGitError.launchFailed
      }

      let deadline = ContinuousClock.now.advanced(by: timeout ?? defaultTimeout)
      while process.isRunning && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
      }
      if process.isRunning {
        _ = process.terminateAndWait(gracePeriod: .seconds(1))
        process.drainRemainingOutput()
        process.close()
        throw DirectGitError.timedOut
      }
      guard let termination = process.waitForExit(timeout: .seconds(1)) else {
        _ = process.terminateAndWait(gracePeriod: .milliseconds(0))
        process.drainRemainingOutput()
        process.close()
        throw DirectGitError.timedOut
      }
      process.drainRemainingOutput()
      process.close()
      guard case .exited(let exitCode) = termination else {
        return DirectGitResult(exitCode: -1, output: collector.snapshot())
      }
      return DirectGitResult(exitCode: exitCode, output: collector.snapshot())
    }.value
  }

  private static var missingGitPath: String {
    #if canImport(WinSDK)
      return "C:\\CodexBridge\\Missing\\git.exe"
    #else
      return "/usr/bin/git"
    #endif
  }

  private static func gitEnvironment() -> [String: String] {
    let current = ProcessInfo.processInfo.environment
    #if canImport(WinSDK)
      let allowed = [
        "SystemRoot", "WINDIR", "TEMP", "TMP", "USERPROFILE", "HOMEDRIVE", "HOMEPATH",
        "HOME", "LOCALAPPDATA", "APPDATA", "ProgramFiles", "ProgramFiles(x86)",
        "ProgramW6432", "PATH", "PATHEXT", "LANG", "LC_ALL",
      ]
      var result: [String: String] = [:]
      for key in allowed {
        if let value = WindowsPath.environmentValue(key, in: current) {
          result[key] = value
        }
      }
      return result
    #else
      var result = current
      result["PATH"] = result["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
      return result
    #endif
  }
}
