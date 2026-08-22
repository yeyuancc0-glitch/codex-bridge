import BridgeProcessRuntime
import Foundation

public struct AppServerConfiguration: Equatable, Sendable {
  public let executableURL: URL
  public let arguments: [String]
  public let currentDirectoryURL: URL?
  public let environment: [String: String]?
  public let maximumProtocolLineBytes: Int
  public let stderrBufferBytes: Int

  let launchFailureReason: String?

  public init(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL? = nil,
    environment: [String: String]? = nil,
    maximumProtocolLineBytes: Int = 8 * 1024 * 1024,
    stderrBufferBytes: Int = 64 * 1024
  ) {
    self.init(
      executableURL: executableURL,
      arguments: arguments,
      currentDirectoryURL: currentDirectoryURL,
      environment: environment,
      maximumProtocolLineBytes: maximumProtocolLineBytes,
      stderrBufferBytes: stderrBufferBytes,
      launchFailureReason: nil
    )
  }

  private init(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL?,
    environment: [String: String]?,
    maximumProtocolLineBytes: Int,
    stderrBufferBytes: Int,
    launchFailureReason: String?
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.currentDirectoryURL = currentDirectoryURL
    self.environment = environment
    self.maximumProtocolLineBytes = max(1, maximumProtocolLineBytes)
    self.stderrBufferBytes = max(0, stderrBufferBytes)
    self.launchFailureReason = launchFailureReason
  }

  public static func codex(executableURL: URL? = nil) -> AppServerConfiguration {
    #if canImport(WinSDK)
      let resolver = CodexExecutableResolver()
      if let resolved = resolver.resolve(explicitURL: executableURL) {
        return AppServerConfiguration(
          executableURL: resolved,
          arguments: ["app-server", "--stdio"]
        )
      }
      let requested = executableURL?.path ?? "the standard Codex installation locations"
      return AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "C:\\CodexBridge\\Missing\\codex.exe"),
        arguments: ["app-server", "--stdio"],
        currentDirectoryURL: nil,
        environment: nil,
        maximumProtocolLineBytes: 8 * 1024 * 1024,
        stderrBufferBytes: 64 * 1024,
        launchFailureReason: "Unable to resolve a trusted native codex.exe from \(requested)"
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

  public static func defaultCodexExecutableURL() -> URL? {
    #if canImport(WinSDK)
      return CodexExecutableResolver().resolve()
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
      return candidates.first {
        FileManager.default.isExecutableFile(atPath: $0.path)
      }
    #endif
  }
}

actor AppServerStderrBuffer {
  private let limit: Int
  private var data = Data()

  init(limit: Int) {
    self.limit = limit
  }

  func append(_ chunk: Data) {
    guard limit > 0, !chunk.isEmpty else { return }
    if chunk.count >= limit {
      data = Data(chunk.suffix(limit))
      return
    }

    data.append(chunk)
    let overflow = data.count - limit
    if overflow > 0 {
      data.removeFirst(overflow)
    }
  }

  func snapshot() -> Data {
    data
  }
}
