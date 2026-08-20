import BridgeFiles
import BridgeSecurity
import Foundation
import MCP

extension MCPServiceToolDispatcher {
  func callDirect(
    _ name: MCPServiceToolName,
    arguments: [String: Value]?
  ) async throws -> CallTool.Result {
    switch name {
    case .directWriteProjectFile:
      return try await callDirectWriteProjectFile(arguments)
    case .directEditProjectFile:
      return try await callDirectEditProjectFile(arguments)
    case .directApplyProjectPatch:
      return try await callDirectApplyProjectPatch(arguments)
    case .directManageProjectPath:
      return try await callDirectManageProjectPath(arguments)
    case .directExecCommand:
      return try await callDirectExecCommand(arguments)
    case .directGitCommit:
      return try await callDirectGitCommit(arguments)
    case .directReadCommand:
      return try await callDirectReadCommand(arguments)
    case .directWriteStdin:
      return try await callDirectWriteStdin(arguments)
    case .directInterruptCommand:
      return try await callDirectInterruptCommand(arguments)
    default:
      throw MCPError.invalidParams("Unknown tool name.")
    }
  }

  private func callDirectWriteProjectFile(_ arguments: [String: Value]?) async throws
    -> CallTool.Result
  {
    let request = try parseDirectWrite(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectWriteFile(request, deadline: deadline)
    }
    return try resultEncoder.encode(ServiceDirectMutationOutput(receipt: receipt))

  }

  private func callDirectEditProjectFile(_ arguments: [String: Value]?) async throws
    -> CallTool.Result
  {
    let request = try parseDirectEdit(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectEditFile(request, deadline: deadline)
    }
    return try resultEncoder.encode(ServiceDirectMutationOutput(receipt: receipt))

  }

  private func callDirectApplyProjectPatch(_ arguments: [String: Value]?) async throws
    -> CallTool.Result
  {
    let request = try parseDirectPatch(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectApplyPatch(request, deadline: deadline)
    }
    return try resultEncoder.encode(ServiceDirectPatchOutput(receipt: receipt))

  }

  private func callDirectManageProjectPath(_ arguments: [String: Value]?) async throws
    -> CallTool.Result
  {
    let request = try parseDirectManagePath(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectManagePath(request, deadline: deadline)
    }
    return try resultEncoder.encode(ServiceDirectManagePathOutput(receipt: receipt))

  }

  private func callDirectExecCommand(_ arguments: [String: Value]?) async throws -> CallTool.Result
  {
    let request = try parseDirectExec(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectExecCommand(request, deadline: deadline)
    }
    return try resultEncoder.encode(ServiceDirectExecOutput(receipt: receipt))

  }

  private func callDirectGitCommit(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    let request = try parseDirectGitCommit(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectGitCommit(request, deadline: deadline)
    }
    return try resultEncoder.encode(ServiceDirectGitCommitOutput(receipt: receipt))

  }

  private func callDirectReadCommand(_ arguments: [String: Value]?) async throws -> CallTool.Result
  {
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

  }

  private func callDirectWriteStdin(_ arguments: [String: Value]?) async throws -> CallTool.Result {
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

  }

  private func callDirectInterruptCommand(_ arguments: [String: Value]?) async throws
    -> CallTool.Result
  {
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
