import Foundation

public struct AntigravityCLIProcessConfiguration: Sendable {
  public let argv: [String]
  public let workingDirectory: String
  public let environment: [String: String]
  public let maximumFrameBytes: Int
  public let maximumStandardErrorBytes: Int
  public let maximumLifetime: Duration
  public let standardInputTimeout: Duration

  public init(
    argv: [String],
    workingDirectory: String,
    environment: [String: String],
    maximumFrameBytes: Int,
    maximumStandardErrorBytes: Int,
    maximumLifetime: Duration,
    standardInputTimeout: Duration = .seconds(2)
  ) {
    self.argv = argv
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.maximumFrameBytes = maximumFrameBytes
    self.maximumStandardErrorBytes = maximumStandardErrorBytes
    self.maximumLifetime = maximumLifetime
    self.standardInputTimeout = standardInputTimeout
  }
}

public struct AntigravityCLILaunchConfiguration: Sendable {
  public let process: AntigravityCLIProcessConfiguration
  public let runDirectory: String
  public let resolvedExecutablePath: String
  public let readOnlySandboxed: Bool

  public init(
    process: AntigravityCLIProcessConfiguration,
    runDirectory: String,
    resolvedExecutablePath: String,
    readOnlySandboxed: Bool
  ) {
    self.process = process
    self.runDirectory = runDirectory
    self.resolvedExecutablePath = resolvedExecutablePath
    self.readOnlySandboxed = readOnlySandboxed
  }
}
