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
  public static let gitPath = "/usr/bin/git"

  public let defaultTimeout: Duration

  public init(defaultTimeout: Duration = .seconds(60)) {
    self.defaultTimeout = defaultTimeout
  }

  public func run(
    argv: [String],
    workingDirectory: String,
    timeout: Duration = .seconds(60)
  ) async throws -> DirectGitResult {
    guard let executable = argv.first, !executable.isEmpty, argv.count <= 128 else {
      throw DirectGitError.invalidArgument
    }
    return try await Task.detached(priority: .userInitiated) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = Array(argv.dropFirst())
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
      var environment = ProcessInfo.processInfo.environment
      environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
      process.environment = environment

      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      let collector = DirectCommandOutputCollector(maximumBytes: 256 * 1_024)
      pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty {
          collector.append(data)
        }
      }

      do {
        try process.run()
      } catch {
        throw DirectGitError.launchFailed
      }

      let deadline = ContinuousClock.now.advanced(by: timeout)
      while process.isRunning && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
      }
      if process.isRunning {
        _ = Darwin.kill(-process.processIdentifier, SIGKILL)
        pipe.fileHandleForReading.readabilityHandler = nil
        throw DirectGitError.timedOut
      }
      pipe.fileHandleForReading.readabilityHandler = nil
      var remaining = Data()
      while true {
        let chunk = pipe.fileHandleForReading.readData(ofLength: 16 * 1_024)
        if chunk.isEmpty { break }
        remaining.append(chunk)
      }
      if !remaining.isEmpty {
        collector.append(remaining)
      }
      return DirectGitResult(exitCode: process.terminationStatus, output: collector.snapshot())
    }.value
  }
}
