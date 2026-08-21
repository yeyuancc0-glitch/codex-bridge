import AppKit
import BridgeMCP
import Foundation

extension BridgeServiceAppModel {
  public func setQwenStudioEnabled(_ enabled: Bool) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.setMCPClientEnabled(
        clientID: MCPClientID.qwenStudio.rawValue,
        enabled: enabled
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func setQwenStudioExposureMode(_ mode: MCPServiceExposureMode) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.setMCPClientExposureMode(
        clientID: MCPClientID.qwenStudio.rawValue,
        mode: mode
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func copyQwenStudioConfiguration() {
    runMutation { client in
      let configuration = try await client.exportMCPClientConfiguration(
        clientID: MCPClientID.qwenStudio.rawValue
      )
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(configuration, forType: .string)
    }
  }

  public func rotateQwenStudioCredential() {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.rotateMCPClientCredential(
        clientID: MCPClientID.qwenStudio.rawValue
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func rotateLocalMCPEndpoint() {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.rotateLocalMCPEndpoint()
      await self.refresh(silent: true, includeCatalog: false)
    }
  }
}
