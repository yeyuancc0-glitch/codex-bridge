import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import Foundation

struct ServiceCoreFixture {
  let rootURL: URL
  let firstProjectURL: URL
  let secondProjectURL: URL
  let databasePath: String

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-bridge-service-core-tests-" + UUID().uuidString,
      isDirectory: true
    )
    firstProjectURL = rootURL.appendingPathComponent("first-project", isDirectory: true)
    secondProjectURL = rootURL.appendingPathComponent("second-project", isDirectory: true)
    databasePath = rootURL.appendingPathComponent("service.sqlite").path
    try FileManager.default.createDirectory(
      at: firstProjectURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: secondProjectURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

final class ServiceCoreTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
    value = start
  }

  func next() -> Date {
    lock.withLock {
      defer { value = value.addingTimeInterval(1) }
      return value
    }
  }
}

func makeServiceProject(
  id: String,
  rootURL: URL,
  date: Date = Date(timeIntervalSince1970: 1_800_000_000),
  policy: ProjectAccessPolicy = .init()
) throws -> ServiceProjectRecord {
  try ServiceProjectRecord(
    id: ProjectID(rawValue: id),
    name: id,
    root: ServiceRootIdentity(capturing: rootURL),
    accessPolicy: policy,
    createdAt: date,
    updatedAt: date
  )
}

func makeServiceTask(
  id: String,
  projectID: ProjectID,
  date: Date = Date(timeIntervalSince1970: 1_800_000_100),
  source: ServiceTaskSource = .chatGPT,
  clientRequestID: String? = nil,
  prompt: String = "Implement the requested project change.",
  providerID: String = serviceCodexProviderID,
  installationID: String? = nil,
  selectionMode: ServiceAgentSelectionMode = .legacyCodex,
  status: ServiceTaskStatus = .awaitingLocalApproval,
  providerSessionID: String? = nil,
  providerRunID: String? = nil,
  supervisorStatus: ServiceSupervisorStatus = .disabled,
  permissionMode: ServicePermissionMode = .workspaceWrite,
  supervisorModel: String? = nil,
  supervisorEffort: String? = nil,
  accessMode: ServiceAccessMode = .requestApproval,
  fastMode: Bool = false
) throws -> ServiceTaskRecord {
  try ServiceTaskRecord(
    id: TaskID(rawValue: id),
    projectID: projectID,
    source: source,
    clientRequestID: clientRequestID,
    prompt: prompt,
    providerID: providerID,
    installationID: installationID,
    selectionMode: selectionMode,
    executionModel: "codex-model",
    executionEffort: "high",
    supervisorModel: supervisorModel,
    supervisorEffort: supervisorEffort,
    permissionMode: permissionMode,
    networkAllowed: false,
    accessMode: accessMode,
    fastMode: fastMode,
    state: ServiceTaskState(
      providerSessionID: providerSessionID,
      providerRunID: providerRunID,
      status: status,
      supervisorStatus: supervisorStatus
    ),
    createdAt: date,
    updatedAt: date
  )
}

func creationEvent(at date: Date) throws -> ServiceTaskEventDraft {
  try ServiceTaskEventDraft(
    kind: .taskCreated,
    summary: "The task was created.",
    createdAt: date
  )
}
