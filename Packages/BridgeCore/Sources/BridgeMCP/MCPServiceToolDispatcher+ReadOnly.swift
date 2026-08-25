import BridgeFiles
import BridgeSecurity
import Foundation
import MCP

extension MCPServiceToolDispatcher {
  func callReadOnly(
    _ name: MCPServiceToolName,
    arguments: [String: Value]?
  ) async throws -> CallTool.Result {
    switch name {
    case .bridgeStatus:
      return try await callBridgeStatus(arguments)
    case .listProjects:
      return try await callListProjects(arguments)
    case .getProject:
      return try await callGetProject(arguments)
    case .searchProjectFiles:
      return try await callSearchProjectFiles(arguments)
    case .readProjectFile:
      return try await callReadProjectFile(arguments)
    case .listThreads:
      return try await callListThreads(arguments)
    case .readThread:
      return try await callReadThread(arguments)
    case .listModels:
      return try await callListModels(arguments)
    case .listSkills:
      return try await callListSkills(arguments)
    case .readSkill:
      return try await callReadSkill(arguments)
    case .getProjectChanges:
      return try await callGetProjectChanges(arguments)
    case .listProjectCommands:
      return try await callListProjectCommands(arguments)
    default:
      throw MCPError.invalidParams("Unknown tool name.")
    }
  }

  private func callBridgeStatus(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    let values = try StrictToolArguments(arguments, allowed: [])
    _ = values
    let deadline = clock.now.advanced(by: deadlines.read)
    let snapshot = try await withToolDeadline(until: deadline) {
      try await service.serviceStatus(deadline: deadline)
    }
    return try resultEncoder.encode(BridgeStatusOutput(snapshot: snapshot))

  }

  private func callListProjects(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    let values = try StrictToolArguments(arguments, allowed: ["cursor", "limit"])
    let cursor = try values.optionalString("cursor", maximumUTF8Bytes: 2_048)
    let limit = try values.limit()
    let deadline = clock.now.advanced(by: deadlines.read)
    let page = try await withToolDeadline(until: deadline) {
      try await service.serviceProjects(cursor: cursor, limit: limit, deadline: deadline)
    }
    return try resultEncoder.encode(ListProjectsOutput(page: page))

  }

  private func callGetProject(_ arguments: [String: Value]?) async throws -> CallTool.Result {
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

  }

  private func callSearchProjectFiles(_ arguments: [String: Value]?) async throws -> CallTool.Result
  {
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

  }

  private func callReadProjectFile(_ arguments: [String: Value]?) async throws -> CallTool.Result {
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
    let lineCount = min(requestedCount, FileLineRange.maximumLineCount)
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

  }

  private func callListThreads(_ arguments: [String: Value]?) async throws -> CallTool.Result {
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

  }

  private func callReadThread(_ arguments: [String: Value]?) async throws -> CallTool.Result {
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

  }

  private func callListModels(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    _ = try StrictToolArguments(arguments, allowed: [])
    let deadline = clock.now.advanced(by: deadlines.read)
    let models = try await withToolDeadline(until: deadline) {
      try await service.serviceModels(deadline: deadline)
    }
    return try resultEncoder.encode(ListModelsOutput(list: models))

  }

  private func callListSkills(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    let values = try StrictToolArguments(arguments, allowed: ["project_id"])
    let projectID = try values.optionalIdentifier("project_id", maximumUTF8Bytes: 128)
    let deadline = clock.now.advanced(by: deadlines.read)
    let skills = try await withToolDeadline(until: deadline) {
      try await service.serviceListSkills(projectID: projectID, deadline: deadline)
    }
    return try resultEncoder.encode(ListSkillsOutput(list: skills))

  }

  private func callReadSkill(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["skill_name", "project_id", "subpath"],
      required: ["skill_name"]
    )
    let skillName = try values.requiredIdentifier("skill_name", maximumUTF8Bytes: 128)
    let projectID = try values.optionalIdentifier("project_id", maximumUTF8Bytes: 128)
    let subpath = try values.optionalString("subpath", maximumUTF8Bytes: 1_024) ?? "SKILL.md"
    let deadline = clock.now.advanced(by: deadlines.read)
    let document = try await withToolDeadline(until: deadline) {
      try await service.serviceReadSkill(
        skillName: skillName, projectID: projectID, subpath: subpath, deadline: deadline
      )
    }
    return try resultEncoder.encode(ReadSkillOutput(document: document))

  }

  private func callGetProjectChanges(_ arguments: [String: Value]?) async throws -> CallTool.Result
  {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["project_id"],
      required: ["project_id"]
    )
    let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
    let deadline = clock.now.advanced(by: deadlines.projectChanges)
    let changes = try await withToolDeadline(until: deadline) {
      try await service.serviceProjectChanges(projectID: projectID, deadline: deadline)
    }
    return try resultEncoder.encode(ServiceProjectChangesOutput(changes: changes))

  }

  private func callListProjectCommands(_ arguments: [String: Value]?) async throws
    -> CallTool.Result
  {
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

  }

}
