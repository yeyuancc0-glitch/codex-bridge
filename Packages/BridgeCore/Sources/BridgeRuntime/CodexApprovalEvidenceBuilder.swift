import BridgeCodexRPC
import BridgeDomain
import BridgeSecurity
import CryptoKit
import Foundation

enum CodexApprovalEvidenceBuilder {
  static func build(
    approvalID: ApprovalID,
    request: CodexApprovalRequest,
    requestParameters: JSONValue,
    itemEvidence: CodexApprovalItemEvidence?,
    itemSourceDigest: String,
    root: RegisteredRoot
  ) throws -> CodexApprovalEvidence {
    guard let itemEvidence,
      request.correlation.item == itemEvidence.item,
      request.correlation.startedAtMilliseconds == startedAt(itemEvidence)
    else { throw IsolatedCodexTaskRuntimeError.protocolViolation }

    let digest = try evidenceDigest(
      requestParameters: requestParameters,
      itemSourceDigest: itemSourceDigest
    )
    switch (request, itemEvidence) {
    case (.command(let command), .commandExecution(let execution)):
      return try commandEvidence(
        approvalID: approvalID,
        request: command,
        execution: execution,
        digest: digest,
        root: root
      )
    case (.fileChange(let file), .fileChange(let changes)):
      return try fileEvidence(
        approvalID: approvalID,
        request: file,
        changes: changes,
        digest: digest,
        root: root
      )
    case (.permissions(let permissions), .commandExecution(let execution)):
      return try permissionsEvidence(
        approvalID: approvalID,
        request: permissions,
        execution: execution,
        digest: digest,
        root: root
      )
    default:
      throw IsolatedCodexTaskRuntimeError.protocolViolation
    }
  }

  private static func commandEvidence(
    approvalID: ApprovalID,
    request: CodexCommandApprovalRequest,
    execution: CodexCommandExecutionEvidence,
    digest: String,
    root: RegisteredRoot
  ) throws -> CodexApprovalEvidence {
    try validateCommandCorrelation(request, execution: execution)
    let actions = execution.displayActions
    let summaries = commandSummaries(request, actions: actions, projectRoot: root.canonicalPath)
    let paths = actions.compactMap(actionPath).prefix(8).map {
      safePath($0, projectRoot: root.canonicalPath)
    }
    return try CodexApprovalEvidence(
      approvalID: approvalID,
      kind: .command,
      authority: .correlatedDisplayOnly,
      threadID: ThreadID(rawValue: request.correlation.item.threadID),
      turnID: TurnID(rawValue: request.correlation.item.turnID),
      itemID: request.correlation.item.itemID,
      callbackID: request.correlation.callbackID,
      startedAtMilliseconds: request.correlation.startedAtMilliseconds,
      operationTitle: "Codex 命令审批（展示信息）",
      displayCommand: safeText(
        request.displayCommand ?? execution.displayCommand,
        maximumBytes: 8 * 1_024
      ),
      displayArguments: Array(summaries.prefix(8)),
      changedPaths: Array(paths),
      omittedOperationCount: max(0, summaries.count - 8),
      workingDirectory: safePath(
        request.displayWorkingDirectory ?? execution.workingDirectory,
        projectRoot: root.canonicalPath
      ),
      reason: safeText(request.reason, maximumBytes: 2 * 1_024),
      evidenceDigest: digest
    )
  }

  private static func fileEvidence(
    approvalID: ApprovalID,
    request: CodexFileChangeApprovalRequest,
    changes: CodexFileChangeEvidence,
    digest: String,
    root: RegisteredRoot
  ) throws -> CodexApprovalEvidence {
    guard changes.status == .inProgress,
      let grantRoot = request.grantRoot,
      normalizedAbsolutePath(grantRoot) == root.canonicalPath
    else { throw IsolatedCodexTaskRuntimeError.protocolViolation }
    let manifest = try fileManifest(changes, root: root)
    let rawPaths = manifest.entries.flatMap { entry in
      [entry.path] + (entry.movePath.map { [$0] } ?? [])
    }
    return try CodexApprovalEvidence(
      approvalID: approvalID,
      kind: .fileChange,
      authority: .correlatedFileChanges,
      threadID: ThreadID(rawValue: request.correlation.item.threadID),
      turnID: TurnID(rawValue: request.correlation.item.turnID),
      itemID: request.correlation.item.itemID,
      callbackID: request.correlation.callbackID,
      startedAtMilliseconds: request.correlation.startedAtMilliseconds,
      operationTitle: "Codex 文件变更审批",
      changedPaths: Array(rawPaths.prefix(8)),
      omittedOperationCount: max(0, rawPaths.count - 8),
      workingDirectory: ".",
      reason: safeText(request.reason, maximumBytes: 2 * 1_024),
      evidenceDigest: digest,
      fileChangeManifest: manifest
    )
  }

  private static func fileManifest(
    _ evidence: CodexFileChangeEvidence,
    root: RegisteredRoot
  ) throws -> CodexApprovalFileChangeManifest {
    guard !evidence.changes.isEmpty,
      evidence.changes.count <= CodexApprovalFileChangeManifest.maximumEntries
    else { throw IsolatedCodexTaskRuntimeError.protocolViolation }
    var totalBytes = 0
    let entries = try evidence.changes.map { change in
      let byteCount = change.diff.utf8.count
      let (nextTotal, overflow) = totalBytes.addingReportingOverflow(byteCount)
      guard !overflow, nextTotal <= CodexApprovalFileChangeManifest.maximumTotalDiffBytes else {
        throw IsolatedCodexTaskRuntimeError.protocolViolation
      }
      totalBytes = nextTotal
      let kind: CodexApprovalFileChangeKind
      let movePath: String?
      switch change.kind {
      case .add:
        kind = .add
        movePath = nil
      case .delete:
        kind = .delete
        movePath = nil
      case .update(let rawMovePath):
        kind = .update
        movePath = try rawMovePath.map { try relativePath($0, root: root) }
      }
      return try CodexApprovalFileChangeManifestEntry(
        path: relativePath(change.path, root: root),
        kind: kind,
        movePath: movePath,
        diffByteCount: byteCount,
        diffSHA256: SHA256.hash(data: Data(change.diff.utf8)).map {
          String(format: "%02x", $0)
        }.joined()
      )
    }
    return try CodexApprovalFileChangeManifest(
      entries: entries,
      totalDiffBytes: totalBytes,
      rootDevice: root.identity.device,
      rootInode: root.identity.inode
    )
  }

  private static func relativePath(_ value: String, root: RegisteredRoot) throws -> String {
    guard !value.isEmpty, value.utf8.count <= CodexApprovalWireLimits.stringBytes,
      !value.hasPrefix("~"), !value.lowercased().hasPrefix("file:"), !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      let normalizedRoot = normalizedAbsolutePath(root.canonicalPath),
      normalizedRoot == root.canonicalPath
    else { throw IsolatedCodexTaskRuntimeError.protocolViolation }
    let candidate = value.hasPrefix("/") ? value : normalizedRoot + "/" + value
    guard let normalized = normalizedAbsolutePath(candidate) else {
      throw IsolatedCodexTaskRuntimeError.protocolViolation
    }
    let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
    guard normalized.hasPrefix(prefix) else {
      throw IsolatedCodexTaskRuntimeError.protocolViolation
    }
    do {
      return try SecureRelativePath(String(normalized.dropFirst(prefix.count))).value
    } catch {
      throw IsolatedCodexTaskRuntimeError.protocolViolation
    }
  }

  private static func normalizedAbsolutePath(_ value: String) -> String? {
    guard value.hasPrefix("/"), !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    return URL(fileURLWithPath: value).standardizedFileURL.path
  }

  private static func permissionsEvidence(
    approvalID: ApprovalID,
    request: CodexPermissionsApprovalRequest,
    execution: CodexCommandExecutionEvidence,
    digest: String,
    root: RegisteredRoot
  ) throws -> CodexApprovalEvidence {
    guard request.workingDirectory == execution.workingDirectory else {
      throw IsolatedCodexTaskRuntimeError.protocolViolation
    }
    let summaries = permissionSummaries(request.permissions, projectRoot: root.canonicalPath)
    return try CodexApprovalEvidence(
      approvalID: approvalID,
      kind: .permissions,
      authority: .requestedPermissionProfile,
      threadID: ThreadID(rawValue: request.correlation.item.threadID),
      turnID: TurnID(rawValue: request.correlation.item.turnID),
      itemID: request.correlation.item.itemID,
      callbackID: request.correlation.callbackID,
      startedAtMilliseconds: request.correlation.startedAtMilliseconds,
      operationTitle: "Codex 权限范围审批",
      displayCommand: safeText(execution.displayCommand, maximumBytes: 8 * 1_024),
      displayArguments: Array(summaries.prefix(8)),
      omittedOperationCount: max(0, summaries.count - 8),
      workingDirectory: safePath(request.workingDirectory, projectRoot: root.canonicalPath),
      reason: safeText(request.reason, maximumBytes: 2 * 1_024),
      evidenceDigest: digest
    )
  }

  private static func validateCommandCorrelation(
    _ request: CodexCommandApprovalRequest,
    execution: CodexCommandExecutionEvidence
  ) throws {
    if let command = request.displayCommand, command != execution.displayCommand {
      throw IsolatedCodexTaskRuntimeError.protocolViolation
    }
    if let workingDirectory = request.displayWorkingDirectory,
      workingDirectory != execution.workingDirectory
    {
      throw IsolatedCodexTaskRuntimeError.protocolViolation
    }
    if let actions = request.displayActions, actions != execution.displayActions {
      throw IsolatedCodexTaskRuntimeError.protocolViolation
    }
  }

  private static func evidenceDigest(
    requestParameters: JSONValue,
    itemSourceDigest: String
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(
      JSONValue.object([
        "itemDigest": .string(itemSourceDigest),
        "request": requestParameters,
      ]))
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func canonicalSource(_ value: JSONValue) throws -> (digest: String, byteCount: Int) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    return (
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      data.count
    )
  }

  private static func actionSummary(
    _ action: CodexCommandAction,
    projectRoot: String
  ) -> String {
    let value: String
    switch action {
    case .read(_, let name, let path):
      value = "读取 \(name)：\(safePath(path, projectRoot: projectRoot))"
    case .listFiles(_, let path):
      value = "列出文件：\(path.map { safePath($0, projectRoot: projectRoot) } ?? ".")"
    case .search(_, let path, let query):
      let scope = path.map { safePath($0, projectRoot: projectRoot) } ?? "."
      let safeQuery = safeText(query, maximumBytes: 256) ?? "未提供查询"
      value = "搜索 \(scope)：\(safeQuery)"
    case .unknown(let displayCommand):
      value = "未分类操作：\(safeText(displayCommand, maximumBytes: 384) ?? "[REDACTED]")"
    }
    return OutboundContentSecurity.redacted(value, maximumUTF8Bytes: 512)
  }

  private static func commandSummaries(
    _ request: CodexCommandApprovalRequest,
    actions: [CodexCommandAction],
    projectRoot: String
  ) -> [String] {
    var result: [String] = []
    if let network = request.networkContext {
      let host = safeText(network.host, maximumBytes: 256) ?? "[REDACTED]"
      result.append("网络目标 \(network.protocol.rawValue)：\(host)")
    }
    for amendment in request.proposedNetworkPolicyAmendments ?? [] {
      let host = safeText(amendment.host, maximumBytes: 256) ?? "[REDACTED]"
      result.append("网络策略 \(amendment.action.rawValue)：\(host)")
    }
    for amendment in request.proposedExecPolicyAmendment ?? [] {
      let value = safeText(amendment, maximumBytes: 384) ?? "[REDACTED]"
      result.append("执行策略变更：\(value)")
    }
    if let environmentID = request.environmentID {
      let value = safeText(environmentID, maximumBytes: 256) ?? "[REDACTED]"
      result.append("环境：\(value)")
    }
    result.append(contentsOf: actions.map { actionSummary($0, projectRoot: projectRoot) })
    return result
  }

  private static func actionPath(_ action: CodexCommandAction) -> String? {
    switch action {
    case .read(_, _, let path): path
    case .listFiles(_, let path), .search(_, let path, _): path
    case .unknown: nil
    }
  }

  private static func permissionSummaries(
    _ profile: CodexRequestPermissionProfile,
    projectRoot: String
  ) -> [String] {
    var result: [String] = []
    if let fileSystem = profile.fileSystem {
      for entry in fileSystem.entries ?? [] {
        result.append(
          "文件系统 \(entry.access.rawValue)：\(permissionPath(entry.path, projectRoot: projectRoot))"
        )
      }
      for path in fileSystem.legacyReadPaths ?? [] {
        result.append("文件系统 read：\(safePath(path, projectRoot: projectRoot))")
      }
      for path in fileSystem.legacyWritePaths ?? [] {
        result.append("文件系统 write：\(safePath(path, projectRoot: projectRoot))")
      }
      if let depth = fileSystem.globScanMaximumDepth {
        result.append("Glob 扫描深度：\(depth)")
      }
    }
    if let enabled = profile.network?.enabled {
      result.append("网络访问：\(enabled ? "请求启用" : "保持关闭")")
    }
    return result.isEmpty ? ["未请求附加权限"] : result
  }

  private static func permissionPath(
    _ path: CodexFileSystemPath,
    projectRoot: String
  ) -> String {
    switch path {
    case .path(let value), .globPattern(let value):
      safePath(value, projectRoot: projectRoot)
    case .special(let special):
      switch special {
      case .root: "特殊路径：root"
      case .minimal: "特殊路径：minimal"
      case .projectRoots(let subpath):
        "项目根\(subpath.map { "/\(safePath($0, projectRoot: projectRoot))" } ?? "")"
      case .temporaryDirectory: "特殊路径：temporaryDirectory"
      case .slashTemporaryDirectory: "特殊路径：/tmp"
      case .unknown(let path, let subpath):
        "特殊路径：\(safeText(path, maximumBytes: 128) ?? "[REDACTED]")\(subpath.map { "/\(safePath($0, projectRoot: projectRoot))" } ?? "")"
      }
    }
  }

  private static func safeText(_ value: String?, maximumBytes: Int) -> String? {
    value.map { OutboundContentSecurity.redacted($0, maximumUTF8Bytes: maximumBytes) }
  }

  private static func safePath(_ value: String, projectRoot: String) -> String {
    guard value.hasPrefix("/") else {
      return OutboundContentSecurity.isSafeOutboundRelativePath(value)
        ? value : "[REDACTED]"
    }
    let normalizedRoot = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
    let normalized = URL(fileURLWithPath: value).standardizedFileURL.path
    if normalized == normalizedRoot { return "." }
    let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
    guard normalized.hasPrefix(prefix) else { return "[REDACTED]" }
    let relative = String(normalized.dropFirst(prefix.count))
    return OutboundContentSecurity.isSafeOutboundRelativePath(relative)
      ? relative : "[REDACTED]"
  }

  private static func startedAt(_ evidence: CodexApprovalItemEvidence) -> Int64 {
    switch evidence {
    case .commandExecution(let command): command.startedAtMilliseconds
    case .fileChange(let file): file.startedAtMilliseconds
    }
  }
}
