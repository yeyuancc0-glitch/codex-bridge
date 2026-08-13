import Foundation

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
  public let verificationCommands: [String]
  public let threadCount: Int
  public let lastTaskTitle: String?
  public let isAvailable: Bool

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
    isAvailable: Bool
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
    self.verificationCommands = verificationCommands
    self.threadCount = threadCount
    self.lastTaskTitle = lastTaskTitle
    self.isAvailable = isAvailable
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
  public let preview: String
  public let projectName: String
  public let source: String
  public let model: String
  public let status: PresentationStatus
  public let updatedAt: Date
  public let isOccupied: Bool
  public let canArchive: Bool

  public init(
    id: String,
    preview: String,
    projectName: String,
    source: String,
    model: String,
    status: PresentationStatus,
    updatedAt: Date,
    isOccupied: Bool,
    canArchive: Bool = false
  ) {
    self.id = id
    self.preview = preview
    self.projectName = projectName
    self.source = source
    self.model = model
    self.status = status
    self.updatedAt = updatedAt
    self.isOccupied = isOccupied
    self.canArchive = canArchive
  }
}

public struct ThreadPagePresentation: Equatable, Sendable {
  public let threads: [ThreadPresentation]
  public let projectFilterName: String?

  public init(threads: [ThreadPresentation], projectFilterName: String? = nil) {
    self.threads = threads
    self.projectFilterName = projectFilterName
  }
}
