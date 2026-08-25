import BridgeFiles
import BridgeSecurity
import Foundation
import MCP

extension MCPServiceToolDispatcher {
  func callTask(
    _ name: MCPServiceToolName,
    arguments: [String: Value]?,
    sessionID: String
  ) async throws -> CallTool.Result {
    switch name {
    case .runSkillAction:
      return try await callRunSkillAction(arguments)
    case .getTask:
      return try await callGetTask(arguments)
    case .submitTask:
      return try await callSubmitTask(arguments, sessionID: sessionID)
    case .steerTask:
      return try await callSteerTask(arguments)
    case .interruptTask:
      return try await callInterruptTask(arguments)
    default:
      throw MCPError.invalidParams("Unknown tool name.")
    }
  }

  private func callRunSkillAction(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    let request = try parseRunSkillAction(arguments)
    let executionDuration = max(
      deadlines.mutation,
      .milliseconds(request.yieldTimeMS) + .seconds(5)
    )
    let deadline = clock.now.advanced(by: executionDuration)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceRunSkillAction(request, deadline: deadline)
    }
    return try resultEncoder.encode(ServiceDirectExecOutput(receipt: receipt))
  }

  private func callGetTask(_ arguments: [String: Value]?) async throws -> CallTool.Result {
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

  }

  private func callSubmitTask(
    _ arguments: [String: Value]?,
    sessionID: String
  ) async throws -> CallTool.Result {
    let submission = try parseSubmission(arguments)
    let deadline = clock.now.advanced(by: deadlines.submit)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceSubmitTask(
        submission,
        invocationContext: MCPInvocationContext(clientID: clientID, sessionID: sessionID),
        deadline: deadline
      )
    }
    return try resultEncoder.encode(ServiceSubmitTaskOutput(receipt: receipt))

  }

  private func callSteerTask(_ arguments: [String: Value]?) async throws -> CallTool.Result {
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

  }

  private func callInterruptTask(_ arguments: [String: Value]?) async throws -> CallTool.Result {
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
