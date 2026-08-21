import Foundation

public enum ProjectPermissionPresentation: String, Equatable, Sendable {
  case denied
  case requiresLocalApproval
  case allowed
}

public struct ProjectPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let normalizedPath: String
  public let branch: String?
  public let isDirty: Bool
  public let canRead: Bool
  public let canWrite: Bool
  public let networkAllowed: Bool
  public let requiresLocalConfirmation: Bool
  public let readPermission: ProjectPermissionPresentation
  public let writePermission: ProjectPermissionPresentation
  public let networkPermission: ProjectPermissionPresentation
  public let verificationCommands: [String]
  public let threadCount: Int
  public let lastTaskTitle: String?
  public let isAvailable: Bool
  public let threadCountIsKnown: Bool
  public let gitFactsKnown: Bool

  public init(
    id: String,
    name: String,
    normalizedPath: String,
    branch: String? = nil,
    isDirty: Bool,
    canRead: Bool,
    canWrite: Bool,
    networkAllowed: Bool,
    requiresLocalConfirmation: Bool,
    verificationCommands: [String] = [],
    threadCount: Int,
    lastTaskTitle: String? = nil,
    isAvailable: Bool,
    threadCountIsKnown: Bool = true,
    gitFactsKnown: Bool = true,
    readPermission: ProjectPermissionPresentation? = nil,
    writePermission: ProjectPermissionPresentation? = nil,
    networkPermission: ProjectPermissionPresentation? = nil
  ) {
    self.id = id
    self.name = name
    self.normalizedPath = normalizedPath
    self.branch = branch
    self.isDirty = isDirty
    self.canRead = canRead
    self.canWrite = canWrite
    self.networkAllowed = networkAllowed
    self.requiresLocalConfirmation = requiresLocalConfirmation
    self.readPermission = readPermission ?? (canRead ? .allowed : .denied)
    self.writePermission =
      writePermission
      ?? Self.permission(canUse: canWrite, requiresLocalConfirmation: requiresLocalConfirmation)
    self.networkPermission =
      networkPermission
      ?? Self.permission(
        canUse: networkAllowed,
        requiresLocalConfirmation: requiresLocalConfirmation
      )
    self.verificationCommands = verificationCommands
    self.threadCount = threadCount
    self.lastTaskTitle = lastTaskTitle
    self.isAvailable = isAvailable
    self.threadCountIsKnown = threadCountIsKnown
    self.gitFactsKnown = gitFactsKnown
  }

  private static func permission(
    canUse: Bool,
    requiresLocalConfirmation: Bool
  ) -> ProjectPermissionPresentation {
    guard canUse else { return .denied }
    return requiresLocalConfirmation ? .requiresLocalApproval : .allowed
  }
}

public struct ProjectPagePresentation: Equatable, Sendable {
  public let projects: [ProjectPresentation]

  public init(projects: [ProjectPresentation]) {
    self.projects = projects
  }
}

public struct ThreadPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let projectID: String?
  public let preview: String
  public let projectName: String
  public let source: String
  public let model: String
  public let status: PresentationStatus
  public let updatedAt: Date
  public let isOccupied: Bool
  public let canArchive: Bool
  public let canOpenInCodex: Bool
  public let canReadHistory: Bool
  public let canContinue: Bool
  public let canCreateTask: Bool
  public let modelIsKnown: Bool

  public init(
    id: String,
    projectID: String? = nil,
    preview: String,
    projectName: String,
    source: String,
    model: String,
    status: PresentationStatus,
    updatedAt: Date,
    isOccupied: Bool,
    canArchive: Bool = false,
    canOpenInCodex: Bool = true,
    canReadHistory: Bool = true,
    canContinue: Bool = true,
    canCreateTask: Bool = true,
    modelIsKnown: Bool = true
  ) {
    self.id = id
    self.projectID = projectID
    self.preview = preview
    self.projectName = projectName
    self.source = source
    self.model = model
    self.status = status
    self.updatedAt = updatedAt
    self.isOccupied = isOccupied
    self.canArchive = canArchive
    self.canOpenInCodex = canOpenInCodex
    self.canReadHistory = canReadHistory
    self.canContinue = canContinue
    self.canCreateTask = canCreateTask
    self.modelIsKnown = modelIsKnown
  }
}

public struct ThreadProjectOptionPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct ThreadHistoryEntryPresentation: Identifiable, Equatable, Sendable {
  public let id: String
  public let turnID: String
  public let role: String
  public let text: String
  public let status: String?

  public init(id: String, turnID: String, role: String, text: String, status: String? = nil) {
    self.id = id
    self.turnID = turnID
    self.role = role
    self.text = text
    self.status = status
  }
}

public struct ThreadHistoryPresentation: Equatable, Sendable {
  public let projectID: String
  public let threadID: String
  public let title: String
  public let entries: [ThreadHistoryEntryPresentation]
  public let canLoadMore: Bool
  public let isLoadingMore: Bool
  public let isTruncated: Bool

  public init(
    projectID: String,
    threadID: String,
    title: String,
    entries: [ThreadHistoryEntryPresentation],
    canLoadMore: Bool,
    isLoadingMore: Bool = false,
    isTruncated: Bool = false
  ) {
    self.projectID = projectID
    self.threadID = threadID
    self.title = title
    self.entries = entries
    self.canLoadMore = canLoadMore
    self.isLoadingMore = isLoadingMore
    self.isTruncated = isTruncated
  }
}

public struct ThreadPagePresentation: Equatable, Sendable {
  public let threads: [ThreadPresentation]
  public let projectFilterName: String?
  public let projectOptions: [ThreadProjectOptionPresentation]
  public let selectedProjectID: String?
  public let canLoadMoreThreads: Bool
  public let isLoadingMoreThreads: Bool
  public let history: PresentationLoadState<ThreadHistoryPresentation>?
  public let isCatalogLoaded: Bool

  public init(
    threads: [ThreadPresentation],
    projectFilterName: String? = nil,
    projectOptions: [ThreadProjectOptionPresentation] = [],
    selectedProjectID: String? = nil,
    canLoadMoreThreads: Bool = false,
    isLoadingMoreThreads: Bool = false,
    history: PresentationLoadState<ThreadHistoryPresentation>? = nil,
    isCatalogLoaded: Bool = true
  ) {
    self.threads = threads
    self.projectFilterName = projectFilterName
    self.projectOptions = projectOptions
    self.selectedProjectID = selectedProjectID
    self.canLoadMoreThreads = canLoadMoreThreads
    self.isLoadingMoreThreads = isLoadingMoreThreads
    self.history = history
    self.isCatalogLoaded = isCatalogLoaded
  }
}

extension ProjectPresentation {
  var threadCountDisplayValue: String {
    threadCountIsKnown ? String(threadCount) : "未读取"
  }

  var branchDisplayValue: String {
    guard gitFactsKnown else { return "Git 状态未读取" }
    return branch ?? "非 Git 仓库"
  }

  var workingTreeDisplayValue: String {
    guard gitFactsKnown else { return "Git 状态未读取" }
    return isDirty ? "有未提交修改" : "干净"
  }

  var showsDirtyIndicator: Bool {
    gitFactsKnown && isDirty
  }
}

extension ThreadPresentation {
  var modelDisplayValue: String {
    modelIsKnown ? model : "未读取"
  }

  var canContinueNow: Bool {
    canContinue && !isOccupied
  }
}
