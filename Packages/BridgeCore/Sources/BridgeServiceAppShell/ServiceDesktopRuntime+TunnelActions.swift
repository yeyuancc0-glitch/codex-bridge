import BridgeIPC

extension BridgeServiceAppModel {
  public func configureTunnel(tunnelID: String, runtimeKey: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.configureTunnel(
        IPCTunnelConfigurationRequest(
          tunnelID: tunnelID,
          runtimeKey: runtimeKey
        )
      )
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("Secure Tunnel 配置已提交，正在启动连接…")
    }
  }

  public func connectTunnel() {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.connectTunnel()
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("正在连接 Secure Tunnel…")
    }
  }

  public func disconnectTunnel() {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.disconnectTunnel()
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("Secure Tunnel 已断开连接", symbol: "link.badge.plus", tone: .neutral)
    }
  }

  public func clearTunnel() {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.clearTunnel()
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("已清除 Secure Tunnel 配置", symbol: "trash", tone: .neutral)
    }
  }
}
