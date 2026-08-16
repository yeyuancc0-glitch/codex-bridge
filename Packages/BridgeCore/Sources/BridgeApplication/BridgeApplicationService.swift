import BridgeCoordinator
import BridgeDomain
import BridgeFiles
import BridgeMCP
import BridgePersistence
import BridgeProjects
import BridgeReporting
import BridgeRepositories
import BridgeSecurity
import Foundation

public enum BridgeApplicationError: Error, Equatable, Sendable {
  case invalidArgument
  case deadlineExceeded
  case catalogUnavailable
  case catalogLimitExceeded
  case invalidCatalogResponse
  case invalidStoredReport
}

public enum LocalReadOnlyTaskPolicy {
  public static let supervisorModelID = "gpt-5.6-luna"

  public static func isLunaModel(id: String, displayName: String) -> Bool {
    _ = displayName
    return id == supervisorModelID
  }

  public static var defaultSupervisorModelID: String { supervisorModelID }
}

public actor BridgeApplicationService:
  BridgeMCPQueries, BridgeMCPTaskOperations, BridgeMCPProjectOperations
{
  private static let localTaskOrigin = "macos.app"
  private static let remoteTaskOrigin = "chatgpt.mcp"

  private let coordinator: TaskCoordinator
  private let eventStore: EventStore
  private let projectRepository: any ProjectRepository
  private let reportStore: any FinalReportStore
  private let catalog: any CodexCatalogQuerying
  private let status: any BridgeStatusProviding
  private let artifacts: any TaskArtifactQuerying
  private let files: RestrictedProjectFileService
  private let openCodexURL: @Sendable (URL) async -> Bool
  private let iso8601 = ISO8601DateFormatter()

  public init(
    coordinator: TaskCoordinator,
    eventStore: EventStore,
    projectRepository: any ProjectRepository,
    reportStore: any FinalReportStore,
    catalog: any CodexCatalogQuerying,
    status: any BridgeStatusProviding,
    artifacts: any TaskArtifactQuerying = UnavailableTaskArtifacts(),
    files: RestrictedProjectFileService? = nil,
    openCodexURL: @escaping @Sendable (URL) async -> Bool = { _ in false }
  ) {
    self.coordinator = coordinator
    self.eventStore = eventStore
    self.projectRepository = projectRepository
    self.reportStore = reportStore
    self.catalog = catalog
    self.status = status
    self.artifacts = artifacts
    self.files = files ?? RestrictedProjectFileService(repository: projectRepository)
    self.openCodexURL = openCodexURL
  }

  public func getProject(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail {
    do {
      let project = try await requireReadableProject(projectID)
      try Self.checkDeadline(deadline)
      return MCPProjectDetail(
        projectID: project.id.rawValue,
        name: Self.sanitize(project.name, maximumBytes: 1_024),
        capabilities: MCPProjectCapabilities(
          read: project.accessPolicy.read.rawValue,
          write: project.accessPolicy.write.rawValue,
          network: project.accessPolicy.network.rawValue
        ),
        verificationCommands: project.verificationCommands.map(Self.commandName)
      )
    } catch {
      throw Self.publicError(error)
    }
  }

  public func accountRateLimits(
    deadline: ContinuousClock.Instant
  ) async throws -> CatalogRateLimitSummary {
    try Self.checkDeadline(deadline)
    return try await catalog.readAccountRateLimits(deadline: deadline)
  }

  public func searchProjectFiles(
    projectID: String,
    query: String,
    relativeDirectory: String?,
    caseSensitive: Bool,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileSearchPage {
    do {
      try Self.checkDeadline(deadline)
      let result = try await files.search(
        ProjectFileSearchRequest(
          projectID: ProjectID(rawValue: projectID),
          query: query,
          relativeDirectory: relativeDirectory,
          caseSensitive: caseSensitive,
          limit: limit,
          cursor: cursor
        )
      )
      try Self.checkDeadline(deadline)
      return MCPProjectFileSearchPage(
        matches: result.matches.enumerated().map { index, match in
          let preview = Self.sourceRedaction(match.preview, maximumBytes: 1_024)
          let relativePath = Self.outboundRelativePath(match.relativePath, index: index)
          return MCPProjectFileSearchMatch(
            relativePath: relativePath,
            lineNumber: match.lineNumber,
            preview: preview.text,
            redacted: match.redacted || preview.changed || relativePath != match.relativePath
          )
        },
        nextCursor: result.nextCursor,
        skippedFileCount: result.skippedFileCount
      )
    } catch {
      throw Self.publicError(error)
    }
  }

  public func readProjectFile(
    projectID: String,
    relativePath: String,
    startLine: Int,
    lineCount: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileReadPage {
    do {
      try Self.checkDeadline(deadline)
      let result = try await files.read(
        ProjectFileReadRequest(
          projectID: ProjectID(rawValue: projectID),
          relativePath: relativePath,
          lineRange: try FileLineRange(startLine: startLine, lineCount: lineCount)
        )
      )
      try Self.checkDeadline(deadline)
      let content = Self.sourceRedaction(result.content, maximumBytes: 200 * 1_024)
      guard !content.truncated else { throw BridgeApplicationError.invalidCatalogResponse }
      let returnedLineCount = result.endLine.map { $0 - result.startLine + 1 } ?? 0
      return MCPProjectFileReadPage(
        relativePath: result.relativePath,
        startLine: result.startLine,
        endLine: result.endLine,
        content: content.text,
        redactedLineCount: min(
          returnedLineCount,
          result.redactedLineCount + content.redactedLineCount
        ),
        truncated: result.truncated,
        nextStartLine: result.nextStartLine
      )
    } catch {
      throw Self.publicError(error)
    }
  }

  public func openInCodex(
    projectID: String,
    threadID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPOpenInCodexReceipt {
    do {
      try Self.validateIdentifier(threadID, maximum: 1_024)
      let project = try await requireReadableProject(projectID)
      let thread = try await catalog.readThread(
        threadID: threadID,
        includeTurns: false,
        deadline: deadline
      )
      guard thread.threadID == threadID, Self.executionRoots(project).contains(thread.cwd) else {
        throw BridgeMCPQueryError.threadNotFound
      }
      var components = URLComponents()
      components.scheme = "codex"
      components.host = "threads"
      components.path = "/\(threadID)"
      guard let url = components.url else { throw BridgeApplicationError.invalidArgument }
      let opened = await openCodexURL(url)
      guard opened else { throw BridgeMCPQueryError.unavailable }
      return MCPOpenInCodexReceipt(
        projectID: projectID,
        threadID: threadID,
        opened: true
      )
    } catch {
      throw Self.publicError(error)
    }
  }

  public func statusSnapshot(
    deadline: ContinuousClock.Instant
  ) async throws -> BridgeStatusSnapshot {
    do {
      try Self.checkDeadline(deadline)
      let snapshot = try await status.snapshot(deadline: deadline)
      try Self.checkDeadline(deadline)
      return snapshot
    } catch {
      throw Self.publicError(error)
    }
  }

  public func listMCPVisibleProjects(
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage {
    do {
      try Self.validatePage(limit: limit, cursor: cursor)
      try Self.checkDeadline(deadline)
      let projects = try await projectRepository.allProjects()
        .filter { $0.accessPolicy.read != .denied }
        .sorted(by: Self.projectOrder)
      let start = try Self.startIndex(after: cursor, in: projects.map(\.id.rawValue))
      let end = min(projects.count, start + limit)
      let page = projects[start..<end].map(Self.projectSummary)
      let next = end < projects.count ? projects[end - 1].id.rawValue : nil
      try Self.checkDeadline(deadline)
      return MCPProjectPage(projects: page, nextCursor: next)
    } catch {
      throw Self.publicError(error)
    }
  }

  public func listThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    do {
      try Self.validatePage(limit: limit, cursor: cursor)
      let project = try await requireReadableProject(projectID)
      let allowedRoots = Self.executionRoots(project)
      let page = try await catalog.listThreads(
        canonicalWorkingDirectories: allowedRoots,
        cursor: cursor,
        limit: limit,
        search: search,
        deadline: deadline
      )
      guard page.threads.count <= limit,
        page.threads.allSatisfy({ allowedRoots.contains($0.cwd) })
      else {
        throw BridgeApplicationError.invalidCatalogResponse
      }
      for thread in page.threads {
        try Self.validateOutboundIdentifier(thread.threadID, maximum: 1_024)
      }
      try Self.validateOutboundOptional(page.nextCursor, maximum: 2_048)
      return MCPThreadPage(
        threads: page.threads.map(threadSummary),
        nextCursor: page.nextCursor
      )
    } catch {
      throw Self.publicError(error)
    }
  }

  public func readThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    do {
      try Self.validateIdentifier(threadID, maximum: 1_024)
      try Self.validatePage(limit: limit, cursor: cursor)
      let project = try await requireReadableProject(projectID)
      let thread = try await catalog.readThread(
        threadID: threadID,
        includeTurns: detail == .full,
        deadline: deadline
      )
      let allowedRoots = Self.executionRoots(project)
      guard thread.threadID == threadID, allowedRoots.contains(thread.cwd) else {
        throw BridgeMCPQueryError.threadNotFound
      }
      try Self.validateOutboundIdentifier(thread.threadID, maximum: 1_024)
      let entries = detail == .full ? thread.entries : []
      let start = try Self.entryStartIndex(cursor, count: entries.count)
      let end = min(entries.count, start + limit)
      for entry in entries[start..<end] {
        try Self.validateOutboundIdentifier(entry.turnID, maximum: 1_024)
        guard entry.role == "assistant" || entry.role == "user" else {
          throw BridgeApplicationError.invalidCatalogResponse
        }
      }
      let page = entries[start..<end].map(Self.threadEntry)
      let next = end < entries.count ? Self.entryCursor(end) : nil
      try Self.checkDeadline(deadline)
      return MCPThreadReadPage(
        thread: threadSummary(thread),
        detail: detail,
        entries: page,
        nextCursor: next
      )
    } catch {
      throw Self.publicError(error)
    }
  }

  public func listModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList {
    do {
      let values = try await validatedCatalogModels(deadline: deadline).map { model in
        return MCPModelSummary(
          modelID: model.id,
          displayName: Self.sanitize(model.displayName, maximumBytes: 1_024),
          isDefault: model.isDefault,
          reasoningEfforts: model.reasoningEfforts,
          defaultReasoningEffort: model.defaultReasoningEffort
        )
      }
      return MCPModelList(models: values)
    } catch {
      throw Self.publicError(error)
    }
  }

  public func getTask(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskSnapshot {
    do {
      let projection = try await projection(taskID, deadline: deadline)
      let artifactSummary = await artifactSummary(taskID: taskID, deadline: deadline)
      let reportAvailable =
        try await reportStore.finalReport(
          for: TaskID(rawValue: taskID)
        ) != nil
      try Self.checkDeadline(deadline)
      let aggregate = projection.aggregate
      try Self.validateOutboundOptional(aggregate.binding?.threadID.rawValue, maximum: 1_024)
      try Self.validateOutboundOptional(aggregate.binding?.turnID.rawValue, maximum: 1_024)
      return MCPTaskSnapshot(
        taskID: taskID,
        phase: aggregate.phase.rawValue,
        activity: aggregate.activity.rawValue,
        threadID: aggregate.binding?.threadID.rawValue,
        turnID: aggregate.binding?.turnID.rawValue,
        currentPlan: aggregate.submission.contract.requirements.map {
          Self.sanitize($0, maximumBytes: 4_096)
        },
        supervisorState: Self.supervisorState(aggregate),
        changedFileCount: artifactSummary.changedFileCount,
        verificationSummary: artifactSummary.verificationSummary.map {
          Self.sanitize($0, maximumBytes: 4_096)
        },
        finalReportAvailable: reportAvailable
      )
    } catch {
      throw Self.publicError(error)
    }
  }

  public func getTaskEvents(
    taskID: String,
    afterSequence: Int64?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskEventPage {
    do {
      _ = try await projection(taskID, deadline: deadline)
      let after = afterSequence ?? 0
      guard after >= 0, (1...100).contains(limit) else {
        throw BridgeApplicationError.invalidArgument
      }
      var events = try await eventStore.events(
        for: TaskID(rawValue: taskID),
        afterSequence: after,
        limit: limit + 1
      )
      let hasMore = events.count > limit
      if hasMore { events.removeLast(events.count - limit) }
      let values = events.map { event in
        MCPTaskEvent(
          sequence: event.sequence,
          kind: event.kind,
          occurredAt: iso8601.string(from: event.createdAt)
        )
      }
      return MCPTaskEventPage(
        taskID: taskID,
        events: values,
        nextAfterSequence: hasMore ? values.last?.sequence : nil
      )
    } catch {
      throw Self.publicError(error)
    }
  }

  public func getTaskDiff(
    taskID: String,
    cursor: String?,
    limit: Int,
    includePatch: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskDiffPage {
    do {
      _ = try await projection(taskID, deadline: deadline)
      return try await artifacts.diff(
        taskID: taskID,
        cursor: cursor,
        limit: limit,
        includePatch: includePatch,
        deadline: deadline
      )
    } catch {
      throw Self.publicError(error)
    }
  }

  public func getFinalReport(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPFinalReport {
    do {
      let task = try await projection(taskID, deadline: deadline)
      guard task.aggregate.phase.isTerminal else {
        throw BridgeMCPQueryError.invalidTaskState
      }
      guard let stored = try await reportStore.finalReport(for: TaskID(rawValue: taskID)) else {
        throw BridgeMCPQueryError.invalidTaskState
      }
      let report = try Self.decodeReport(stored.json)
      guard report.taskID == taskID else { throw BridgeApplicationError.invalidStoredReport }
      try Self.checkDeadline(deadline)
      return try Self.mcpReport(report)
    } catch {
      throw Self.publicError(error)
    }
  }

  public func submitTask(
    _ submission: TaskSubmission,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskSubmissionReceipt {
    try await submit(
      submission,
      origin: Self.remoteTaskOrigin,
      deadline: deadline
    )
  }

  public func submitLocalTask(
    _ submission: TaskSubmission,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskSubmissionReceipt {
    do {
      try Self.checkDeadline(deadline)
      if let existing = try await coordinator.existingSubmissionResult(
        origin: Self.localTaskOrigin,
        submission: submission
      ) {
        try Self.checkDeadline(deadline)
        return Self.submissionReceipt(existing)
      }
      try await validateLocalSubmission(submission, deadline: deadline)
      return try await submit(
        submission,
        origin: Self.localTaskOrigin,
        deadline: deadline
      )
    } catch {
      throw Self.publicError(error)
    }
  }

  private func submit(
    _ submission: TaskSubmission,
    origin: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskSubmissionReceipt {
    do {
      try Self.checkDeadline(deadline)
      _ = try await requireReadableProject(submission.projectID.rawValue)
      let result = try await coordinator.submitWithResult(
        origin: origin,
        submission: submission
      )
      try Self.checkDeadline(deadline)
      return Self.submissionReceipt(result)
    } catch {
      throw Self.publicError(error)
    }
  }

  private func validateLocalSubmission(
    _ submission: TaskSubmission,
    deadline: ContinuousClock.Instant
  ) async throws {
    guard submission.execution.permissionMode == "read-only",
      !submission.execution.networkAccess
    else { throw BridgeMCPQueryError.contractRejected }
    if !submission.supervisor.enabled {
      guard submission.supervisor.deterministicFallbackAuthorized else {
        throw BridgeMCPQueryError.contractRejected
      }
    }
    let project = try await requireReadableProject(submission.projectID.rawValue)
    if case .existing(let threadID) = submission.thread {
      try Self.validateOutboundIdentifier(threadID.rawValue, maximum: 1_024)
      let thread = try await catalog.readThread(
        threadID: threadID.rawValue,
        includeTurns: false,
        deadline: deadline
      )
      guard thread.threadID == threadID.rawValue,
        Self.executionRoots(project).contains(thread.cwd)
      else { throw BridgeMCPQueryError.threadNotFound }
    }
    let models = try await validatedCatalogModels(deadline: deadline)
    guard
      let execution = models.first(where: { $0.id == submission.execution.model }),
      execution.reasoningEfforts.contains(submission.execution.effort)
    else { throw BridgeMCPQueryError.contractRejected }
    if submission.supervisor.enabled {
      guard
        let supervisor = models.first(where: { $0.id == submission.supervisor.model }),
        supervisor.reasoningEfforts.contains(submission.supervisor.effort)
      else { throw BridgeMCPQueryError.contractRejected }
    }
  }

  private func validatedCatalogModels(
    deadline: ContinuousClock.Instant
  ) async throws -> [CatalogModel] {
    try Self.checkDeadline(deadline)
    let models = try await catalog.listModels(deadline: deadline)
    try Self.checkDeadline(deadline)
    guard models.count <= 800, Set(models.map(\.id)).count == models.count else {
      throw BridgeApplicationError.invalidCatalogResponse
    }
    for model in models {
      try Self.validateIdentifier(model.id, maximum: 256)
      guard OutboundContentSecurity.isSafe(model.id) else {
        throw BridgeApplicationError.invalidCatalogResponse
      }
      guard !model.reasoningEfforts.isEmpty,
        Set(model.reasoningEfforts).count == model.reasoningEfforts.count
      else { throw BridgeApplicationError.invalidCatalogResponse }
      for effort in model.reasoningEfforts {
        try Self.validateIdentifier(effort, maximum: 64)
        guard OutboundContentSecurity.isSafe(effort) else {
          throw BridgeApplicationError.invalidCatalogResponse
        }
      }
      if let defaultEffort = model.defaultReasoningEffort {
        try Self.validateIdentifier(defaultEffort, maximum: 64)
        guard OutboundContentSecurity.isSafe(defaultEffort),
          model.reasoningEfforts.contains(defaultEffort)
        else { throw BridgeApplicationError.invalidCatalogResponse }
      }
    }
    return models
  }

  private static func submissionReceipt(
    _ result: TaskSubmissionResult
  ) -> MCPTaskSubmissionReceipt {
    MCPTaskSubmissionReceipt(
      taskID: result.projection.aggregate.id.rawValue,
      phase: result.projection.aggregate.phase.rawValue,
      reusedExistingTask: result.reusedExistingTask,
      localApprovalRequired: result.projection.aggregate.phase == .awaitingLocalApproval
    )
  }

  public func steerTask(
    taskID: String,
    expectedTurnID: String,
    input: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskMutationReceipt {
    do {
      try Self.validateIdentifier(taskID, maximum: 256)
      try Self.validateIdentifier(expectedTurnID, maximum: 1_024)
      try Self.checkDeadline(deadline)
      let result = try await coordinator.steerWithResult(
        taskID: TaskID(rawValue: taskID),
        expectedTurnID: TurnID(rawValue: expectedTurnID),
        prompt: input
      )
      try Self.checkDeadline(deadline)
      return Self.mutationReceipt(result)
    } catch {
      throw Self.publicError(error)
    }
  }

  public func interruptTask(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskMutationReceipt {
    do {
      _ = try await projection(taskID, deadline: deadline)
      let result = try await coordinator.interruptWithResult(
        taskID: TaskID(rawValue: taskID),
        reason: "Interrupted by an authenticated ChatGPT MCP request."
      )
      try Self.checkDeadline(deadline)
      return Self.mutationReceipt(result)
    } catch {
      throw Self.publicError(error)
    }
  }

  public func interruptTask(
    taskID: String,
    expectedTurnID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskMutationReceipt {
    do {
      try Self.validateIdentifier(taskID, maximum: 256)
      try Self.validateIdentifier(expectedTurnID, maximum: 1_024)
      try Self.checkDeadline(deadline)
      let result = try await coordinator.interruptWithResult(
        taskID: TaskID(rawValue: taskID),
        expectedTurnID: TurnID(rawValue: expectedTurnID),
        reason: "Interrupted by an authenticated ChatGPT MCP request."
      )
      try Self.checkDeadline(deadline)
      return Self.mutationReceipt(result)
    } catch {
      throw Self.publicError(error)
    }
  }

  private func requireReadableProject(_ rawID: String) async throws -> RegisteredProject {
    try Self.validateIdentifier(rawID, maximum: 256)
    guard let project = try await projectRepository.project(id: ProjectID(rawValue: rawID)),
      project.accessPolicy.read != .denied
    else {
      throw BridgeMCPQueryError.projectNotFound
    }
    do {
      try project.validateCurrentRoots()
    } catch {
      throw BridgeMCPQueryError.projectNotFound
    }
    return project
  }

  private func projection(
    _ rawTaskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> TaskProjection {
    try Self.validateIdentifier(rawTaskID, maximum: 256)
    try Self.checkDeadline(deadline)
    return try await coordinator.task(TaskID(rawValue: rawTaskID))
  }

  private func artifactSummary(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async -> TaskArtifactSummary {
    do {
      let summary = try await artifacts.summary(taskID: taskID, deadline: deadline)
      guard summary.changedFileCount >= 0 else { return TaskArtifactSummary() }
      return summary
    } catch {
      return TaskArtifactSummary()
    }
  }

  private func threadSummary(_ thread: CatalogThread) -> MCPThreadSummary {
    MCPThreadSummary(
      threadID: thread.threadID,
      title: thread.title.map { Self.sanitize($0, maximumBytes: 2_048) },
      status: Self.sanitize(thread.status, maximumBytes: 128),
      updatedAt: thread.updatedAt.map(iso8601.string(from:)),
      preview: thread.preview.map { Self.sanitize($0, maximumBytes: 4_096) }
    )
  }

  private static func projectSummary(_ project: RegisteredProject) -> MCPProjectSummary {
    MCPProjectSummary(
      projectID: project.id.rawValue,
      name: sanitize(project.name, maximumBytes: 1_024),
      capabilities: MCPProjectCapabilities(
        read: project.accessPolicy.read.rawValue,
        write: project.accessPolicy.write.rawValue,
        network: project.accessPolicy.network.rawValue
      )
    )
  }

  private static func threadEntry(_ entry: CatalogThreadEntry) -> MCPThreadEntry {
    MCPThreadEntry(
      turnID: entry.turnID,
      role: entry.role,
      text: sanitize(entry.text, maximumBytes: 16 * 1_024),
      status: entry.status.map { sanitize($0, maximumBytes: 128) }
    )
  }

  private static func mutationReceipt(_ result: TaskMutationResult) -> MCPTaskMutationReceipt {
    MCPTaskMutationReceipt(
      taskID: result.projection.aggregate.id.rawValue,
      phase: result.projection.aggregate.phase.rawValue,
      accepted: true,
      operationID: result.operationID.rawValue
    )
  }

  private static func decodeReport(_ data: Data) throws -> FinalReport {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.keyDecodingStrategy = .custom { path in
      let source = path.last?.stringValue ?? ""
      return ApplicationCodingKey(Self.reportPropertyName(source))
    }
    do {
      return try decoder.decode(FinalReport.self, from: data)
    } catch {
      throw BridgeApplicationError.invalidStoredReport
    }
  }

  private static func mcpReport(_ report: FinalReport) throws -> MCPFinalReport {
    try validateOutboundIdentifier(report.threadID, maximum: 1_024)
    try validateOutboundIdentifier(report.execution.model, maximum: 256)
    try validateOutboundIdentifier(report.execution.effort, maximum: 64)
    return MCPFinalReport(
      taskID: report.taskID,
      status: report.status.rawValue,
      projectName: sanitize(report.project, maximumBytes: 4_096),
      threadID: report.threadID,
      executionModel: report.execution.model,
      executionEffort: report.execution.effort,
      summary: sanitize(report.summary, maximumBytes: 16 * 1_024),
      changedFiles: report.changedFiles.enumerated().map { index, file in
        outboundRelativePath(file.relativePath, index: index)
      },
      diffStat: sanitize(report.diffStat, maximumBytes: 8 * 1_024),
      commands: report.commands.map(commandSummary),
      verification: report.verification.map(verificationSummary),
      warnings: report.warnings.map { sanitize($0, maximumBytes: 4_096) },
      unresolvedItems: report.unresolvedItems.map { sanitize($0, maximumBytes: 4_096) },
      commit: report.commit,
      startedAt: iso8601String(report.startedAt),
      completedAt: iso8601String(report.completedAt)
    )
  }

  private static func commandSummary(_ command: AppServerCommandEvidence) -> String {
    let executable = URL(fileURLWithPath: command.executable).lastPathComponent
    let arguments = command.arguments.map { argument in
      argument.hasPrefix("/") || argument.hasPrefix("~")
        ? "[path]"
        : sanitize(argument, maximumBytes: 1_024)
    }
    let exit = command.exitCode.map { " exit=\($0)" } ?? ""
    return sanitize(([executable] + arguments).joined(separator: " ") + exit, maximumBytes: 4_096)
  }

  private static func commandName(_ command: VerificationCommand) -> String {
    let executable = URL(fileURLWithPath: command.executable).lastPathComponent
    return sanitize(([executable] + command.arguments).joined(separator: " "), maximumBytes: 4_096)
  }

  private static func verificationSummary(_ evidence: VerificationEvidence) -> String {
    let exit = evidence.exitCode.map { " exit=\($0)" } ?? ""
    return sanitize("\(evidence.name): \(evidence.status.rawValue)\(exit)", maximumBytes: 4_096)
  }

  private static func supervisorState(_ aggregate: TaskAggregate) -> String {
    guard aggregate.submission.supervisor.enabled else { return "disabled" }
    return aggregate.activity.rawValue
  }

  private static func executionRoots(_ project: RegisteredProject) -> [String] {
    ([project.primaryRoot] + project.worktreeRoots).map(\.canonicalPath)
  }

  private static func projectOrder(_ lhs: RegisteredProject, _ rhs: RegisteredProject) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.id.rawValue < rhs.id.rawValue
  }

  private static func startIndex(after cursor: String?, in identifiers: [String]) throws -> Int {
    guard let cursor else { return 0 }
    guard let index = identifiers.firstIndex(of: cursor) else {
      throw BridgeApplicationError.invalidArgument
    }
    return identifiers.index(after: index)
  }

  private static func entryStartIndex(_ cursor: String?, count: Int) throws -> Int {
    guard let cursor else { return 0 }
    guard cursor.hasPrefix("entry:"), let index = Int(cursor.dropFirst(6)),
      (0...count).contains(index)
    else {
      throw BridgeApplicationError.invalidArgument
    }
    return index
  }

  private static func entryCursor(_ index: Int) -> String {
    "entry:\(index)"
  }

  private static func validatePage(limit: Int, cursor: String?) throws {
    guard (1...100).contains(limit), cursor?.utf8.count ?? 0 <= 2_048 else {
      throw BridgeApplicationError.invalidArgument
    }
  }

  private static func validateIdentifier(_ value: String, maximum: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maximum, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw BridgeApplicationError.invalidArgument
    }
  }

  private static func validateOutboundIdentifier(_ value: String, maximum: Int) throws {
    try validateIdentifier(value, maximum: maximum)
    guard OutboundContentSecurity.isSafe(value) else {
      throw BridgeApplicationError.invalidCatalogResponse
    }
  }

  private static func validateOutboundOptional(_ value: String?, maximum: Int) throws {
    guard let value else { return }
    try validateOutboundIdentifier(value, maximum: maximum)
  }

  private static func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now < deadline else { throw BridgeMCPQueryError.timeout }
  }

  private static func sanitize(_ value: String, maximumBytes: Int) -> String {
    redaction(value, maximumBytes: maximumBytes).text
  }

  private static func outboundRelativePath(_ value: String, index: Int = 0) -> String {
    guard OutboundContentSecurity.isSafeOutboundRelativePath(value) else {
      return "[redacted-sensitive-path-\(index)]"
    }
    return value
  }

  private static func redaction(_ value: String, maximumBytes: Int) -> OutboundRedaction {
    OutboundContentSecurity.redaction(of: value, maximumUTF8Bytes: maximumBytes)
  }

  private static func sourceRedaction(_ value: String, maximumBytes: Int) -> OutboundRedaction {
    OutboundContentSecurity.redaction(
      of: value,
      maximumUTF8Bytes: maximumBytes,
      preservingSourceSyntax: true
    )
  }

  private static func iso8601String(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func reportPropertyName(_ source: String) -> String {
    let components = source.split(separator: "_", omittingEmptySubsequences: false)
    guard let first = components.first else { return source }
    return components.dropFirst().reduce(String(first)) { result, component in
      if component == "id" { return result + "ID" }
      return result + component.prefix(1).uppercased() + component.dropFirst()
    }
  }

  private static func publicError(_ error: any Error) -> any Error {
    if error is CancellationError { return CancellationError() }
    if let query = error as? BridgeMCPQueryError { return query }
    if error is TaskCoordinatorTurnMismatchError { return BridgeMCPQueryError.turnMismatch }
    if error is TaskCoordinatorEventSequenceMismatchError {
      return BridgeMCPQueryError.eventSequenceMismatch
    }
    if let store = error as? EventStoreError {
      if case .idempotencyMismatch = store { return BridgeMCPQueryError.idempotencyConflict }
      return BridgeMCPQueryError.unavailable
    }
    if let coordinator = error as? TaskCoordinatorError {
      switch coordinator {
      case .unknownTask: return BridgeMCPQueryError.taskNotFound
      case .projectReadDenied, .projectWriteDenied, .projectNetworkDenied,
        .unsupportedPermissionMode, .invalidSteerPrompt, .submissionTooLarge:
        return BridgeMCPQueryError.contractRejected
      default: return BridgeMCPQueryError.invalidTaskState
      }
    }
    if error is TaskTransitionError { return BridgeMCPQueryError.invalidTaskState }
    if error is ProjectRegistryError { return BridgeMCPQueryError.projectNotFound }
    if let files = error as? ProjectFileError {
      switch files {
      case .unknownProject: return BridgeMCPQueryError.projectNotFound
      case .readNotAllowed, .forbiddenPath: return BridgeMCPQueryError.pathDenied
      case .invalidLineRange, .invalidSearchRequest, .invalidCursor:
        return BridgeMCPQueryError.contractRejected
      default: return BridgeMCPQueryError.unavailable
      }
    }
    if error is PathSecurityError { return BridgeMCPQueryError.pathDenied }
    if let application = error as? BridgeApplicationError {
      switch application {
      case .deadlineExceeded: return BridgeMCPQueryError.timeout
      case .invalidArgument, .catalogUnavailable, .catalogLimitExceeded,
        .invalidCatalogResponse, .invalidStoredReport:
        return BridgeMCPQueryError.unavailable
      }
    }
    return BridgeMCPQueryError.unavailable
  }
}

private struct ApplicationCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init(_ stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(stringValue: String) {
    self.init(stringValue)
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}
