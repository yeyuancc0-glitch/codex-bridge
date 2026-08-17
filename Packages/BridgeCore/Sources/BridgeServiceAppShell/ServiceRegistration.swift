import Foundation
import ServiceManagement

public enum BridgeServiceRegistrationStatus: String, CaseIterable, Sendable {
  case notRegistered = "not_registered"
  case enabled
  case requiresApproval = "requires_approval"
  case notFound = "not_found"
}

@MainActor
public protocol BridgeServiceRegistrationManaging: AnyObject {
  var status: BridgeServiceRegistrationStatus { get }

  func register() throws
  func unregister() async throws
  func openSystemSettings()
}

@MainActor
public final class SystemBridgeServiceRegistration: BridgeServiceRegistrationManaging {
  private let service: SMAppService

  public init(plistName: String = "org.codexbridge.service.plist") {
    precondition(!plistName.isEmpty)
    service = SMAppService.agent(plistName: plistName)
  }

  public var status: BridgeServiceRegistrationStatus {
    switch service.status {
    case .notRegistered:
      .notRegistered
    case .enabled:
      .enabled
    case .requiresApproval:
      .requiresApproval
    case .notFound:
      .notFound
    @unknown default:
      .notFound
    }
  }

  public func register() throws {
    try service.register()
  }

  public func unregister() async throws {
    try await service.unregister()
  }

  public func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
