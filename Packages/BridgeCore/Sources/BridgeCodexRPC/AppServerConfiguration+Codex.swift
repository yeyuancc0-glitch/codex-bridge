@preconcurrency import Foundation

extension AppServerConfiguration {
  public static func codex(executableURL: URL? = nil) -> AppServerConfiguration {
    #if os(Windows)
      if let executableURL {
        if let discovered = CodexExecutableResolver().resolve(explicitPath: executableURL.path) {
          return AppServerConfiguration(
            executableURL: URL(fileURLWithPath: discovered),
            arguments: ["app-server", "--stdio"]
          )
        }
        return unavailableWindowsCodexConfiguration(
          reason:
            "The configured Codex app-server executable is unavailable or not a native Windows binary."
        )
      }
      if let discovered = CodexExecutableResolver().resolve() {
        return AppServerConfiguration(
          executableURL: URL(fileURLWithPath: discovered),
          arguments: ["app-server", "--stdio"]
        )
      }
      return unavailableWindowsCodexConfiguration(
        reason:
          "Codex app-server executable was not found in PATH or standard Windows installation locations."
      )
    #else
      if let executableURL {
        return AppServerConfiguration(
          executableURL: executableURL,
          arguments: ["app-server", "--stdio"]
        )
      }
      if let discovered = defaultCodexExecutableURL() {
        return AppServerConfiguration(
          executableURL: discovered,
          arguments: ["app-server", "--stdio"]
        )
      }
      return AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["codex", "app-server", "--stdio"]
      )
    #endif
  }

  #if os(Windows)
    private static func unavailableWindowsCodexConfiguration(reason: String)
      -> AppServerConfiguration
    {
      AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "C:\\CodexBridge\\Unavailable\\codex.exe"),
        arguments: ["app-server", "--stdio"],
        currentDirectoryURL: nil,
        environment: nil,
        maximumProtocolLineBytes: 64 * 1024 * 1024,
        stderrBufferBytes: 64 * 1024,
        launchFailureReason: reason
      )
    }
  #endif

  public static func defaultCodexExecutableURL() -> URL? {
    #if os(Windows)
      guard let path = CodexExecutableResolver().resolve() else { return nil }
      return URL(fileURLWithPath: path)
    #else
      let home = FileManager.default.homeDirectoryForCurrentUser
      let candidates: [URL] = [
        URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
        URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        URL(fileURLWithPath: "/usr/local/bin/codex"),
        home.appendingPathComponent(".local/bin/codex"),
        home.appendingPathComponent(".cargo/bin/codex"),
        home.appendingPathComponent(".npm-global/bin/codex"),
        home.appendingPathComponent(
          "Library/Application Support/codex-plusplus/backup/Codex.app/Contents/Resources/codex"
        ),
      ]
      for candidate in candidates {
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
          return candidate
        }
      }
      return nil
    #endif
  }
}
