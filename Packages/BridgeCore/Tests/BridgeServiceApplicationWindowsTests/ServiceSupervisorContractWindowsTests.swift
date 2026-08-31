#if os(Windows)
  import BridgeIPC
  import XCTest

  @testable import BridgeServiceApplication

  final class ServiceSupervisorContractWindowsTests: XCTestCase {
    func testCodexDoesNotAdvertiseSupervisorSupportOnWindows() {
      XCTAssertFalse(ServiceAgentProviderPolicyRegistry.codex.supportsSupervisor)
    }

    func testIPCModelPreferencesDefaultSupervisorStateIsDisabled() {
      let preferences = IPCModelPreferences(
        executionModel: "execution",
        executionEffort: "medium",
        supervisorModel: "supervisor",
        supervisorEffort: "medium"
      )
      XCTAssertFalse(preferences.supervisorEnabled)
    }
  }
#endif
