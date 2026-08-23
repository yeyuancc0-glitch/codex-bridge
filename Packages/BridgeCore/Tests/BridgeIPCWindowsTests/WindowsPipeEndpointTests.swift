#if canImport(WinSDK)
  import BridgeIPC
  import BridgeIPCWindows
  import XCTest

  final class WindowsPipeEndpointTests: XCTestCase {
    func testProductionPipeIsScopedToCurrentUserSID() throws {
      let identifier = try WindowsPipeEndpoint.currentUserIdentifier()
      XCTAssertTrue(identifier.hasPrefix("S-1-"))
      XCTAssertEqual(
        try WindowsPipeEndpoint.currentUserPipeName(),
        "\(BridgeServiceIPC.windowsPipeBaseName).\(identifier)"
      )
      XCTAssertEqual(
        try WindowsPipeEndpoint.currentUserPath(),
        "\\\\.\\pipe\\\(BridgeServiceIPC.windowsPipeBaseName).\(identifier)"
      )
    }
  }
#endif
