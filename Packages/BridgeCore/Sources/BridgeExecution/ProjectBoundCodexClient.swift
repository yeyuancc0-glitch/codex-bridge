import BridgeCodexRPC
import BridgeDomain
import BridgeProjects
import Foundation

public actor ProjectBoundCodexClient {
  private let registry: ProjectRegistry
  private let client: any CodexTaskClient
  private let bindings: any ThreadBindingRepository

  package init(
    registry: ProjectRegistry,
    client: any CodexTaskClient,
    bindings: any ThreadBindingRepository
  ) {
    self.registry = registry
    self.client = client
    self.bindings = bindings
  }

  package init(
    registry: ProjectRegistry,
    client: CodexAppServerClient,
    bindings: any ThreadBindingRepository
  ) {
    self.registry = registry
    self.client = client
    self.bindings = bindings
  }

  public func startReadOnlyThread(
    projectID: ProjectID,
    workingDirectoryURL: URL,
    model: String? = nil,
    developerInstructions: String? = nil
  ) async throws -> ThreadStartResponse {
    let context = try await registry.executionContext(
      for: projectID,
      workingDirectoryURL: workingDirectoryURL
    )
    guard context.accessPolicy.read == .allowed else {
      throw ProjectExecutionError.projectReadDenied
    }

    let response = try await client.startThread(
      ThreadStartParams(
        cwd: context.root.canonicalPath,
        sandbox: .readOnly,
        approvalPolicy: .never,
        ephemeral: true,
        model: model,
        developerInstructions: developerInstructions
      )
    )
    try validate(response: response, context: context)
    try await bindings.insert(
      ProjectThreadBinding(
        threadID: response.thread.id,
        projectID: projectID,
        root: context.root
      )
    )
    return response
  }

  public func readBoundThread(
    threadID: String,
    projectID: ProjectID,
    includeTurns: Bool = false
  ) async throws -> ThreadReadResponse {
    guard let binding = try await bindings.binding(for: threadID) else {
      throw ProjectExecutionError.unboundThread
    }
    guard binding.projectID == projectID else {
      throw ProjectExecutionError.threadProjectMismatch
    }
    let context = try await registry.executionContext(
      for: projectID,
      workingDirectoryURL: URL(fileURLWithPath: binding.root.canonicalPath, isDirectory: true)
    )
    guard context.root == binding.root else {
      throw ProjectExecutionError.workingDirectoryMismatch
    }

    let response = try await client.readThread(
      ThreadReadParams(threadId: threadID, includeTurns: includeTurns)
    )
    guard response.thread.id == threadID,
      response.thread.cwd == binding.root.canonicalPath
    else {
      throw ProjectExecutionError.workingDirectoryMismatch
    }
    return response
  }

  private func validate(
    response: ThreadStartResponse,
    context: ProjectExecutionContext
  ) throws {
    guard response.cwd == context.root.canonicalPath,
      response.thread.cwd == context.root.canonicalPath
    else {
      throw ProjectExecutionError.workingDirectoryMismatch
    }
  }
}

public enum ProjectExecutionError: Error, Equatable, Sendable {
  case projectReadDenied
  case workingDirectoryMismatch
  case unboundThread
  case threadProjectMismatch
  case threadAlreadyBound
}
