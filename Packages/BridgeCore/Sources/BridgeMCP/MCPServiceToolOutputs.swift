import BridgeFiles
import Foundation

struct ServiceGetProjectOutput: Codable, Sendable {
  let schemaVersion = 1
  let project: MCPProjectDetail

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case project
  }
}

struct ListSkillsOutput: Codable, Sendable {
  let schemaVersion = 1
  let skills: [MCPServiceSkill]
  init(list: MCPServiceSkillList) { skills = list.skills }
  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case skills
  }
}

struct ReadSkillOutput: Codable, Sendable {
  let schemaVersion = 1
  let name: String
  let subpath: String
  let content: String
  let byteCount: Int
  init(document: MCPServiceSkillDocument) {
    name = document.name
    subpath = document.subpath
    content = document.content
    byteCount = document.byteCount
  }
  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case name, subpath, content
    case byteCount = "byte_count"
  }
}

struct ServiceSearchProjectFilesOutput: Codable, Sendable {
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

struct ServiceReadProjectFileOutput: Codable, Sendable {
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

struct ServiceGetTaskOutput: Codable, Sendable {
  let schemaVersion = 1
  let task: MCPServiceTaskSnapshot

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case task
  }
}

struct ServiceSubmitTaskOutput: Codable, Sendable {
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

struct ServiceMutateTaskOutput: Codable, Sendable {
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

struct ServiceProjectChangesOutput: Codable, Sendable {
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

struct ServiceProjectCommandsOutput: Codable, Sendable {
  let schemaVersion = 1
  let commandMode: String
  let builtInCommands: [MCPBuiltInCommand]
  let registeredCommands: [MCPProjectCommand]
  let commands: [MCPProjectCommand]

  init(commands: MCPProjectCommands) {
    commandMode = commands.commandMode
    builtInCommands = commands.builtInCommands
    registeredCommands = commands.commands
    self.commands = commands.commands
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case commandMode = "command_mode"
    case builtInCommands = "built_in_commands"
    case registeredCommands = "registered_commands"
    case commands
  }
}

struct ServiceDirectMutationOutput: Codable, Sendable {
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

struct ServiceDirectPatchOutput: Codable, Sendable {
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

struct ServiceDirectManagePathOutput: Codable, Sendable {
  let schemaVersion = 1
  let relativePath: String
  let sourceRelativePath: String
  let destinationRelativePath: String?
  let operation: String
  let sha256: String?
  let oldSHA256: String?
  let newSHA256: String?
  let byteCount: Int

  init(receipt: MCPDirectManagePathReceipt) {
    relativePath = receipt.relativePath
    sourceRelativePath = receipt.sourceRelativePath
    destinationRelativePath = receipt.destinationRelativePath
    operation = receipt.operation
    sha256 = receipt.sha256
    oldSHA256 = receipt.oldSHA256
    newSHA256 = receipt.newSHA256
    byteCount = receipt.byteCount
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case relativePath = "relative_path"
    case sourceRelativePath = "source_relative_path"
    case destinationRelativePath = "destination_relative_path"
    case operation
    case sha256
    case oldSHA256 = "old_sha256"
    case newSHA256 = "new_sha256"
    case byteCount = "byte_count"
  }
}

struct ServiceDirectExecOutput: Codable, Sendable {
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

struct ServiceDirectCommandOutput: Codable, Sendable {
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

struct ServiceDirectWriteStdinOutput: Codable, Sendable {
  let schemaVersion = 1

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
  }
}

struct ServiceDirectGitCommitOutput: Codable, Sendable {
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
