import BridgeAgentCore
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceManagedAgentProviderDescriptors(
    deadline: ContinuousClock.Instant
  ) async throws -> [AgentProviderDescriptor] {
    try Self.checkDeadline(deadline)
    return try await requiredAgentRegistry().providerDescriptors()
  }

  public func serviceManagedAgentInstallations(
    deadline: ContinuousClock.Instant
  ) async throws -> [ServiceAgentInstallationRecord] {
    try Self.checkDeadline(deadline)
    return try await requiredAgentRegistry().installations()
  }

  public func serviceRegisterManagedAgent(
    _ request: ServiceAgentRegistrationRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentInstallationRecord {
    try Self.checkDeadline(deadline)
    let record = try await requiredAgentRegistry().registerAndProbe(request)
    try Self.checkDeadline(deadline)
    return record
  }

  public func serviceReprobeManagedAgent(
    installationID: AgentInstallationID,
    acceptReplacement: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentInstallationRecord {
    try Self.checkDeadline(deadline)
    let record = try await requiredAgentRegistry().reprobe(
      installationID: installationID,
      acceptReplacement: acceptReplacement
    )
    try Self.checkDeadline(deadline)
    return record
  }

  public func serviceSetManagedAgentEnabled(
    installationID: AgentInstallationID,
    enabled: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentInstallationRecord {
    try Self.checkDeadline(deadline)
    let record = try await requiredAgentRegistry().setEnabled(
      enabled,
      installationID: installationID
    )
    try Self.checkDeadline(deadline)
    return record
  }

  public func serviceRemoveManagedAgent(
    installationID: AgentInstallationID,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    try await requiredAgentRegistry().remove(installationID: installationID)
  }

  func requiredAgentRegistry() throws -> ServiceAgentRegistry {
    guard let agentRegistry else { throw BridgeMCPQueryError.unavailable }
    return agentRegistry
  }
}

extension BridgeServiceApplication {
  /// Local App submission path for agent providers. Mirrors the MCP
  /// `submit_task` semantics: persists as awaiting_local_approval and never
  /// auto-starts.
  public func serviceSubmitAgentTask(
    projectID: String,
    providerID: String,
    installationID: String?,
    model: String?,
    prompt: String,
    deadline: ContinuousClock.Instant
  ) async throws -> (taskID: String, status: String) {
    try Self.checkDeadline(deadline)
    let submission = MCPServiceTaskSubmission(
      projectID: projectID,
      prompt: prompt,
      providerID: providerID,
      installationID: installationID,
      executionModel: model,
      modelOverride: model == nil ? nil : true,
      clientRequestID: "app-\(UUID().uuidString.lowercased())"
    )
    let receipt = try await serviceSubmitTask(
      submission,
      invocationContext: MCPInvocationContext(clientID: MCPClientID(rawValue: "macos.app")),
      deadline: deadline
    )
    return (receipt.taskID, receipt.status)
  }
}

public struct ServiceAgentModelListItem: Codable, Equatable, Sendable {
  public let modelID: String
  public let displayName: String

  public init(modelID: String, displayName: String) {
    self.modelID = modelID
    self.displayName = displayName
  }
}

extension BridgeServiceApplication {
  /// Lists models advertised by the registered provider binary itself
  /// (config providers plus subscription catalogs such as Go/Zen).
  public func serviceListAgentModels(
    installationID: AgentInstallationID,
    deadline: ContinuousClock.Instant
  ) async throws -> [ServiceAgentModelListItem] {
    try Self.checkDeadline(deadline)
    let registry = try requiredAgentRegistry()
    guard
      let record = try await registry.installation(id: installationID),
      record.isSelectable
    else {
      throw BridgeMCPQueryError.unavailable
    }
    return try await Self.runModelsList(
      executable: record.executableIdentity.canonicalPath
    )
  }

  private static func runModelsList(
    executable: String
  ) async throws -> [ServiceAgentModelListItem] {
    try await Task.detached(priority: .userInitiated) {
      try Self.runModelsListSync(executable: executable)
    }.value
  }

  private static func runModelsListSync(
    executable: String
  ) throws -> [ServiceAgentModelListItem] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["models"]
    process.environment = ProcessInfo.processInfo.environment
    process.standardError = Pipe()
    let output = Pipe()
    process.standardOutput = output
    do {
      try process.run()
    } catch {
      throw BridgeMCPQueryError.unavailable
    }
    let collected = OutputCollector()
    output.fileHandleForReading.readabilityHandler = { handle in
      collected.append(handle.availableData)
    }
    let watchdog = Task {
      try? await Task.sleep(for: .seconds(10))
      if process.isRunning {
        process.terminate()
      }
    }
    process.waitUntilExit()
    watchdog.cancel()
    output.fileHandleForReading.readabilityHandler = nil
    collected.append(output.fileHandleForReading.readDataToEndOfFile())
    guard process.terminationStatus == 0 || !collected.data.isEmpty else {
      throw BridgeMCPQueryError.unavailable
    }
    var seen = Set<String>()
    var items: [ServiceAgentModelListItem] = []
    for rawLine in collected.data.split(separator: UInt8(ascii: "\n")) {
      let line = String(decoding: rawLine, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard Self.isValidModelLine(line), seen.insert(line).inserted else { continue }
      items.append(ServiceAgentModelListItem(modelID: line, displayName: line))
      if items.count >= 512 { break }
    }
    guard !items.isEmpty else { throw BridgeMCPQueryError.unavailable }
    return items
  }

  private static func isValidModelLine(_ line: String) -> Bool {
    guard !line.isEmpty, line.utf8.count <= 256 else { return false }
    return line.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "/" || $0 == "_")
    }
  }

  private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    func append(_ chunk: Data) {
      lock.lock()
      defer { lock.unlock() }
      guard storage.count < 1_048_576 else { return }
      storage.append(chunk.prefix(1_048_576 - storage.count))
    }
  }
}

extension BridgeServiceApplication {
  public func serviceOpenCodeDefaultModel(
    deadline: ContinuousClock.Instant
  ) async throws -> String? {
    try Self.checkDeadline(deadline)
    return try await settings.string(for: .openCodeDefaultModel)
  }

  public func serviceSetOpenCodeDefaultModel(
    _ model: String?,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    let validated = try Self.validatedAgentModel(model)
    try await settings.set(validated, for: .openCodeDefaultModel)
  }
}
