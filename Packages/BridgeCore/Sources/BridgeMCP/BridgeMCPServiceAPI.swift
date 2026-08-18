import Foundation

public enum MCPServiceExposureMode: String, Codable, Equatable, Sendable {
  case readOnly = "read-only"
  case full
}

public protocol BridgeMCPServiceAPI: Sendable {
  func serviceStatus(deadline: ContinuousClock.Instant) async throws -> BridgeStatusSnapshot

  func serviceProjects(
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage

  func serviceProject(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail

  func serviceProjectCommands(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectCommands

  func serviceSearchProjectFiles(
    projectID: String,
    query: String,
    relativeDirectory: String?,
    caseSensitive: Bool,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileSearchPage

  func serviceReadProjectFile(
    projectID: String,
    relativePath: String,
    startLine: Int,
    lineCount: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileReadPage

  func serviceThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage

  func serviceReadThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage

  func serviceModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList

  func serviceTask(
    taskID: String,
    recentEventLimit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSnapshot

  func serviceSubmitTask(
    _ submission: MCPServiceTaskSubmission,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt

  func serviceSteerTask(
    taskID: String,
    expectedTurnID: String,
    input: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskMutationReceipt

  func serviceInterruptTask(
    taskID: String,
    expectedTurnID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskMutationReceipt

  func serviceProjectChanges(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectChanges

  func serviceDirectWriteFile(
    _ request: MCPDirectWriteRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectWriteReceipt

  func serviceDirectEditFile(
    _ request: MCPDirectEditRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectEditReceipt

  func serviceDirectApplyPatch(
    _ request: MCPDirectPatchRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectPatchReceipt

  func serviceDirectManagePath(
    _ request: MCPDirectManagePathRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectManagePathReceipt
}

public struct MCPServiceTaskEvent: Codable, Equatable, Sendable {
  public let sequence: Int64
  public let kind: String
  public let summary: String
  public let occurredAt: String

  public init(sequence: Int64, kind: String, summary: String, occurredAt: String) {
    self.sequence = sequence
    self.kind = kind
    self.summary = summary
    self.occurredAt = occurredAt
  }

  private enum CodingKeys: String, CodingKey {
    case sequence = "seq"
    case kind
    case summary
    case occurredAt = "occurred_at"
  }
}

public struct MCPServiceTaskSnapshot: Codable, Equatable, Sendable {
  public let taskID: String
  public let projectID: String
  public let status: String
  public let threadID: String?
  public let turnID: String?
  public let currentStep: String?
  public let changedFiles: [String]
  public let recentEvents: [MCPServiceTaskEvent]
  public let supervisorStatus: String
  public let supervisorSummary: String?
  public let localApprovalRequired: Bool
  public let resultSummary: String?
  public let failureCode: String?
  public let updatedAt: String

  public init(
    taskID: String,
    projectID: String,
    status: String,
    threadID: String? = nil,
    turnID: String? = nil,
    currentStep: String? = nil,
    changedFiles: [String] = [],
    recentEvents: [MCPServiceTaskEvent] = [],
    supervisorStatus: String,
    supervisorSummary: String? = nil,
    localApprovalRequired: Bool,
    resultSummary: String? = nil,
    failureCode: String? = nil,
    updatedAt: String
  ) {
    self.taskID = taskID
    self.projectID = projectID
    self.status = status
    self.threadID = threadID
    self.turnID = turnID
    self.currentStep = currentStep
    self.changedFiles = changedFiles
    self.recentEvents = recentEvents
    self.supervisorStatus = supervisorStatus
    self.supervisorSummary = supervisorSummary
    self.localApprovalRequired = localApprovalRequired
    self.resultSummary = resultSummary
    self.failureCode = failureCode
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case projectID = "project_id"
    case status
    case threadID = "thread_id"
    case turnID = "turn_id"
    case currentStep = "current_step"
    case changedFiles = "changed_files"
    case recentEvents = "recent_events"
    case supervisorStatus = "supervisor_status"
    case supervisorSummary = "supervisor_summary"
    case localApprovalRequired = "local_approval_required"
    case resultSummary = "result_summary"
    case failureCode = "failure_code"
    case updatedAt = "updated_at"
  }
}

public struct MCPServiceTaskSubmission: Codable, Equatable, Sendable {
  public let projectID: String
  public let prompt: String
  public let threadID: String?
  public let executionModel: String?
  public let executionEffort: String?
  public let supervisorModel: String?
  public let supervisorEffort: String?
  public let permissionMode: String?
  public let networkAccess: Bool
  public let acceptanceCriteria: [String]
  public let clientRequestID: String?

  public init(
    projectID: String,
    prompt: String,
    threadID: String? = nil,
    executionModel: String? = nil,
    executionEffort: String? = nil,
    supervisorModel: String? = nil,
    supervisorEffort: String? = nil,
    permissionMode: String? = nil,
    networkAccess: Bool = false,
    acceptanceCriteria: [String] = [],
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.prompt = prompt
    self.threadID = threadID
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.supervisorModel = supervisorModel
    self.supervisorEffort = supervisorEffort
    self.permissionMode = permissionMode
    self.networkAccess = networkAccess
    self.acceptanceCriteria = acceptanceCriteria
    self.clientRequestID = clientRequestID
  }
}

public struct MCPServiceTaskSubmissionReceipt: Codable, Equatable, Sendable {
  public let taskID: String
  public let status: String
  public let reusedExistingTask: Bool
  public let localApprovalRequired: Bool

  public init(
    taskID: String,
    status: String,
    reusedExistingTask: Bool,
    localApprovalRequired: Bool
  ) {
    self.taskID = taskID
    self.status = status
    self.reusedExistingTask = reusedExistingTask
    self.localApprovalRequired = localApprovalRequired
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case status
    case reusedExistingTask = "reused_existing_task"
    case localApprovalRequired = "local_approval_required"
  }
}

public struct MCPServiceTaskMutationReceipt: Codable, Equatable, Sendable {
  public let taskID: String
  public let status: String
  public let accepted: Bool

  public init(taskID: String, status: String, accepted: Bool) {
    self.taskID = taskID
    self.status = status
    self.accepted = accepted
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case status
    case accepted
  }
}

public struct MCPWorkspaceOwner: Codable, Equatable, Sendable {
  public let owner: String
  public let taskID: String?
  public let operationID: String?
  public let sessionID: String?

  public init(
    owner: String,
    taskID: String? = nil,
    operationID: String? = nil,
    sessionID: String? = nil
  ) {
    self.owner = owner
    self.taskID = taskID
    self.operationID = operationID
    self.sessionID = sessionID
  }

  public init(detail: WorkspaceBusyDetail) {
    self.init(
      owner: detail.owner,
      taskID: detail.taskID,
      operationID: detail.operationID,
      sessionID: detail.sessionID
    )
  }

  private enum CodingKeys: String, CodingKey {
    case owner
    case taskID = "task_id"
    case operationID = "operation_id"
    case sessionID = "session_id"
  }
}

public struct MCPBoundedDiff: Codable, Equatable, Sendable {
  public let removedLines: [String]
  public let addedLines: [String]
  public let truncated: Bool
  public let byteCount: Int

  public init(removedLines: [String], addedLines: [String], truncated: Bool, byteCount: Int) {
    self.removedLines = removedLines
    self.addedLines = addedLines
    self.truncated = truncated
    self.byteCount = byteCount
  }

  public static let empty = MCPBoundedDiff(
    removedLines: [], addedLines: [], truncated: false, byteCount: 0)

  private enum CodingKeys: String, CodingKey {
    case removedLines = "removed_lines"
    case addedLines = "added_lines"
    case truncated
    case byteCount = "byte_count"
  }
}

public struct MCPDirectWriteRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let relativePath: String
  public let mode: String
  public let content: String
  public let expectedSHA256: String?
  public let createParents: Bool
  public let clientRequestID: String?

  public init(
    projectID: String,
    relativePath: String,
    mode: String,
    content: String,
    expectedSHA256: String? = nil,
    createParents: Bool = false,
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.relativePath = relativePath
    self.mode = mode
    self.content = content
    self.expectedSHA256 = expectedSHA256
    self.createParents = createParents
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case relativePath = "relative_path"
    case mode
    case content
    case expectedSHA256 = "expected_sha256"
    case createParents = "create_parents"
    case clientRequestID = "client_request_id"
  }
}

public struct MCPDirectWriteReceipt: Codable, Equatable, Sendable {
  public let relativePath: String
  public let operation: String
  public let oldSHA256: String?
  public let newSHA256: String?
  public let byteCount: Int
  public let boundedDiff: MCPBoundedDiff

  public init(
    relativePath: String,
    operation: String,
    oldSHA256: String?,
    newSHA256: String?,
    byteCount: Int,
    boundedDiff: MCPBoundedDiff = .empty
  ) {
    self.relativePath = relativePath
    self.operation = operation
    self.oldSHA256 = oldSHA256
    self.newSHA256 = newSHA256
    self.byteCount = byteCount
    self.boundedDiff = boundedDiff
  }

  public init(result: MCPDirectWriteReceipt, boundedDiff: MCPBoundedDiff) {
    self.init(
      relativePath: result.relativePath,
      operation: result.operation,
      oldSHA256: result.oldSHA256,
      newSHA256: result.newSHA256,
      byteCount: result.byteCount,
      boundedDiff: boundedDiff
    )
  }

  private enum CodingKeys: String, CodingKey {
    case relativePath = "relative_path"
    case operation
    case oldSHA256 = "old_sha256"
    case newSHA256 = "new_sha256"
    case byteCount = "byte_count"
    case boundedDiff = "bounded_diff"
  }
}

public struct MCPDirectEditRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let relativePath: String
  public let expectedSHA256: String
  public let oldText: String
  public let newText: String
  public let expectedReplacements: Int
  public let clientRequestID: String?

  public init(
    projectID: String,
    relativePath: String,
    expectedSHA256: String,
    oldText: String,
    newText: String,
    expectedReplacements: Int = 1,
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.relativePath = relativePath
    self.expectedSHA256 = expectedSHA256
    self.oldText = oldText
    self.newText = newText
    self.expectedReplacements = expectedReplacements
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case relativePath = "relative_path"
    case expectedSHA256 = "expected_sha256"
    case oldText = "old_text"
    case newText = "new_text"
    case expectedReplacements = "expected_replacements"
    case clientRequestID = "client_request_id"
  }
}

public typealias MCPDirectEditReceipt = MCPDirectWriteReceipt

public struct MCPPatchHunk: Codable, Equatable, Sendable {
  public let context: String
  public let removals: [String]
  public let additions: [String]

  public init(context: String, removals: [String], additions: [String]) {
    self.context = context
    self.removals = removals
    self.additions = additions
  }

  private enum CodingKeys: String, CodingKey {
    case context
    case removals
    case additions
  }
}

public struct MCPPatchFileOperation: Codable, Equatable, Sendable {
  public let action: String
  public let relativePath: String
  public let expectedSHA256: String?
  public let hunks: [MCPPatchHunk]

  public init(
    action: String,
    relativePath: String,
    expectedSHA256: String? = nil,
    hunks: [MCPPatchHunk]
  ) {
    self.action = action
    self.relativePath = relativePath
    self.expectedSHA256 = expectedSHA256
    self.hunks = hunks
  }

  private enum CodingKeys: String, CodingKey {
    case action
    case relativePath = "relative_path"
    case expectedSHA256 = "expected_sha256"
    case hunks
  }
}

public struct MCPDirectPatchRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let patch: String
  public let clientRequestID: String?

  public init(
    projectID: String,
    patch: String,
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.patch = patch
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case patch
    case clientRequestID = "client_request_id"
  }
}

public struct MCPPartialCommit: Codable, Equatable, Sendable {
  public let changedFiles: [String]
  public let rollbackStatus: String

  public init(changedFiles: [String], rollbackStatus: String) {
    self.changedFiles = changedFiles
    self.rollbackStatus = rollbackStatus
  }

  private enum CodingKeys: String, CodingKey {
    case changedFiles = "changed_files"
    case rollbackStatus = "rollback_status"
  }
}

public struct MCPDirectPatchReceipt: Codable, Equatable, Sendable {
  public let operations: [MCPDirectWriteReceipt]
  public let partialCommit: MCPPartialCommit?

  public init(operations: [MCPDirectWriteReceipt], partialCommit: MCPPartialCommit? = nil) {
    self.operations = operations
    self.partialCommit = partialCommit
  }

  private enum CodingKeys: String, CodingKey {
    case operations
    case partialCommit = "partial_commit"
  }
}

public struct MCPDirectManagePathRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let action: String
  public let relativePath: String
  public let expectedSHA256: String?
  public let destinationRelativePath: String?
  public let sourceExpectedSHA256: String?
  public let destinationExpectedAbsent: Bool
  public let clientRequestID: String?

  public init(
    projectID: String,
    action: String,
    relativePath: String,
    expectedSHA256: String? = nil,
    destinationRelativePath: String? = nil,
    sourceExpectedSHA256: String? = nil,
    destinationExpectedAbsent: Bool = true,
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.action = action
    self.relativePath = relativePath
    self.expectedSHA256 = expectedSHA256
    self.destinationRelativePath = destinationRelativePath
    self.sourceExpectedSHA256 = sourceExpectedSHA256
    self.destinationExpectedAbsent = destinationExpectedAbsent
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case action
    case relativePath = "relative_path"
    case expectedSHA256 = "expected_sha256"
    case destinationRelativePath = "destination_relative_path"
    case sourceExpectedSHA256 = "source_expected_sha256"
    case destinationExpectedAbsent = "destination_expected_absent"
    case clientRequestID = "client_request_id"
  }
}

public struct MCPDirectManagePathReceipt: Codable, Equatable, Sendable {
  public let relativePath: String
  public let operation: String
  public let oldSHA256: String?
  public let newSHA256: String?
  public let byteCount: Int

  public init(
    relativePath: String,
    operation: String,
    oldSHA256: String? = nil,
    newSHA256: String? = nil,
    byteCount: Int = 0
  ) {
    self.relativePath = relativePath
    self.operation = operation
    self.oldSHA256 = oldSHA256
    self.newSHA256 = newSHA256
    self.byteCount = byteCount
  }

  private enum CodingKeys: String, CodingKey {
    case relativePath = "relative_path"
    case operation
    case oldSHA256 = "old_sha256"
    case newSHA256 = "new_sha256"
    case byteCount = "byte_count"
  }
}

public struct MCPProjectCommand: Codable, Equatable, Sendable {
  public let commandID: String
  public let name: String
  public let executable: String
  public let arguments: [String]
  public let workingDirectory: String?
  public let requiresNetwork: Bool
  public let risk: String

  public init(
    commandID: String,
    name: String,
    executable: String,
    arguments: [String],
    workingDirectory: String? = nil,
    requiresNetwork: Bool = false,
    risk: String = "normal"
  ) {
    self.commandID = commandID
    self.name = name
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.requiresNetwork = requiresNetwork
    self.risk = risk
  }

  private enum CodingKeys: String, CodingKey {
    case commandID = "command_id"
    case name
    case executable
    case arguments
    case workingDirectory = "working_directory"
    case requiresNetwork = "requires_network"
    case risk
  }
}

public struct MCPProjectCommands: Codable, Equatable, Sendable {
  public let commandMode: String
  public let commands: [MCPProjectCommand]

  public init(commandMode: String, commands: [MCPProjectCommand]) {
    self.commandMode = commandMode
    self.commands = commands
  }

  private enum CodingKeys: String, CodingKey {
    case commandMode = "command_mode"
    case commands
  }
}

public struct MCPProjectChanges: Codable, Equatable, Sendable {
  public let changedFiles: [String]
  public let diff: String
  public let additions: Int
  public let deletions: Int
  public let truncated: Bool
  public let notGitRepository: Bool

  public init(
    changedFiles: [String],
    diff: String,
    additions: Int,
    deletions: Int,
    truncated: Bool,
    notGitRepository: Bool
  ) {
    self.changedFiles = changedFiles
    self.diff = diff
    self.additions = additions
    self.deletions = deletions
    self.truncated = truncated
    self.notGitRepository = notGitRepository
  }

  private enum CodingKeys: String, CodingKey {
    case changedFiles = "changed_files"
    case diff
    case additions
    case deletions
    case truncated
    case notGitRepository = "not_git_repository"
  }
}

public struct MCPDirectExecRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let commandID: String?
  public let argv: [String]
  public let workingDirectory: String?
  public let tty: Bool
  public let yieldTimeMS: Int
  public let timeoutMS: Int
  public let clientRequestID: String?

  public init(
    projectID: String,
    commandID: String? = nil,
    argv: [String],
    workingDirectory: String? = nil,
    tty: Bool = false,
    yieldTimeMS: Int = 1_000,
    timeoutMS: Int = 300_000,
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.commandID = commandID
    self.argv = argv
    self.workingDirectory = workingDirectory
    self.tty = tty
    self.yieldTimeMS = yieldTimeMS
    self.timeoutMS = timeoutMS
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case commandID = "command_id"
    case argv
    case workingDirectory = "working_directory"
    case tty
    case yieldTimeMS = "yield_time_ms"
    case timeoutMS = "timeout_ms"
    case clientRequestID = "client_request_id"
  }
}

public struct MCPDirectCommandReceipt: Codable, Equatable, Sendable {
  public let sessionID: String
  public let status: String
  public let exitCode: Int?
  public let startedAt: String?
  public let completedAt: String?
  public let output: MCPDirectCommandOutput?
  public let error: String?

  public init(
    sessionID: String,
    status: String,
    exitCode: Int? = nil,
    startedAt: String? = nil,
    completedAt: String? = nil,
    output: MCPDirectCommandOutput? = nil,
    error: String? = nil
  ) {
    self.sessionID = sessionID
    self.status = status
    self.exitCode = exitCode
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.output = output
    self.error = error
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case status
    case exitCode = "exit_code"
    case startedAt = "started_at"
    case completedAt = "completed_at"
    case output
    case error
  }
}

public struct MCPDirectCommandOutput: Codable, Equatable, Sendable {
  public let sessionID: String
  public let status: String
  public let sequence: Int
  public let stdout: String
  public let stderr: String
  public let truncated: Bool
  public let exitCode: Int?
  public let completedAt: String?

  public init(
    sessionID: String,
    status: String,
    sequence: Int,
    stdout: String,
    stderr: String,
    truncated: Bool,
    exitCode: Int? = nil,
    completedAt: String? = nil
  ) {
    self.sessionID = sessionID
    self.status = status
    self.sequence = sequence
    self.stdout = stdout
    self.stderr = stderr
    self.truncated = truncated
    self.exitCode = exitCode
    self.completedAt = completedAt
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case status
    case sequence
    case stdout
    case stderr
    case truncated
    case exitCode = "exit_code"
    case completedAt = "completed_at"
  }
}
