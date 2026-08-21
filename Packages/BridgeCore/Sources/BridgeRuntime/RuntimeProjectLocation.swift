import BridgeDomain
import Foundation

public struct RuntimeProjectLocation: Sendable {
  public let workingDirectoryURL: URL
  public let repositoryRootURL: URL

  public init(workingDirectoryURL: URL, repositoryRootURL: URL) {
    self.workingDirectoryURL = workingDirectoryURL
    self.repositoryRootURL = repositoryRootURL
  }
}

public protocol RuntimeProjectLocationResolving: Sendable {
  func location(for submission: TaskSubmission) async throws -> RuntimeProjectLocation
}

public struct ClosureRuntimeProjectLocationResolver: RuntimeProjectLocationResolving {
  private let resolve: @Sendable (TaskSubmission) async throws -> RuntimeProjectLocation

  public init(
    resolve: @escaping @Sendable (TaskSubmission) async throws -> RuntimeProjectLocation
  ) {
    self.resolve = resolve
  }

  public func location(for submission: TaskSubmission) async throws -> RuntimeProjectLocation {
    try await resolve(submission)
  }
}
