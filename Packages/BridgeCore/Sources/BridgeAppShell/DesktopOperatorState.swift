import BridgeApplication
import BridgeMCP
import BridgePresentation
import Foundation

enum DesktopOperatorLoad<Value: Equatable & Sendable>: Equatable, Sendable {
  case notLoaded
  case loading
  case ready(Value)
  case failed(String)
}

struct DesktopThreadCatalogPage: Equatable, Sendable {
  let projectID: String
  let projectName: String
  let threads: [MCPThreadSummary]
  let nextCursor: String?
  let isLoadingMore: Bool
  let isTruncated: Bool
}

struct DesktopThreadHistoryPage: Equatable, Sendable {
  let projectID: String
  let thread: MCPThreadSummary
  let entries: [MCPThreadEntry]
  let nextCursor: String?
  let isLoadingMore: Bool
  let isTruncated: Bool
}

struct DesktopLocalTaskComposer: Equatable, Sendable {
  let requestID: String
  let projectID: String
  let threadID: String?
  let models: [MCPModelSummary]
  let isSubmitting: Bool
  let submittedDraft: ReadOnlyTaskDraftPresentation?
}

struct DesktopBackupRestoreState: Equatable, Sendable {
  var lastBackupAt: Date?
  var restoreResult: DesktopRestoreResult?
  var restorePending: Bool
}

struct DesktopOperatorState: Equatable, Sendable {
  var selectedProjectID: String?
  var threads: DesktopOperatorLoad<DesktopThreadCatalogPage> = .notLoaded
  var history: DesktopOperatorLoad<DesktopThreadHistoryPage>?
  var composer: DesktopOperatorLoad<DesktopLocalTaskComposer>?
  var rateLimits: DesktopOperatorLoad<CatalogRateLimitSummary> = .notLoaded
  var backupRestore: DesktopOperatorLoad<DesktopBackupRestoreState> = .notLoaded
  var threadGeneration: UInt64 = 0
  var historyGeneration: UInt64 = 0

  mutating func selectProject(_ projectID: String?) -> UInt64 {
    selectedProjectID = projectID
    threads = .loading
    history = nil
    threadGeneration &+= 1
    historyGeneration &+= 1
    return threadGeneration
  }

  mutating func beginHistory() -> UInt64 {
    history = .loading
    historyGeneration &+= 1
    return historyGeneration
  }

  mutating func removeProjectSelection(_ projectID: String) {
    guard selectedProjectID == projectID else { return }
    selectedProjectID = nil
    threads = .notLoaded
    history = nil
    composer = nil
    threadGeneration &+= 1
    historyGeneration &+= 1
  }

  mutating func rebindProjectSelection(_ projectID: String) {
    guard selectedProjectID == projectID else { return }
    threads = .notLoaded
    history = nil
    composer = nil
    threadGeneration &+= 1
    historyGeneration &+= 1
  }
}
