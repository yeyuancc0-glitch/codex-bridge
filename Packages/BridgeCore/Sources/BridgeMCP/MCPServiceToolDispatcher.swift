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
        "Lightweight MCP service tool request failed. name=\(parameters.name) error=\(error) type=\(String(describing: type(of: error)))",
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
      let requestedCount =
        try values.optionalPositiveInteger("line_count", maximum: Int.max)
        ?? 200
      let lineCount = min(requestedCount, 300)
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

    case .getProjectChanges:
      let values = try StrictToolArguments(
        arguments,
        allowed: ["project_id"],
        required: ["project_id"]
      )
      let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
      let deadline = clock.now.advanced(by: deadlines.read)
      let changes = try await withToolDeadline(until: deadline) {
        try await service.serviceProjectChanges(projectID: projectID, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceProjectChangesOutput(changes: changes))

    case .listProjectCommands:
      let values = try StrictToolArguments(
        arguments,
        allowed: ["project_id"],
        required: ["project_id"]
      )
      let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
      let deadline = clock.now.advanced(by: deadlines.read)
      let commands = try await withToolDeadline(until: deadline) {
        try await service.serviceProjectCommands(projectID: projectID, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceProjectCommandsOutput(commands: commands))

    case .directWriteProjectFile:
      let request = try parseDirectWrite(arguments)
      let deadline = clock.now.advanced(by: deadlines.mutation)
      let receipt = try await withToolDeadline(until: deadline) {
        try await service.serviceDirectWriteFile(request, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceDirectMutationOutput(receipt: receipt))

    case .directEditProjectFile:
      let request = try parseDirectEdit(arguments)
      let deadline = clock.now.advanced(by: deadlines.mutation)
      let receipt = try await withToolDeadline(until: deadline) {
        try await service.serviceDirectEditFile(request, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceDirectMutationOutput(receipt: receipt))

    case .directApplyProjectPatch:
      let request = try parseDirectPatch(arguments)
      let deadline = clock.now.advanced(by: deadlines.mutation)
      let receipt = try await withToolDeadline(until: deadline) {
        try await service.serviceDirectApplyPatch(request, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceDirectPatchOutput(receipt: receipt))

    case .directManageProjectPath:
      let request = try parseDirectManagePath(arguments)
      let deadline = clock.now.advanced(by: deadlines.mutation)
      let receipt = try await withToolDeadline(until: deadline) {
        try await service.serviceDirectManagePath(request, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceDirectManagePathOutput(receipt: receipt))

    case .directExecCommand:
      let request = try parseDirectExec(arguments)
      let deadline = clock.now.advanced(by: deadlines.mutation)
      let receipt = try await withToolDeadline(until: deadline) {
        try await service.serviceDirectExecCommand(request, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceDirectExecOutput(receipt: receipt))

    case .directGitCommit:
      let request = try parseDirectGitCommit(arguments)
      let deadline = clock.now.advanced(by: deadlines.mutation)
      let receipt = try await withToolDeadline(until: deadline) {
        try await service.serviceDirectGitCommit(request, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceDirectGitCommitOutput(receipt: receipt))

    case .directReadCommand:
      let values = try StrictToolArguments(
        arguments,
        allowed: ["session_id"],
        required: ["session_id"]
      )
      let sessionID = try values.requiredIdentifier("session_id", maximumUTF8Bytes: 128)
      let deadline = clock.now.advanced(by: deadlines.read)
      let output = try await withToolDeadline(until: deadline) {
        try await service.serviceDirectReadCommand(sessionID: sessionID, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceDirectCommandOutput(output: output))

    case .directWriteStdin:
      let values = try StrictToolArguments(
        arguments,
        allowed: ["session_id", "data"],
        required: ["session_id", "data"]
      )
      let sessionID = try values.requiredIdentifier("session_id", maximumUTF8Bytes: 128)
      let data = try values.requiredText("data", maximumUTF8Bytes: 64 * 1_024)
      let deadline = clock.now.advanced(by: deadlines.mutation)
      try await withToolDeadline(until: deadline) {
        try await service.serviceDirectWriteStdin(
          sessionID: sessionID,
          data: data,
          deadline: deadline
        )
      }
      return try resultEncoder.encode(ServiceDirectWriteStdinOutput())

    case .directInterruptCommand:
      let values = try StrictToolArguments(
        arguments,
        allowed: ["session_id"],
        required: ["session_id"]
      )
      let sessionID = try values.requiredIdentifier("session_id", maximumUTF8Bytes: 128)
      let deadline = clock.now.advanced(by: deadlines.mutation)
      let output = try await withToolDeadline(until: deadline) {
        try await service.serviceDirectInterruptCommand(sessionID: sessionID, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceDirectCommandOutput(output: output))
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

  private func parseDirectWrite(_ arguments: [String: Value]?) throws -> MCPDirectWriteRequest {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 512 * 1_024 else {
      throw MCPError.invalidParams("The write request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "relative_path", "mode", "content", "expected_sha256", "create_parents",
        "client_request_id",
      ],
      required: ["project_id", "relative_path", "mode", "content"]
    )
    let mode = try values.requiredIdentifier("mode", maximumUTF8Bytes: 16)
    guard mode == "create" || mode == "replace" else {
      throw MCPError.invalidParams("Argument 'mode' is invalid.")
    }
    let content = try values.requiredText("content", maximumUTF8Bytes: 256 * 1_024)
    guard OutboundContentSecurity.isSafe(content) else {
      throw MCPError.invalidParams("Write content contains restricted local data.")
    }
    let path = try values.requiredIdentifier("relative_path", maximumUTF8Bytes: 1_024)
    guard OutboundContentSecurity.isSafeRelativePath(path) else {
      throw MCPError.invalidParams("Argument 'relative_path' must be a safe relative path.")
    }
    return MCPDirectWriteRequest(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      relativePath: path,
      mode: mode,
      content: content,
      expectedSHA256: try values.optionalIdentifier("expected_sha256", maximumUTF8Bytes: 64),
      createParents: try values.optionalBoolean("create_parents") ?? false,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

  private func parseDirectEdit(_ arguments: [String: Value]?) throws -> MCPDirectEditRequest {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 512 * 1_024 else {
      throw MCPError.invalidParams("The edit request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "relative_path", "expected_sha256", "old_text", "new_text",
        "expected_replacements", "client_request_id",
      ],
      required: ["project_id", "relative_path", "expected_sha256", "old_text", "new_text"]
    )
    let oldText = try values.requiredText("old_text", maximumUTF8Bytes: 256 * 1_024)
    let newText = try values.requiredText("new_text", maximumUTF8Bytes: 256 * 1_024)
    guard OutboundContentSecurity.isSafe(oldText), OutboundContentSecurity.isSafe(newText) else {
      throw MCPError.invalidParams("Edit text contains restricted local data.")
    }
    let path = try values.requiredIdentifier("relative_path", maximumUTF8Bytes: 1_024)
    guard OutboundContentSecurity.isSafeRelativePath(path) else {
      throw MCPError.invalidParams("Argument 'relative_path' must be a safe relative path.")
    }
    return MCPDirectEditRequest(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      relativePath: path,
      expectedSHA256: try values.requiredIdentifier("expected_sha256", maximumUTF8Bytes: 64),
      oldText: oldText,
      newText: newText,
      expectedReplacements: try values.optionalPositiveInteger(
        "expected_replacements", maximum: 1_000) ?? 1,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

  private func parseDirectPatch(_ arguments: [String: Value]?) throws -> MCPDirectPatchRequest {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 512 * 1_024 else {
      throw MCPError.invalidParams("The patch request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: ["project_id", "patch", "client_request_id"],
      required: ["project_id", "patch"]
    )
    let patch = try values.requiredText("patch", maximumUTF8Bytes: 256 * 1_024)
    guard OutboundContentSecurity.isSafe(patch) else {
      throw MCPError.invalidParams("Patch text contains restricted local data.")
    }
    return MCPDirectPatchRequest(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      patch: patch,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

  private func parseDirectExec(_ arguments: [String: Value]?) throws -> MCPDirectExecRequest {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 128 * 1_024 else {
      throw MCPError.invalidParams("The command request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "command_id", "argv", "working_directory", "tty", "yield_time_ms",
        "timeout_ms", "client_request_id",
      ],
      required: ["project_id", "argv"]
    )
    let argv = try values.optionalStringArray(
      "argv", maximumCount: 128, maximumElementUTF8Bytes: 4_096)
    guard !argv.isEmpty else {
      throw MCPError.invalidParams("Argument 'argv' must contain an executable.")
    }
    let commandID = try values.optionalIdentifier("command_id", maximumUTF8Bytes: 256)
    let workingDirectory = try values.optionalIdentifier(
      "working_directory", maximumUTF8Bytes: 1_024)
    if let workingDirectory, !OutboundContentSecurity.isSafeRelativePath(workingDirectory) {
      throw MCPError.invalidParams(
        "Argument 'working_directory' must be a safe relative path.")
    }
    let yieldTimeMS = try values.optionalNonnegativeInteger("yield_time_ms").map(Int.init)
    let timeoutMS = try values.optionalPositiveInteger(
      "timeout_ms", maximum: 3_600_000)
    return MCPDirectExecRequest(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      commandID: commandID,
      argv: argv,
      workingDirectory: workingDirectory,
      tty: try values.optionalBoolean("tty") ?? false,
      yieldTimeMS: yieldTimeMS ?? 1_000,
      timeoutMS: timeoutMS ?? 300_000,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

  private func parseDirectGitCommit(_ arguments: [String: Value]?) throws
    -> MCPDirectGitCommitRequest
  {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 128 * 1_024 else {
      throw MCPError.invalidParams("The git commit request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: ["project_id", "message", "files", "client_request_id"],
      required: ["project_id", "message"]
    )
    let files = try values.optionalStringArray(
      "files", maximumCount: 128, maximumElementUTF8Bytes: 1_024)
    for file in files {
      guard OutboundContentSecurity.isSafeRelativePath(file) else {
        throw MCPError.invalidParams("Argument 'files' must contain safe relative paths.")
      }
    }
    return MCPDirectGitCommitRequest(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      message: try values.requiredText("message", maximumUTF8Bytes: 4_096),
      files: files,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

  private func parseDirectManagePath(_ arguments: [String: Value]?) throws
    -> MCPDirectManagePathRequest
  {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 128 * 1_024 else {
      throw MCPError.invalidParams("The path request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "action", "relative_path", "expected_sha256",
        "destination_relative_path", "source_expected_sha256", "destination_expected_absent",
        "client_request_id",
      ],
      required: ["project_id", "action", "relative_path"]
    )
    let action = try values.requiredIdentifier("action", maximumUTF8Bytes: 32)
    guard
      ["delete_file", "move_file", "create_directory", "delete_empty_directory"].contains(action)
    else {
      throw MCPError.invalidParams("Argument 'action' is invalid.")
    }
    let path = try values.requiredIdentifier("relative_path", maximumUTF8Bytes: 1_024)
    guard OutboundContentSecurity.isSafeRelativePath(path) else {
      throw MCPError.invalidParams("Argument 'relative_path' must be a safe relative path.")
    }
    let destination = try values.optionalIdentifier(
      "destination_relative_path", maximumUTF8Bytes: 1_024)
    if let destination, !OutboundContentSecurity.isSafeRelativePath(destination) {
      throw MCPError.invalidParams(
        "Argument 'destination_relative_path' must be a safe relative path.")
    }
    if action == "move_file", destination == nil {
      throw MCPError.invalidParams("Argument 'destination_relative_path' is required for move.")
    }
    return MCPDirectManagePathRequest(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      action: action,
      relativePath: path,
      expectedSHA256: try values.optionalIdentifier("expected_sha256", maximumUTF8Bytes: 64),
      destinationRelativePath: destination,
      sourceExpectedSHA256: try values.optionalIdentifier(
        "source_expected_sha256", maximumUTF8Bytes: 64),
      destinationExpectedAbsent: try values.optionalBoolean("destination_expected_absent") ?? true,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
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
    exposureMode == .full
      || ![
        .submitTask, .steerTask, .interruptTask, .directWriteProjectFile, .directEditProjectFile,
        .directApplyProjectPatch, .directManageProjectPath,
      ].contains(name)
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
    case .projectBusy(let detail):
      dto = .init(
        code: "project_busy",
        message: Self.projectBusyMessage(detail),
        retryable: true,
        owner: detail.owner,
        taskID: detail.taskID,
        operationID: detail.operationID,
        sessionID: detail.sessionID
      )
    case .timeout:
      dto = .init(code: "timeout", message: "The operation timed out.", retryable: true)
    case .unavailable:
      dto = .init(
        code: "unavailable",
        message: "A local component is unavailable.",
        retryable: true
      )
    case .fileRevisionConflict:
      dto = .init(
        code: "file_revision_conflict",
        message: "The file content does not match the expected revision. Read the file again.",
        retryable: true
      )
    case .revisionConflict(let detail):
      dto = .init(
        code: "revision_conflict",
        message: "The file changed since the expected revision. Re-read the file and retry.",
        retryable: true,
        data: detail.errorData
      )
    case .pathForbidden:
      dto = .init(code: "path_forbidden", message: "The path is not allowed.", retryable: false)
    case .pathChanged:
      dto = .init(
        code: "path_changed",
        message: "The target changed after it was validated. Read the file again.",
        retryable: true
      )
    case .writeNotAllowed:
      dto = .init(
        code: "write_not_allowed",
        message: "The project does not allow remote writes.",
        retryable: false
      )
    case .approvalRequired(let approvalID):
      dto = .init(
        code: "approval_required",
        message: "The local user must approve this action (approval \(approvalID)).",
        retryable: true,
        operationID: approvalID
      )
    case .approvalExpired:
      dto = .init(
        code: "approval_expired",
        message: "The local approval expired. Request a new approval.",
        retryable: true
      )
    case .invalidPatch:
      dto = .init(
        code: "invalid_patch",
        message: "The patch could not be parsed or applied.",
        retryable: false
      )
    case .notGitRepository:
      dto = .init(
        code: "not_git_repository",
        message: "The project is not a Git repository.",
        retryable: false
      )
    case .commandSessionNotFound:
      dto = .init(
        code: "command_session_not_found",
        message: "The command session is unavailable.",
        retryable: false
      )
    case .commandTimeout:
      dto = .init(
        code: "command_timeout",
        message: "The command exceeded its time limit.",
        retryable: true
      )
    case .commandDenied(let reason):
      dto = .init(
        code: "command_denied",
        message: "The requested command was denied: \(reason)",
        retryable: false
      )
    case .processLaunchFailed:
      dto = .init(
        code: "process_launch_failed",
        message:
          "The command could not be launched. Check the executable path and that it is executable.",
        retryable: true
      )

    case .gitOperationFailed(let summary):
      dto = .init(
        code: "git_operation_failed",
        message: "The git operation failed: \(summary)",
        retryable: true
      )
    case .outputLimitExceeded:
      dto = .init(
        code: "output_limit_exceeded",
        message: "The command output exceeded the bounded limit.",
        retryable: false
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

  private static func projectBusyMessage(_ detail: WorkspaceBusyDetail) -> String {
    switch detail.owner {
    case "codex_task":
      if let taskID = detail.taskID {
        return "The project workspace is busy with a Codex task (\(taskID))."
      }
      return "The project workspace is being acquired by a Codex task."
    case "direct_file":
      return "The project workspace is busy with a direct file operation."
    case "direct_command":
      return "The project workspace is busy with a running command session."
    default:
      return "The project workspace is busy."
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
  let sha256: String
  let byteCount: Int
  let fileRevision: String

  init(page: MCPProjectFileReadPage) {
    relativePath = page.relativePath
    startLine = page.startLine
    endLine = page.endLine
    content = page.content
    redactedLineCount = page.redactedLineCount
    truncated = page.truncated
    nextStartLine = page.nextStartLine
    sha256 = page.sha256
    byteCount = page.byteCount
    fileRevision = page.fileRevision
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
    case sha256
    case byteCount = "byte_count"
    case fileRevision = "file_revision"
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

private struct ServiceProjectChangesOutput: Codable, Sendable {
  let schemaVersion = 1
  let changedFiles: [String]
  let diff: String
  let additions: Int
  let deletions: Int
  let truncated: Bool
  let notGitRepository: Bool

  init(changes: MCPProjectChanges) {
    changedFiles = changes.changedFiles
    diff = changes.diff
    additions = changes.additions
    deletions = changes.deletions
    truncated = changes.truncated
    notGitRepository = changes.notGitRepository
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case changedFiles = "changed_files"
    case diff
    case additions
    case deletions
    case truncated
    case notGitRepository = "not_git_repository"
  }
}

private struct ServiceProjectCommandsOutput: Codable, Sendable {
  let schemaVersion = 1
  let commandMode: String
  let commands: [MCPProjectCommand]

  init(commands: MCPProjectCommands) {
    commandMode = commands.commandMode
    self.commands = commands.commands
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case commandMode = "command_mode"
    case commands
  }
}

private struct ServiceDirectMutationOutput: Codable, Sendable {
  let schemaVersion = 1
  let relativePath: String
  let operation: String
  let oldSHA256: String?
  let newSHA256: String?
  let byteCount: Int
  let boundedDiff: MCPBoundedDiff

  init(receipt: MCPDirectWriteReceipt) {
    relativePath = receipt.relativePath
    operation = receipt.operation
    oldSHA256 = receipt.oldSHA256
    newSHA256 = receipt.newSHA256
    byteCount = receipt.byteCount
    boundedDiff = receipt.boundedDiff
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case relativePath = "relative_path"
    case operation
    case oldSHA256 = "old_sha256"
    case newSHA256 = "new_sha256"
    case byteCount = "byte_count"
    case boundedDiff = "bounded_diff"
  }
}

private struct ServiceDirectPatchOutput: Codable, Sendable {
  let schemaVersion = 1
  let operations: [MCPDirectWriteReceipt]
  let partialCommit: MCPPartialCommit?

  init(receipt: MCPDirectPatchReceipt) {
    operations = receipt.operations
    partialCommit = receipt.partialCommit
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operations
    case partialCommit = "partial_commit"
  }
}

private struct ServiceDirectManagePathOutput: Codable, Sendable {
  let schemaVersion = 1
  let relativePath: String
  let operation: String
  let oldSHA256: String?
  let newSHA256: String?
  let byteCount: Int

  init(receipt: MCPDirectManagePathReceipt) {
    relativePath = receipt.relativePath
    operation = receipt.operation
    oldSHA256 = receipt.oldSHA256
    newSHA256 = receipt.newSHA256
    byteCount = receipt.byteCount
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case relativePath = "relative_path"
    case operation
    case oldSHA256 = "old_sha256"
    case newSHA256 = "new_sha256"
    case byteCount = "byte_count"
  }
}

private struct ServiceDirectExecOutput: Codable, Sendable {
  let schemaVersion = 1
  let sessionID: String
  let status: String
  let exitCode: Int?
  let startedAt: String?
  let output: MCPDirectCommandOutput?

  init(receipt: MCPDirectCommandReceipt) {
    sessionID = receipt.sessionID
    status = receipt.status
    exitCode = receipt.exitCode
    startedAt = receipt.startedAt
    output = receipt.output
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case sessionID = "session_id"
    case status
    case exitCode = "exit_code"
    case startedAt = "started_at"
    case output
  }
}

private struct ServiceDirectCommandOutput: Codable, Sendable {
  let schemaVersion = 1
  let sessionID: String
  let status: String
  let exitCode: Int?
  let timedOut: Bool
  let head: String
  let tail: String
  let byteCount: Int
  let truncated: Bool

  init(output: MCPDirectCommandOutput) {
    sessionID = output.sessionID
    status = output.status
    exitCode = output.exitCode
    timedOut = output.timedOut
    head = output.head
    tail = output.tail
    byteCount = output.byteCount
    truncated = output.truncated
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case sessionID = "session_id"
    case status
    case exitCode = "exit_code"
    case timedOut = "timed_out"
    case head
    case tail
    case byteCount = "byte_count"
    case truncated
  }
}

private struct ServiceDirectWriteStdinOutput: Codable, Sendable {
  let schemaVersion = 1

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
  }
}

private struct ServiceDirectGitCommitOutput: Codable, Sendable {
  let schemaVersion = 1
  let commitHash: String?
  let changedFiles: [String]
  let summary: String
  let exitCode: Int

  init(receipt: MCPDirectGitCommitReceipt) {
    commitHash = receipt.commitHash
    changedFiles = receipt.changedFiles
    summary = receipt.summary
    exitCode = receipt.exitCode
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case commitHash = "commit_hash"
    case changedFiles = "changed_files"
    case summary
    case exitCode = "exit_code"
  }
}
