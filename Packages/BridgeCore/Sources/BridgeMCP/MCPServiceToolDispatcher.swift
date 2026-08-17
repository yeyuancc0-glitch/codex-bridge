import BridgeSecurity
import Foundation
import Logging
import MCP

public struct MCPServiceToolDeadlines: Sendable {
  public static let production = MCPServiceToolDeadlines(
    read: .seconds(15),
    submit: .seconds(5),
    mutation: .seconds(10)
  )

  public let read: ContinuousClock.Duration
  public let submit: ContinuousClock.Duration
  public let mutation: ContinuousClock.Duration

  public init(
    read: ContinuousClock.Duration,
    submit: ContinuousClock.Duration,
    mutation: ContinuousClock.Duration
  ) {
    precondition(read > .zero && submit > .zero && mutation > .zero)
    self.read = read
    self.submit = submit
    self.mutation = mutation
  }
}

public struct MCPServiceToolDispatcher: Sendable {
  private let service: any BridgeMCPServiceAPI
  private let exposureMode: MCPServiceExposureMode
  private let resultEncoder: MCPToolResultEncoder
  private let admission: MCPToolAdmission
  private let deadlines: MCPServiceToolDeadlines
  private let logger: Logger
  private let clock = ContinuousClock()

  public init(
    service: any BridgeMCPServiceAPI,
    exposureMode: MCPServiceExposureMode,
    resultEncoder: MCPToolResultEncoder = .init(),
    admission: MCPToolAdmission = .init(),
    deadlines: MCPServiceToolDeadlines = .production,
    logger: Logger = Logger(label: "CodexBridge.BridgeMCP.ServiceTools")
  ) {
    self.service = service
    self.exposureMode = exposureMode
    self.resultEncoder = resultEncoder
    self.admission = admission
    self.deadlines = deadlines
    self.logger = logger
  }

  public func call(
    _ parameters: CallTool.Parameters,
    sessionID: String = "direct"
  ) async throws -> CallTool.Result {
    guard let name = MCPServiceToolName(rawValue: parameters.name), isExposed(name) else {
      throw MCPError.invalidParams("Unknown tool name.")
    }
    let key = sessionID.isEmpty ? "direct" : sessionID
    guard await admission.acquire(sessionID: key) else {
      return try encodeQueryError(.busy)
    }
    defer { Task { await admission.release(sessionID: key) } }

    do {
      return try await callAdmitted(name, arguments: parameters.arguments)
    } catch let error as BridgeMCPQueryError {
      return try encodeQueryError(error)
    } catch let error as MCPToolResultEncodingError {
      return try encodeResultError(error)
    } catch let error as MCPError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let correlationID = UUID().uuidString.lowercased()
      logger.error(
        "Lightweight MCP service tool request failed.",
        metadata: ["correlation_id": .string(correlationID)]
      )
      throw MCPError.internalError("The tool request failed.")
    }
  }

  private func callAdmitted(
    _ name: MCPServiceToolName,
    arguments: [String: Value]?
  ) async throws -> CallTool.Result {
    switch name {
    case .bridgeStatus:
      let values = try StrictToolArguments(arguments, allowed: [])
      _ = values
      let deadline = clock.now.advanced(by: deadlines.read)
      let snapshot = try await withToolDeadline(until: deadline) {
        try await service.serviceStatus(deadline: deadline)
      }
      return try resultEncoder.encode(BridgeStatusOutput(snapshot: snapshot))

    case .listProjects:
      let values = try StrictToolArguments(arguments, allowed: ["cursor", "limit"])
      let cursor = try values.optionalString("cursor", maximumUTF8Bytes: 2_048)
      let limit = try values.limit()
      let deadline = clock.now.advanced(by: deadlines.read)
      let page = try await withToolDeadline(until: deadline) {
        try await service.serviceProjects(cursor: cursor, limit: limit, deadline: deadline)
      }
      return try resultEncoder.encode(ListProjectsOutput(page: page))

    case .getProject:
      let values = try StrictToolArguments(
        arguments,
        allowed: ["project_id"],
        required: ["project_id"]
      )
      let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
      let deadline = clock.now.advanced(by: deadlines.read)
      let project = try await withToolDeadline(until: deadline) {
        try await service.serviceProject(projectID: projectID, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceGetProjectOutput(project: project))

    case .searchProjectFiles:
      let values = try StrictToolArguments(
        arguments,
        allowed: [
          "project_id", "query", "relative_directory", "case_sensitive", "cursor", "limit",
        ],
        required: ["project_id", "query"]
      )
      let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
      let query = try values.requiredText("query", maximumUTF8Bytes: 512)
      let directory = try values.optionalString(
        "relative_directory",
        maximumUTF8Bytes: 1_024
      )
      let caseSensitive = try values.optionalBoolean("case_sensitive") ?? false
      let cursor = try values.optionalString("cursor", maximumUTF8Bytes: 2_048)
      let limit = try values.limit(maximum: 50)
      let deadline = clock.now.advanced(by: deadlines.read)
      let page = try await withToolDeadline(until: deadline) {
        try await service.serviceSearchProjectFiles(
          projectID: projectID,
          query: query,
          relativeDirectory: directory,
          caseSensitive: caseSensitive,
          cursor: cursor,
          limit: limit,
          deadline: deadline
        )
      }
      return try resultEncoder.encode(ServiceSearchProjectFilesOutput(page: page))

    case .readProjectFile:
      let values = try StrictToolArguments(
        arguments,
        allowed: ["project_id", "relative_path", "start_line", "line_count"],
        required: ["project_id", "relative_path"]
      )
      let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
      let path = try values.requiredIdentifier("relative_path", maximumUTF8Bytes: 1_024)
      guard OutboundContentSecurity.isSafeRelativePath(path) else {
        throw MCPError.invalidParams("Argument 'relative_path' must be a safe relative path.")
      }
      let startLine = try values.optionalPositiveInteger("start_line", maximum: Int.max) ?? 1
      let lineCount = try values.optionalPositiveInteger("line_count", maximum: 300) ?? 200
      let deadline = clock.now.advanced(by: deadlines.read)
      let page = try await withToolDeadline(until: deadline) {
        try await service.serviceReadProjectFile(
          projectID: projectID,
          relativePath: path,
          startLine: startLine,
          lineCount: lineCount,
          deadline: deadline
        )
      }
      return try resultEncoder.encode(ServiceReadProjectFileOutput(page: page))

    case .listThreads:
      let values = try StrictToolArguments(
        arguments,
        allowed: ["project_id", "cursor", "limit", "search"],
        required: ["project_id"]
      )
      let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
      let cursor = try values.optionalString("cursor", maximumUTF8Bytes: 2_048)
      let limit = try values.limit()
      let search = try values.optionalString("search", maximumUTF8Bytes: 200)
      let deadline = clock.now.advanced(by: deadlines.read)
      let page = try await withToolDeadline(until: deadline) {
        try await service.serviceThreads(
          projectID: projectID,
          cursor: cursor,
          limit: limit,
          search: search,
          deadline: deadline
        )
      }
      return try resultEncoder.encode(ListThreadsOutput(page: page))

    case .readThread:
      let values = try StrictToolArguments(
        arguments,
        allowed: ["project_id", "thread_id", "detail", "cursor", "limit"],
        required: ["project_id", "thread_id"]
      )
      let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
      let threadID = try values.requiredIdentifier("thread_id", maximumUTF8Bytes: 1_024)
      let detail = try values.threadDetail()
      let cursor = try values.optionalString("cursor", maximumUTF8Bytes: 2_048)
      let limit = try values.limit()
      let deadline = clock.now.advanced(by: deadlines.read)
      let page = try await withToolDeadline(until: deadline) {
        try await service.serviceReadThread(
          projectID: projectID,
          threadID: threadID,
          detail: detail,
          cursor: cursor,
          limit: limit,
          deadline: deadline
        )
      }
      return try resultEncoder.encode(ReadThreadOutput(page: page))

    case .listModels:
      _ = try StrictToolArguments(arguments, allowed: [])
      let deadline = clock.now.advanced(by: deadlines.read)
      let models = try await withToolDeadline(until: deadline) {
        try await service.serviceModels(deadline: deadline)
      }
      return try resultEncoder.encode(ListModelsOutput(list: models))

    case .getTask:
      let values = try StrictToolArguments(
        arguments,
        allowed: ["task_id", "recent_event_limit"],
        required: ["task_id"]
      )
      let taskID = try values.requiredIdentifier("task_id", maximumUTF8Bytes: 128)
      let eventLimit =
        try values.optionalPositiveInteger(
          "recent_event_limit",
          maximum: 50
        ) ?? 20
      let deadline = clock.now.advanced(by: deadlines.read)
      let snapshot = try await withToolDeadline(until: deadline) {
        try await service.serviceTask(
          taskID: taskID,
          recentEventLimit: eventLimit,
          deadline: deadline
        )
      }
      try validate(snapshot, requestedTaskID: taskID, eventLimit: eventLimit)
      return try resultEncoder.encode(ServiceGetTaskOutput(task: snapshot))

    case .submitTask:
      let submission = try parseSubmission(arguments)
      let deadline = clock.now.advanced(by: deadlines.submit)
      let receipt = try await withToolDeadline(until: deadline) {
        try await service.serviceSubmitTask(submission, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceSubmitTaskOutput(receipt: receipt))

    case .steerTask:
      let values = try StrictToolArguments(
        arguments,
        allowed: ["task_id", "expected_turn_id", "input"],
        required: ["task_id", "expected_turn_id", "input"]
      )
      let taskID = try values.requiredIdentifier("task_id", maximumUTF8Bytes: 128)
      let turnID = try values.requiredIdentifier("expected_turn_id", maximumUTF8Bytes: 1_024)
      let input = try values.requiredText("input", maximumUTF8Bytes: 32 * 1_024)
      guard OutboundContentSecurity.isSafe(input) else {
        throw MCPError.invalidParams("Task input contains restricted local data.")
      }
      let deadline = clock.now.advanced(by: deadlines.mutation)
      let receipt = try await withToolDeadline(until: deadline) {
        try await service.serviceSteerTask(
          taskID: taskID,
          expectedTurnID: turnID,
          input: input,
          deadline: deadline
        )
      }
      return try resultEncoder.encode(ServiceMutateTaskOutput(receipt: receipt))

    case .interruptTask:
      let values = try StrictToolArguments(
        arguments,
        allowed: ["task_id", "expected_turn_id"],
        required: ["task_id", "expected_turn_id"]
      )
      let taskID = try values.requiredIdentifier("task_id", maximumUTF8Bytes: 128)
      let turnID = try values.requiredIdentifier("expected_turn_id", maximumUTF8Bytes: 1_024)
      let deadline = clock.now.advanced(by: deadlines.mutation)
      let receipt = try await withToolDeadline(until: deadline) {
        try await service.serviceInterruptTask(
          taskID: taskID,
          expectedTurnID: turnID,
          deadline: deadline
        )
      }
      return try resultEncoder.encode(ServiceMutateTaskOutput(receipt: receipt))
    }
  }

  private func parseSubmission(_ arguments: [String: Value]?) throws
    -> MCPServiceTaskSubmission
  {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 96 * 1_024 else {
      throw MCPError.invalidParams("The task request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "prompt", "thread_id", "execution_model", "execution_effort",
        "supervisor_model", "supervisor_effort", "permission_mode", "network_access",
        "acceptance_criteria", "client_request_id",
      ],
      required: ["project_id", "prompt"]
    )
    let prompt = try values.requiredText("prompt", maximumUTF8Bytes: 32 * 1_024)
    let criteria = try values.optionalStringArray(
      "acceptance_criteria",
      maximumCount: 32,
      maximumElementUTF8Bytes: 4_096
    )
    guard ([prompt] + criteria).allSatisfy(OutboundContentSecurity.isSafe) else {
      throw MCPError.invalidParams("Task text contains restricted local data.")
    }
    let permissionMode = try values.optionalIdentifier(
      "permission_mode",
      maximumUTF8Bytes: 32
    )
    if let permissionMode,
      permissionMode != "read-only" && permissionMode != "workspace-write"
    {
      throw MCPError.invalidParams("Argument 'permission_mode' is invalid.")
    }
    let supervisorModel = try values.optionalIdentifier(
      "supervisor_model",
      maximumUTF8Bytes: 256
    )
    let supervisorEffort = try values.optionalIdentifier(
      "supervisor_effort",
      maximumUTF8Bytes: 64
    )
    guard (supervisorModel == nil) == (supervisorEffort == nil) else {
      throw MCPError.invalidParams(
        "Supervisor model and effort must be supplied together."
      )
    }
    return MCPServiceTaskSubmission(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      prompt: prompt,
      threadID: try values.optionalIdentifier("thread_id", maximumUTF8Bytes: 1_024),
      executionModel: try values.optionalIdentifier(
        "execution_model",
        maximumUTF8Bytes: 256
      ),
      executionEffort: try values.optionalIdentifier(
        "execution_effort",
        maximumUTF8Bytes: 64
      ),
      supervisorModel: supervisorModel,
      supervisorEffort: supervisorEffort,
      permissionMode: permissionMode,
      networkAccess: try values.optionalBoolean("network_access") ?? false,
      acceptanceCriteria: criteria,
      clientRequestID: try values.optionalIdentifier(
        "client_request_id",
        maximumUTF8Bytes: 512
      )
    )
  }

  private func validate(
    _ snapshot: MCPServiceTaskSnapshot,
    requestedTaskID: String,
    eventLimit: Int
  ) throws {
    guard snapshot.taskID == requestedTaskID,
      !snapshot.projectID.isEmpty,
      !snapshot.status.isEmpty,
      !snapshot.supervisorStatus.isEmpty,
      snapshot.recentEvents.count <= eventLimit,
      snapshot.changedFiles.allSatisfy({
        OutboundContentSecurity.isSafeOutboundRelativePath($0)
      }),
      snapshot.currentStep.map(OutboundContentSecurity.isSafe) ?? true,
      snapshot.supervisorSummary.map(OutboundContentSecurity.isSafe) ?? true,
      snapshot.resultSummary.map(OutboundContentSecurity.isSafe) ?? true
    else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
    var prior: Int64 = -1
    for event in snapshot.recentEvents {
      guard event.sequence > prior,
        !event.kind.isEmpty,
        OutboundContentSecurity.isSafe(event.summary)
      else {
        throw MCPToolAdapterError.invalidQueryOutput
      }
      prior = event.sequence
    }
  }

  private func isExposed(_ name: MCPServiceToolName) -> Bool {
    exposureMode == .full || ![.submitTask, .steerTask, .interruptTask].contains(name)
  }

  private func encodeQueryError(_ error: BridgeMCPQueryError) throws -> CallTool.Result {
    let dto: MCPToolErrorDTO
    switch error {
    case .projectNotFound:
      dto = .init(
        code: "project_not_found",
        message: "The project is unavailable.",
        retryable: false
      )
    case .threadNotFound:
      dto = .init(
        code: "thread_not_found",
        message: "The Thread is unavailable.",
        retryable: false
      )
    case .pathDenied:
      dto = .init(code: "path_denied", message: "The path is not allowed.", retryable: false)
    case .taskNotFound:
      dto = .init(code: "task_not_found", message: "The task is unavailable.", retryable: false)
    case .idempotencyConflict:
      dto = .init(
        code: "idempotency_conflict",
        message: "The request identifier is already bound to another task.",
        retryable: false
      )
    case .turnMismatch:
      dto = .init(code: "turn_mismatch", message: "The active Turn changed.", retryable: false)
    case .eventSequenceMismatch:
      dto = .init(code: "task_changed", message: "The task changed.", retryable: false)
    case .invalidTaskState:
      dto = .init(
        code: "invalid_task_state",
        message: "The operation is invalid for the current task state.",
        retryable: false
      )
    case .contractRejected:
      dto = .init(
        code: "contract_rejected",
        message: "Local policy rejected the task.",
        retryable: false
      )
    case .busy:
      dto = .init(code: "busy", message: "The Bridge is busy.", retryable: true)
    case .timeout:
      dto = .init(code: "timeout", message: "The operation timed out.", retryable: true)
    case .unavailable:
      dto = .init(
        code: "unavailable",
        message: "A local component is unavailable.",
        retryable: true
      )
    }
    return try resultEncoder.encode(MCPToolErrorOutput(error: dto), isError: true)
  }

  private func encodeResultError(_ error: MCPToolResultEncodingError) throws -> CallTool.Result {
    switch error {
    case .resultTooLarge:
      return try resultEncoder.encode(
        MCPToolErrorOutput(
          error: .init(
            code: "result_too_large",
            message: "The result is too large. Request a smaller page.",
            retryable: true
          )
        ),
        isError: true
      )
    }
  }
}

private struct ServiceGetProjectOutput: Codable, Sendable {
  let schemaVersion = 1
  let project: MCPProjectDetail

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case project
  }
}

private struct ServiceSearchProjectFilesOutput: Codable, Sendable {
  let schemaVersion = 1
  let matches: [MCPProjectFileSearchMatch]
  let nextCursor: String?
  let skippedFileCount: Int

  init(page: MCPProjectFileSearchPage) {
    matches = page.matches
    nextCursor = page.nextCursor
    skippedFileCount = page.skippedFileCount
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case matches
    case nextCursor = "next_cursor"
    case skippedFileCount = "skipped_file_count"
  }
}

private struct ServiceReadProjectFileOutput: Codable, Sendable {
  let schemaVersion = 1
  let relativePath: String
  let startLine: Int
  let endLine: Int?
  let content: String
  let redactedLineCount: Int
  let truncated: Bool
  let nextStartLine: Int?

  init(page: MCPProjectFileReadPage) {
    relativePath = page.relativePath
    startLine = page.startLine
    endLine = page.endLine
    content = page.content
    redactedLineCount = page.redactedLineCount
    truncated = page.truncated
    nextStartLine = page.nextStartLine
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case relativePath = "relative_path"
    case startLine = "start_line"
    case endLine = "end_line"
    case content
    case redactedLineCount = "redacted_line_count"
    case truncated
    case nextStartLine = "next_start_line"
  }
}

private struct ServiceGetTaskOutput: Codable, Sendable {
  let schemaVersion = 1
  let task: MCPServiceTaskSnapshot

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case task
  }
}

private struct ServiceSubmitTaskOutput: Codable, Sendable {
  let schemaVersion = 1
  let taskID: String
  let status: String
  let reusedExistingTask: Bool
  let localApprovalRequired: Bool

  init(receipt: MCPServiceTaskSubmissionReceipt) {
    taskID = receipt.taskID
    status = receipt.status
    reusedExistingTask = receipt.reusedExistingTask
    localApprovalRequired = receipt.localApprovalRequired
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case taskID = "task_id"
    case status
    case reusedExistingTask = "reused_existing_task"
    case localApprovalRequired = "local_approval_required"
  }
}

private struct ServiceMutateTaskOutput: Codable, Sendable {
  let schemaVersion = 1
  let taskID: String
  let status: String
  let accepted: Bool

  init(receipt: MCPServiceTaskMutationReceipt) {
    taskID = receipt.taskID
    status = receipt.status
    accepted = receipt.accepted
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case taskID = "task_id"
    case status
    case accepted
  }
}
