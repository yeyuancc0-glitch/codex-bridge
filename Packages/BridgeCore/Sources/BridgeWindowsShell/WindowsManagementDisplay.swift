#if os(Windows)
  import Foundation

  struct WindowsProjectPolicy: Equatable, Sendable {
    let read: String
    let write: String
    let network: String
  }

  struct WindowsProjectManagementDisplay: Equatable, Sendable {
    let rows: [String]
    let selectedIndex: Int?
    let detailText: String
    let policy: WindowsProjectPolicy?
    let registerEnabled: Bool
    let removeEnabled: Bool
    let savePolicyEnabled: Bool
    let statusText: String
  }

  struct WindowsAgentManagementDisplay: Equatable, Sendable {
    let providerRows: [String]
    let providerIDs: [String]
    let selectedProviderIndex: Int?
    let providerDetailText: String
    let providerRequiresConfiguration: Bool
    let installationRows: [String]
    let selectedInstallationIndex: Int?
    let installationDetailText: String
    let registerEnabled: Bool
    let enableEnabled: Bool
    let disableEnabled: Bool
    let reprobeEnabled: Bool
    let acceptReplacementEnabled: Bool
    let removeEnabled: Bool
    let statusText: String
  }

  struct WindowsManagementDisplay: Equatable, Sendable {
    let connectionState: WindowsWorkbenchDisplay.ConnectionState
    let availableAgentCount: Int
    let project: WindowsProjectManagementDisplay
    let agent: WindowsAgentManagementDisplay
  }

  final class ManagementDisplayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WindowsManagementDisplay

    init(value: WindowsManagementDisplay) {
      self.value = value
    }

    func current() -> WindowsManagementDisplay {
      lock.lock()
      defer { lock.unlock() }
      return value
    }

    func store(_ value: WindowsManagementDisplay) {
      lock.lock()
      self.value = value
      lock.unlock()
    }
  }
#endif
