import BridgeDomain
import Foundation

public struct ServiceTaskCreationResult: Equatable, Sendable {
  public let task: ServiceTaskRecord
  public let reusedExistingTask: Bool

  public init(task: ServiceTaskRecord, reusedExistingTask: Bool) {
    self.task = task
    self.reusedExistingTask = reusedExistingTask
  }
}

public struct ServiceTaskRequest: Equatable, Sendable {
  public let projectID: ProjectID
  public let source: ServiceTaskSource
  public let sourceClientID: String
  public let clientRequestID: String?
  public let prompt: String
  public let requestedThreadID: String?
  public let executionModel: String
  public let executionEffort: String
  public let supervisorModel: String?
  public let supervisorEffort: String?
  public let permissionMode: ServicePermissionMode
  public let networkAllowed: Bool
  public let accessMode: ServiceAccessMode
  public let fastMode: Bool

  public init(
    projectID: ProjectID,
    source: ServiceTaskSource,
    sourceClientID: String = "",
    clientRequestID: String? = nil,
    prompt: String,
    requestedThreadID: String? = nil,
    executionModel: String,
    executionEffort: String,
    supervisorModel: String? = nil,
    supervisorEffort: String? = nil,
    permissionMode: ServicePermissionMode,
    networkAllowed: Bool = false,
    accessMode: ServiceAccessMode = .requestApproval,
    fastMode: Bool = false
  ) {
    self.projectID = projectID
    self.source = source
    self.sourceClientID = sourceClientID
    self.clientRequestID = clientRequestID
    self.prompt = prompt
    self.requestedThreadID = requestedThreadID
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.supervisorModel = supervisorModel
    self.supervisorEffort = supervisorEffort
    self.permissionMode = permissionMode
    self.networkAllowed = networkAllowed
    self.accessMode = accessMode
    self.fastMode = fastMode
  }
}
