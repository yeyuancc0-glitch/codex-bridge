import BridgeCodexRPC
import Foundation

public struct CodexSupervisorAuthenticationConfiguration: Sendable {
  public let appServer: AppServerConfiguration
  public let clientInfo: CodexClientInfo
  public let requestTimeoutNanoseconds: UInt64
  public let loginTimeoutNanoseconds: UInt64
  public let pollIntervalNanoseconds: UInt64

  public init(
    appServer: AppServerConfiguration = .codex(),
    clientInfo: CodexClientInfo,
    requestTimeoutNanoseconds: UInt64 = 30_000_000_000,
    loginTimeoutNanoseconds: UInt64 = 300_000_000_000,
    pollIntervalNanoseconds: UInt64 = 1_000_000_000
  ) {
    self.appServer = appServer
    self.clientInfo = clientInfo
    self.requestTimeoutNanoseconds = max(1, requestTimeoutNanoseconds)
    self.loginTimeoutNanoseconds = max(1, loginTimeoutNanoseconds)
    self.pollIntervalNanoseconds = max(1, pollIntervalNanoseconds)
  }
}

public enum CodexSupervisorAuthenticationError: Error, Equatable, LocalizedError, Sendable {
  case invalidHome
  case processFailed
  case accountReadFailed
  case accountTypeUnsupported
  case invalidLoginResponse
  case invalidAuthenticationURL
  case browserRejected
  case loginFailed
  case loginTimedOut

  public var errorDescription: String? {
    switch self {
    case .invalidHome:
      "Supervisor 隔离 HOME 不满足所有者和权限要求。"
    case .processFailed:
      "无法启动 Supervisor 的隔离认证 app-server。"
    case .accountReadFailed:
      "无法通过 Codex account/read 确认 Supervisor 登录状态。"
    case .accountTypeUnsupported:
      "当前 Codex 账号不是可用于 Supervisor 的 ChatGPT 登录。"
    case .invalidLoginResponse:
      "Codex 返回了无法安全处理的登录响应。"
    case .invalidAuthenticationURL:
      "Codex 登录地址不是有效的 HTTPS 地址。"
    case .browserRejected:
      "系统浏览器未能打开 Codex 登录地址。"
    case .loginFailed:
      "Codex ChatGPT 登录未完成。"
    case .loginTimedOut:
      "等待 Codex ChatGPT 登录超时。"
    }
  }
}

/// Performs the only supported credential setup for an isolated Supervisor HOME.
///
/// The app-server owns the credential storage. Bridge never reads, copies, parses,
/// persists, or logs auth files, tokens, cookies, or login URLs. The browser callback
/// is intentionally user-mediated and is invoked at most once per provisioning run.
public actor CodexSupervisorAuthenticationProvisioner {
  private let configuration: CodexSupervisorAuthenticationConfiguration
  private let openAuthenticationURL: @Sendable (URL) async -> Bool

  public init(
    configuration: CodexSupervisorAuthenticationConfiguration,
    openAuthenticationURL: @escaping @Sendable (URL) async -> Bool
  ) {
    self.configuration = configuration
    self.openAuthenticationURL = openAuthenticationURL
  }

  public func ensureAuthenticated(
    homeURL: URL,
    deniedReadRoots: [URL] = []
  ) async throws -> CodexAccount {
    guard EvidenceOnlyProcessBoundary.isPrivateDirectory(homeURL) else {
      throw CodexSupervisorAuthenticationError.invalidHome
    }

    let wrappedConfiguration: AppServerConfiguration
    do {
      wrappedConfiguration = try EvidenceOnlyProcessBoundary.configuration(
        wrapping: configuration.appServer,
        isolatedHomeURL: homeURL,
        deniedReadRoots: deniedReadRoots,
        networkAccess: true
      )
    } catch {
      throw CodexSupervisorAuthenticationError.invalidHome
    }

    let client = CodexAppServerClient(
      configuration: wrappedConfiguration,
      defaultTimeoutNanoseconds: configuration.requestTimeoutNanoseconds,
      eventBufferLimit: 32
    )
    do {
      try await client.start()
      _ = try await client.initialize(clientInfo: configuration.clientInfo)

      if let account = try await authenticatedAccount(using: client) {
        await client.stop()
        return account
      }

      let login = try await startLogin(using: client)
      guard await openAuthenticationURL(login.url) else {
        await cancel(loginID: login.loginID, using: client)
        await client.stop()
        throw CodexSupervisorAuthenticationError.browserRejected
      }

      do {
        try await waitForLoginCompletion(using: client, loginID: login.loginID)
        let account = try await waitForAuthenticatedAccount(using: client)
        await client.stop()
        return account
      } catch {
        await cancel(loginID: login.loginID, using: client)
        await client.stop()
        throw error
      }
    } catch let error as CodexSupervisorAuthenticationError {
      await client.stop()
      throw error
    } catch is CancellationError {
      await client.stop()
      throw CancellationError()
    } catch {
      await client.stop()
      throw CodexSupervisorAuthenticationError.processFailed
    }
  }

  private func authenticatedAccount(using client: CodexAppServerClient) async throws
    -> CodexAccount?
  {
    let response: GetAccountResponse
    do {
      response = try await client.readAccount(GetAccountParams(refreshToken: false))
    } catch {
      throw CodexSupervisorAuthenticationError.accountReadFailed
    }
    guard !response.requiresOpenaiAuth, let account = response.account else { return nil }
    guard account.type.lowercased() == "chatgpt" else {
      throw CodexSupervisorAuthenticationError.accountTypeUnsupported
    }
    return account
  }

  private func startLogin(using client: CodexAppServerClient) async throws -> LoginRequest {
    let response: StartChatGPTLoginResponse
    do {
      response = try await client.startChatGPTLogin()
    } catch {
      throw CodexSupervisorAuthenticationError.loginFailed
    }
    guard response.type == "chatgpt",
      let loginID = response.loginId,
      Self.isSafeIdentifier(loginID, maximumBytes: 1_024)
    else {
      throw CodexSupervisorAuthenticationError.invalidLoginResponse
    }
    guard let rawURL = response.authUrl,
      let url = Self.authenticationURL(rawURL)
    else {
      throw CodexSupervisorAuthenticationError.invalidAuthenticationURL
    }
    return LoginRequest(loginID: loginID, url: url)
  }

  private func waitForLoginCompletion(
    using client: CodexAppServerClient,
    loginID: String
  ) async throws {
    let events = client.events
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await event in events {
          guard case .notification(let notification) = event,
            notification.method == "account/login/completed"
          else { continue }
          let decoded: CodexAccountNotification
          do {
            decoded = try notification.decodedCodexAccountNotification()
          } catch {
            throw CodexSupervisorAuthenticationError.processFailed
          }
          guard case .loginCompleted(let completion) = decoded else {
            throw CodexSupervisorAuthenticationError.processFailed
          }
          guard completion.loginId == loginID else {
            continue
          }
          guard completion.success else {
            throw CodexSupervisorAuthenticationError.loginFailed
          }
          return
        }
        throw CodexSupervisorAuthenticationError.processFailed
      }
      group.addTask {
        try await Task.sleep(nanoseconds: self.configuration.loginTimeoutNanoseconds)
        throw CodexSupervisorAuthenticationError.loginTimedOut
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }

  private func waitForAuthenticatedAccount(using client: CodexAppServerClient) async throws
    -> CodexAccount
  {
    for attempt in 0..<5 {
      if let account = try await authenticatedAccount(using: client) {
        return account
      }
      if attempt < 4 {
        try await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
      }
    }
    throw CodexSupervisorAuthenticationError.accountReadFailed
  }

  private func cancel(loginID: String, using client: CodexAppServerClient) async {
    _ = try? await client.cancelLogin(CancelLoginParams(loginId: loginID))
  }

  private static func authenticationURL(_ rawValue: String) -> URL? {
    guard rawValue.utf8.count <= 4_096,
      let url = URL(string: rawValue),
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      let host = components.host,
      !host.isEmpty,
      ["auth.openai.com", "chatgpt.com", "www.chatgpt.com"].contains(host.lowercased()),
      components.user == nil,
      components.password == nil
    else { return nil }
    return url
  }

  private static func isSafeIdentifier(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && value.utf8.count <= maximumBytes
      && !value.contains("\0")
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }

  private struct LoginRequest: Sendable {
    let loginID: String
    let url: URL
  }
}
