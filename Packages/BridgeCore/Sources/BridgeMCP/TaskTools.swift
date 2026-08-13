import BridgeDomain
import BridgeSecurity
import Foundation
import MCP

public struct MCPTaskToolDeadlines: Sendable {
  public static let production = MCPTaskToolDeadlines(
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

struct TaskTools: Sendable {
  private let operations: (any BridgeMCPTaskOperations)?
  private let deadlines: MCPTaskToolDeadlines
  private let clock = ContinuousClock()

  init(
    operations: (any BridgeMCPTaskOperations)?,
    deadlines: MCPTaskToolDeadlines = .production
  ) {
    self.operations = operations
    self.deadlines = deadlines
  }

  func getTask(arguments: [String: Value]?) async throws -> GetTaskOutput {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["task_id"],
      required: ["task_id"]
    )
    let taskID = try values.requiredIdentifier("task_id", maximumUTF8Bytes: 128)
    let operations = try availableOperations()
    let deadline = clock.now.advanced(by: deadlines.read)
    let snapshot = try await withToolDeadline(until: deadline) {
      try await operations.getTask(taskID: taskID, deadline: deadline)
    }
    try validate(snapshot)
    return GetTaskOutput(task: snapshot)
  }

  func getTaskEvents(arguments: [String: Value]?) async throws -> GetTaskEventsOutput {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["task_id", "after_seq", "limit"],
      required: ["task_id"]
    )
    let taskID = try values.requiredIdentifier("task_id", maximumUTF8Bytes: 128)
    let afterSequence = try values.optionalNonnegativeInteger("after_seq")
    let limit = try values.limit()
    let operations = try availableOperations()
    let deadline = clock.now.advanced(by: deadlines.read)
    let page = try await withToolDeadline(until: deadline) {
      try await operations.getTaskEvents(
        taskID: taskID,
        afterSequence: afterSequence,
        limit: limit,
        deadline: deadline
      )
    }
    try validate(page, requestedTaskID: taskID, afterSequence: afterSequence, limit: limit)
    return GetTaskEventsOutput(page: page)
  }

  func getTaskDiff(arguments: [String: Value]?) async throws -> GetTaskDiffOutput {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["task_id", "cursor", "limit", "include_patch"],
      required: ["task_id"]
    )
    let taskID = try values.requiredIdentifier("task_id", maximumUTF8Bytes: 128)
    let cursor = try values.optionalString("cursor", maximumUTF8Bytes: 2_048)
    let limit = try values.limit()
    let includePatch = try values.optionalBoolean("include_patch") ?? false
    let operations = try availableOperations()
    let deadline = clock.now.advanced(by: deadlines.read)
    let page = try await withToolDeadline(until: deadline) {
      try await operations.getTaskDiff(
        taskID: taskID,
        cursor: cursor,
        limit: limit,
        includePatch: includePatch,
        deadline: deadline
      )
    }
    try validate(page, requestedTaskID: taskID, limit: limit, includePatch: includePatch)
    return GetTaskDiffOutput(page: page)
  }

  func getFinalReport(arguments: [String: Value]?) async throws -> GetFinalReportOutput {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["task_id"],
      required: ["task_id"]
    )
    let taskID = try values.requiredIdentifier("task_id", maximumUTF8Bytes: 128)
    let operations = try availableOperations()
    let deadline = clock.now.advanced(by: deadlines.read)
    let report = try await withToolDeadline(until: deadline) {
      try await operations.getFinalReport(taskID: taskID, deadline: deadline)
    }
    try validate(report, requestedTaskID: taskID)
    return GetFinalReportOutput(report: report)
  }

  func submitTask(arguments: [String: Value]?) async throws -> SubmitTaskOutput {
    let submission = try TaskSubmissionParser(arguments: arguments).parse()
    let operations = try availableOperations()
    let deadline = clock.now.advanced(by: deadlines.submit)
    let receipt = try await withToolDeadline(until: deadline) {
      try await operations.submitTask(submission, deadline: deadline)
    }
    try validate(receipt)
    return SubmitTaskOutput(receipt: receipt)
  }

  func steerTask(arguments: [String: Value]?) async throws -> MutateTaskOutput {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["task_id", "expected_turn_id", "input"],
      required: ["task_id", "expected_turn_id", "input"]
    )
    let taskID = try values.requiredIdentifier("task_id", maximumUTF8Bytes: 128)
    let turnID = try values.requiredIdentifier("expected_turn_id", maximumUTF8Bytes: 256)
    let input = try values.requiredText("input", maximumUTF8Bytes: 32 * 1_024)
    guard isSafeTaskText(input) else { throw MCPError.invalidParams("Task input is not safe.") }
    let operations = try availableOperations()
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await operations.steerTask(
        taskID: taskID,
        expectedTurnID: turnID,
        input: input,
        deadline: deadline
      )
    }
    try validate(receipt, taskID: taskID)
    return MutateTaskOutput(receipt: receipt)
  }

  func interruptTask(arguments: [String: Value]?) async throws -> MutateTaskOutput {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["task_id"],
      required: ["task_id"]
    )
    let taskID = try values.requiredIdentifier("task_id", maximumUTF8Bytes: 128)
    let operations = try availableOperations()
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await operations.interruptTask(taskID: taskID, deadline: deadline)
    }
    try validate(receipt, taskID: taskID)
    return MutateTaskOutput(receipt: receipt)
  }

  private func availableOperations() throws -> any BridgeMCPTaskOperations {
    guard let operations else { throw BridgeMCPQueryError.unavailable }
    return operations
  }

  private func validate(_ snapshot: MCPTaskSnapshot) throws {
    guard
      !snapshot.taskID.isEmpty,
      !snapshot.phase.isEmpty,
      !snapshot.activity.isEmpty,
      !snapshot.supervisorState.isEmpty,
      snapshot.changedFileCount >= 0,
      snapshot.currentPlan.allSatisfy(isSafeTaskText),
      snapshot.currentStep.map(isSafeTaskText) ?? true,
      snapshot.verificationSummary.map(isSafeTaskText) ?? true
    else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
  }

  private func validate(
    _ page: MCPTaskEventPage,
    requestedTaskID: String,
    afterSequence: Int64?,
    limit: Int
  ) throws {
    guard page.taskID == requestedTaskID, page.events.count <= limit else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
    var prior = afterSequence ?? -1
    for event in page.events {
      guard
        event.sequence > prior,
        !event.kind.isEmpty,
        event.summary.map(isSafeTaskText) ?? true
      else {
        throw MCPToolAdapterError.invalidQueryOutput
      }
      prior = event.sequence
    }
    if let next = page.nextAfterSequence, next < prior {
      throw MCPToolAdapterError.invalidQueryOutput
    }
  }

  private func validate(
    _ page: MCPTaskDiffPage,
    requestedTaskID: String,
    limit: Int,
    includePatch: Bool
  ) throws {
    guard page.taskID == requestedTaskID, page.files.count <= limit else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
    guard
      includePatch || page.patch == nil,
      isSafeTaskText(page.diffStat),
      page.patch.map(isSafeTaskText) ?? true
    else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
    for file in page.files {
      guard
        isSafeRelativePath(file.relativePath),
        !file.status.isEmpty,
        file.additions.map({ $0 >= 0 }) ?? true,
        file.deletions.map({ $0 >= 0 }) ?? true
      else {
        throw MCPToolAdapterError.invalidQueryOutput
      }
    }
  }

  private func validate(_ receipt: MCPTaskSubmissionReceipt) throws {
    guard !receipt.taskID.isEmpty, !receipt.phase.isEmpty else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
  }

  private func validate(_ report: MCPFinalReport, requestedTaskID: String) throws {
    let text =
      [
        report.projectName, report.summary, report.diffStat, report.startedAt, report.completedAt,
      ] + report.commands + report.verification + report.warnings + report.unresolvedItems
    guard
      report.taskID == requestedTaskID,
      text.allSatisfy(isSafeTaskText),
      report.changedFiles.allSatisfy(isSafeRelativePath)
    else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
  }

  private func validate(_ receipt: MCPTaskMutationReceipt, taskID: String) throws {
    guard
      receipt.taskID == taskID,
      !receipt.phase.isEmpty,
      !receipt.operationID.isEmpty
    else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
  }
}

private struct TaskSubmissionParser {
  let arguments: [String: Value]?

  func parse() throws -> TaskSubmission {
    guard
      try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 128 * 1_024
    else {
      throw MCPError.invalidParams("The task contract is too large.")
    }
    let root = try StrictToolArguments(
      arguments,
      allowed: [
        "idempotency_key", "project_id", "thread", "execution", "supervisor", "contract",
      ],
      required: [
        "idempotency_key", "project_id", "thread", "execution", "supervisor", "contract",
      ]
    )
    let idempotencyKey = try root.requiredIdentifier(
      "idempotency_key", maximumUTF8Bytes: 512)
    let projectID = try root.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
    return TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: idempotencyKey),
      projectID: ProjectID(rawValue: projectID),
      thread: try parseThread(root.requiredObject("thread")),
      execution: try parseExecution(root.requiredObject("execution")),
      supervisor: try parseSupervisor(root.requiredObject("supervisor")),
      contract: try parseContract(root.requiredObject("contract"))
    )
  }

  private func parseThread(_ object: [String: Value]) throws -> ThreadTarget {
    let values = try StrictToolArguments(
      object,
      allowed: ["mode", "thread_id"],
      required: ["mode"]
    )
    let mode = try values.requiredIdentifier("mode", maximumUTF8Bytes: 16)
    switch mode {
    case "new":
      guard try values.optionalString("thread_id", maximumUTF8Bytes: 256) == nil else {
        throw MCPError.invalidParams("A new thread cannot include 'thread_id'.")
      }
      return .new
    case "existing":
      let threadID = try values.requiredIdentifier("thread_id", maximumUTF8Bytes: 256)
      return .existing(ThreadID(rawValue: threadID))
    default:
      throw MCPError.invalidParams("Argument 'thread.mode' is invalid.")
    }
  }

  private func parseExecution(_ object: [String: Value]) throws -> ExecutionOptions {
    let values = try StrictToolArguments(
      object,
      allowed: ["model", "effort", "permission_mode", "network_access"],
      required: ["model", "effort", "permission_mode", "network_access"]
    )
    return ExecutionOptions(
      model: try values.requiredIdentifier("model", maximumUTF8Bytes: 128),
      effort: try values.requiredIdentifier("effort", maximumUTF8Bytes: 64),
      permissionMode: try permissionMode(values),
      networkAccess: try values.requiredBoolean("network_access")
    )
  }

  private func permissionMode(_ values: StrictToolArguments) throws -> String {
    let mode = try values.requiredIdentifier("permission_mode", maximumUTF8Bytes: 64)
    switch mode {
    case "read-only", "readOnly":
      return "read-only"
    case "workspace-write", "workspaceWrite":
      return "workspace-write"
    default:
      throw MCPError.invalidParams("Argument 'execution.permission_mode' is invalid.")
    }
  }

  private func parseSupervisor(_ object: [String: Value]) throws -> SupervisorOptions {
    let values = try StrictToolArguments(
      object,
      allowed: ["enabled", "model", "effort"],
      required: ["enabled", "model", "effort"]
    )
    return SupervisorOptions(
      enabled: try values.requiredBoolean("enabled"),
      model: try values.requiredIdentifier("model", maximumUTF8Bytes: 128),
      effort: try values.requiredIdentifier("effort", maximumUTF8Bytes: 64)
    )
  }

  private func parseContract(_ object: [String: Value]) throws -> TaskContract {
    let fields: Set<String> = [
      "goal", "background", "requirements", "acceptance_criteria", "non_goals", "constraints",
      "allowed_paths", "forbidden_paths", "verification",
    ]
    let values = try StrictToolArguments(object, allowed: fields, required: fields)
    let acceptance = try values.stringArray(
      "acceptance_criteria", maximumCount: 100, maximumElementUTF8Bytes: 4_096)
    let hasAcceptanceCriterion = acceptance.contains {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard hasAcceptanceCriterion
    else {
      throw MCPError.invalidParams("Argument 'contract.acceptance_criteria' cannot be empty.")
    }
    let allowedPaths = try values.stringArray(
      "allowed_paths", maximumCount: 200, maximumElementUTF8Bytes: 1_024)
    let forbiddenPaths = try values.stringArray(
      "forbidden_paths", maximumCount: 200, maximumElementUTF8Bytes: 1_024)
    guard (allowedPaths + forbiddenPaths).allSatisfy(isSafeRelativePath) else {
      throw MCPError.invalidParams("Contract paths must be safe relative paths.")
    }
    let goal = try values.requiredText("goal", maximumUTF8Bytes: 32 * 1_024)
    let background = try values.text("background", maximumUTF8Bytes: 64 * 1_024)
    let requirements = try values.stringArray(
      "requirements", maximumCount: 100, maximumElementUTF8Bytes: 4_096)
    let nonGoals = try values.stringArray(
      "non_goals", maximumCount: 100, maximumElementUTF8Bytes: 4_096)
    let constraints = try values.stringArray(
      "constraints", maximumCount: 100, maximumElementUTF8Bytes: 4_096)
    let verification = try values.stringArray(
      "verification", maximumCount: 100, maximumElementUTF8Bytes: 4_096)
    let allText =
      [goal, background] + requirements + acceptance + nonGoals + constraints + verification
    guard allText.allSatisfy(isSafeTaskText) else {
      throw MCPError.invalidParams("Task contract text contains restricted local data.")
    }
    return TaskContract(
      goal: goal,
      background: background,
      requirements: requirements,
      acceptanceCriteria: acceptance,
      nonGoals: nonGoals,
      constraints: constraints,
      allowedPaths: allowedPaths,
      forbiddenPaths: forbiddenPaths,
      verification: verification
    )
  }
}

private func isSafeRelativePath(_ path: String) -> Bool {
  guard
    !path.isEmpty,
    path.utf8.count <= 1_024,
    !path.hasPrefix("/"),
    !path.hasPrefix("~"),
    !path.contains("\\"),
    path.rangeOfCharacter(from: .controlCharacters) == nil
  else { return false }
  let components = path.split(separator: "/", omittingEmptySubsequences: false)
  return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}

private func isSafeTaskText(_ value: String) -> Bool {
  OutboundContentSecurity.isSafe(value)
}

struct GetTaskOutput: Codable, Sendable {
  let schemaVersion = 1
  let task: MCPTaskSnapshot

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case task
  }
}

struct GetTaskEventsOutput: Codable, Sendable {
  let schemaVersion = 1
  let taskID: String
  let events: [MCPTaskEvent]
  let nextAfterSequence: Int64?

  init(page: MCPTaskEventPage) {
    taskID = page.taskID
    events = page.events
    nextAfterSequence = page.nextAfterSequence
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case taskID = "task_id"
    case events
    case nextAfterSequence = "next_after_seq"
  }
}

struct GetTaskDiffOutput: Codable, Sendable {
  let schemaVersion = 1
  let taskID: String
  let files: [MCPTaskDiffFile]
  let diffStat: String
  let patch: String?
  let nextCursor: String?
  let baselineWasDirty: Bool

  init(page: MCPTaskDiffPage) {
    taskID = page.taskID
    files = page.files
    diffStat = page.diffStat
    patch = page.patch
    nextCursor = page.nextCursor
    baselineWasDirty = page.baselineWasDirty
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case taskID = "task_id"
    case files
    case diffStat = "diff_stat"
    case patch
    case nextCursor = "next_cursor"
    case baselineWasDirty = "baseline_was_dirty"
  }
}

struct GetFinalReportOutput: Codable, Sendable {
  let schemaVersion = 1
  let report: MCPFinalReport

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case report
  }
}

struct SubmitTaskOutput: Codable, Sendable {
  let schemaVersion = 1
  let taskID: String
  let phase: String
  let reusedExistingTask: Bool
  let localApprovalRequired: Bool

  init(receipt: MCPTaskSubmissionReceipt) {
    taskID = receipt.taskID
    phase = receipt.phase
    reusedExistingTask = receipt.reusedExistingTask
    localApprovalRequired = receipt.localApprovalRequired
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case taskID = "task_id"
    case phase
    case reusedExistingTask = "reused_existing_task"
    case localApprovalRequired = "local_approval_required"
  }
}

struct MutateTaskOutput: Codable, Sendable {
  let schemaVersion = 1
  let taskID: String
  let phase: String
  let accepted: Bool
  let operationID: String

  init(receipt: MCPTaskMutationReceipt) {
    taskID = receipt.taskID
    phase = receipt.phase
    accepted = receipt.accepted
    operationID = receipt.operationID
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case taskID = "task_id"
    case phase
    case accepted
    case operationID = "operation_id"
  }
}
