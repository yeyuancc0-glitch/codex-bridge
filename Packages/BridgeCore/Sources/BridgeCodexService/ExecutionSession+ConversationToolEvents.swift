import BridgeCodexRPC

extension ExecutionSession {
  func conversationToolCall(
    from evidence: CodexApprovalItemEvidence
  ) throws -> ExecutionToolCall {
    switch evidence {
    case .commandExecution(let command):
      return try ExecutionToolCall(
        itemID: command.item.itemID,
        tool: Self.commandToolName(command.displayActions),
        arguments: Self.commandDetails(command, projectRoot: projectRoot),
        status: .inProgress
      )
    case .fileChange(let file):
      return try ExecutionToolCall(
        itemID: file.item.itemID,
        tool: "file_change",
        arguments: try Self.fileChangeDetails(file.changes, projectRoot: projectRoot),
        status: .inProgress
      )
    }
  }

  func conversationToolCall(
    from evidence: CodexSemanticExecutionEvidence
  ) throws -> ExecutionToolCall? {
    switch evidence {
    case .planChanged:
      return nil
    case .commandCompleted(let completed):
      guard case .commandExecution(let started)? = knownItems[completed.item] else {
        throw ExecutionServiceError.protocolViolation("command conversation item")
      }
      return try ExecutionToolCall(
        itemID: completed.item.itemID,
        tool: Self.commandToolName(started.displayActions),
        arguments: Self.commandDetails(started, projectRoot: projectRoot),
        status: Self.toolStatus(completed.status)
      )
    case .fileChangeCompleted(let completed):
      guard case .fileChange(let started)? = knownItems[completed.item] else {
        throw ExecutionServiceError.protocolViolation("file conversation item")
      }
      return try ExecutionToolCall(
        itemID: completed.item.itemID,
        tool: "file_change",
        arguments: try Self.fileChangeDetails(started.changes, projectRoot: projectRoot),
        status: Self.toolStatus(completed.status)
      )
    }
  }

  static func binding(of evidence: CodexSemanticExecutionEvidence) -> CodexApprovalItemKey {
    switch evidence {
    case .planChanged(let plan):
      return CodexApprovalItemKey(
        threadID: plan.threadID,
        turnID: plan.turnID,
        itemID: "plan"
      )
    case .commandCompleted(let command):
      return command.item
    case .fileChangeCompleted(let file):
      return file.item
    }
  }

  private static func commandToolName(_ actions: [CodexCommandAction]) -> String {
    if actions.contains(where: { if case .search = $0 { true } else { false } }) {
      return "search_files"
    }
    if actions.contains(where: { if case .read = $0 { true } else { false } }) {
      return "read_files"
    }
    if actions.contains(where: { if case .listFiles = $0 { true } else { false } }) {
      return "list_files"
    }
    return "command_execution"
  }

  private static func commandDetails(
    _ command: CodexCommandExecutionEvidence,
    projectRoot: String
  ) -> String {
    var lines: [String] = []
    for action in command.displayActions {
      switch action {
      case .read(_, let name, let path):
        lines.append("读取 \(safeDisplayPath(path, name: name, projectRoot: projectRoot))")
      case .listFiles(_, let path):
        lines.append("列出 \(safeDisplayPath(path, name: nil, projectRoot: projectRoot))")
      case .search(_, let path, let query):
        let location = safeDisplayPath(path, name: nil, projectRoot: projectRoot)
        let term = ExecutionValidation.redacted(query, maximumBytes: 1_024) ?? "内容"
        lines.append("搜索 \(location)：\(term)")
      case .unknown:
        continue
      }
    }
    let displayCommand =
      ExecutionValidation.redacted(command.displayCommand, maximumBytes: 8 * 1_024)
      ?? "命令内容不可用"
    lines.append("命令：\(displayCommand)")
    return lines.joined(separator: "\n")
  }

  private static func fileChangeDetails(
    _ changes: [CodexFileUpdateEvidence],
    projectRoot: String
  ) throws -> String {
    try changes.map { change in
      let path = try ExecutionValidation.relativePath(change.path, root: projectRoot)
      switch change.kind {
      case .add: return "新增 \(path)"
      case .delete: return "删除 \(path)"
      case .update(let movePath):
        guard let movePath else { return "编辑 \(path)" }
        let destination = try ExecutionValidation.relativePath(movePath, root: projectRoot)
        return "移动 \(path) → \(destination)"
      }
    }.joined(separator: "\n")
  }

  private static func safeDisplayPath(
    _ path: String?,
    name: String?,
    projectRoot: String
  ) -> String {
    if let path,
      let relative = try? ExecutionValidation.relativePath(path, root: projectRoot)
    {
      return relative
    }
    return ExecutionValidation.redacted(name, maximumBytes: 1_024) ?? "项目"
  }

  private static func toolStatus(
    _ status: CodexCommandExecutionStatus
  ) -> ExecutionToolCallStatus {
    switch status {
    case .inProgress: .inProgress
    case .completed: .completed
    case .failed: .failed
    case .declined: .declined
    }
  }

  private static func toolStatus(
    _ status: CodexFileChangeStatus
  ) -> ExecutionToolCallStatus {
    switch status {
    case .inProgress: .inProgress
    case .completed: .completed
    case .failed: .failed
    case .declined: .declined
    }
  }
}
