import BridgeDomain
import BridgeServiceCore
import Foundation

public enum LegacyImportStatus: String, Equatable, Sendable {
  case noSource
  case imported
  case alreadyCompleted
}

public struct LegacyProjectReduction: Equatable, Hashable, Sendable {
  public let projectID: ProjectID
  public let omittedWorktreeCount: Int
  public let repositoryRootWasDifferent: Bool

  public init(
    projectID: ProjectID,
    omittedWorktreeCount: Int,
    repositoryRootWasDifferent: Bool
  ) {
    self.projectID = projectID
    self.omittedWorktreeCount = omittedWorktreeCount
    self.repositoryRootWasDifferent = repositoryRootWasDifferent
  }
}

public struct LegacyImportReport: Equatable, Sendable {
  public let status: LegacyImportStatus
  public let sourceFound: Bool
  public let insertedProjectIDs: [ProjectID]
  public let existingProjectIDs: [ProjectID]
  public let reducedProjects: [LegacyProjectReduction]
  public let insertedSettingKeys: [String]
  public let existingSettingKeys: [String]

  public init(
    status: LegacyImportStatus,
    sourceFound: Bool,
    insertedProjectIDs: [ProjectID] = [],
    existingProjectIDs: [ProjectID] = [],
    reducedProjects: [LegacyProjectReduction] = [],
    insertedSettingKeys: [String] = [],
    existingSettingKeys: [String] = []
  ) {
    self.status = status
    self.sourceFound = sourceFound
    self.insertedProjectIDs = insertedProjectIDs
    self.existingProjectIDs = existingProjectIDs
    self.reducedProjects = reducedProjects
    self.insertedSettingKeys = insertedSettingKeys
    self.existingSettingKeys = existingSettingKeys
  }
}

public enum LegacyImportError: Error, Equatable, LocalizedError, Sendable {
  case insecureSourceDirectory
  case insecureSourceFile(String)
  case unsupportedRepositorySchema
  case unsupportedProject(ProjectID)
  case corruptRepository
  case corruptOnboardingState
  case projectLimitExceeded
  case readFailed

  public var errorDescription: String? {
    switch self {
    case .insecureSourceDirectory:
      "The legacy Codex Bridge directory is not a private user-owned directory."
    case .insecureSourceFile(let name):
      "The legacy Codex Bridge file is not safe to read: \(name)."
    case .unsupportedRepositorySchema:
      "The legacy project repository schema is unsupported."
    case .unsupportedProject:
      "A legacy project cannot be represented by the lightweight Service."
    case .corruptRepository:
      "The legacy project repository is corrupt."
    case .corruptOnboardingState:
      "The legacy onboarding state is corrupt."
    case .projectLimitExceeded:
      "The legacy repository contains too many projects to import safely."
    case .readFailed:
      "The legacy Codex Bridge configuration could not be read."
    }
  }
}

struct LegacySourceSnapshot: Sendable {
  let sourceFound: Bool
  let projects: [ServiceProjectRecord]
  let settings: [ServiceSettingRecord]
  let reducedProjects: [LegacyProjectReduction]
}
