import AppKit
import BridgeMCP
import Foundation
import BridgeServiceAppCore

extension BridgeServiceAppModel {
  public func setQwenStudioEnabled(_ enabled: Bool) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.setMCPClientEnabled(
        clientID: MCPClientID.qwenStudio.rawValue,
        enabled: enabled
      )
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast(enabled ? "已启用 Qwen Studio 客户端" : "已停用 Qwen Studio 客户端")
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
      self.postToast("Qwen 工具权限已设置为：\(mode.localizedTitle)")
    }
  }

  public func copyQwenStudioConfiguration() {
    runMutation { [weak self] client in
      let configuration = try await client.exportMCPClientConfiguration(
        clientID: MCPClientID.qwenStudio.rawValue
      )
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(configuration, forType: .string)
      self?.postToast("已复制 Qwen Studio JSON 配置")
    }
  }

  public func rotateQwenStudioCredential() {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.rotateMCPClientCredential(
        clientID: MCPClientID.qwenStudio.rawValue
      )
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("已重新生成 Qwen 凭证")
    }
  }

  public func rotateLocalMCPEndpoint() {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.rotateLocalMCPEndpoint()
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("已重新生成本地 MCP Endpoint")
    }
  }
}
