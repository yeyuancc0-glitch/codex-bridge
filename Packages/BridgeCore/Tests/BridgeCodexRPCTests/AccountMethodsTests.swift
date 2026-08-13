import Foundation
import XCTest

@testable import BridgeCodexRPC

final class AccountMethodsTests: XCTestCase {
  func testAccountLoginAndRateLimitMethodsMatchStableWire() async throws {
    let client = makeClient(
      script: #"""
        IFS= read -r initialize
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake/1","codexHome":"/private/fake","platformFamily":"unix","platformOs":"macos"}}'
        IFS= read -r initialized

        IFS= read -r account_read
        valid=1
        case "$account_read" in *'"method":"account/read"'*) ;; *) valid=0 ;; esac
        case "$account_read" in *'"refreshToken":false'*) ;; *) valid=0 ;; esac
        printf '%s\n' '{"method":"account/updated","params":{"authMode":"chatgpt","planType":"pro","futureField":true}}'
        if [ "$valid" -eq 1 ]; then
          printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"person@example.com","planType":"pro","futureField":true},"requiresOpenaiAuth":true,"futureField":true}}'
        else
          printf '%s\n' '{"id":2,"error":{"code":-1,"message":"invalid account/read"}}'
        fi

        IFS= read -r login_start
        valid=1
        case "$login_start" in *'"method":"account/login/start"'*) ;; *) valid=0 ;; esac
        case "$login_start" in *'"type":"chatgpt"'*) ;; *) valid=0 ;; esac
        if [ "$valid" -eq 1 ]; then
          printf '%s\n' '{"id":3,"result":{"type":"chatgpt","loginId":"login-1","authUrl":"https://auth.example.test/login","futureField":true}}'
        else
          printf '%s\n' '{"id":3,"error":{"code":-1,"message":"invalid account/login/start"}}'
        fi
        printf '%s\n' '{"method":"account/login/completed","params":{"success":true,"loginId":"login-1","error":null,"futureField":true}}'

        IFS= read -r login_cancel
        valid=1
        case "$login_cancel" in *'"method":"account/login/cancel"'*) ;; *) valid=0 ;; esac
        case "$login_cancel" in *'"loginId":"login-1"'*) ;; *) valid=0 ;; esac
        if [ "$valid" -eq 1 ]; then
          printf '%s\n' '{"id":4,"result":{"status":"notFound","futureField":true}}'
        else
          printf '%s\n' '{"id":4,"error":{"code":-1,"message":"invalid account/login/cancel"}}'
        fi

        IFS= read -r rate_limits
        valid=1
        case "$rate_limits" in *'"method":"account/rateLimits/read"'*) ;; *) valid=0 ;; esac
        case "$rate_limits" in *'"params":{}'*) ;; *) valid=0 ;; esac
        if [ "$valid" -eq 1 ]; then
          printf '%s\n' '{"id":5,"result":{"rateLimits":{"limitId":"codex","limitName":"Codex","planType":"pro","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1000},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"5"},"rateLimitReachedType":null,"spendControlReached":false,"futureField":true},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":12}}},"rateLimitResetCredits":null,"futureField":true}}'
        else
          printf '%s\n' '{"id":5,"error":{"code":-1,"message":"invalid account/rateLimits/read"}}'
        fi
        printf '%s\n' '{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":13}},"futureField":true}}'
        sleep 2
        """#
    )
    addTeardownBlock { await client.stop() }
    try await client.start()
    _ = try await client.initialize(clientInfo: .bridge(version: "0.1.0"))
    var events = client.events.makeAsyncIterator()

    let account = try await client.readAccount()
    XCTAssertEqual(account.account?.type, "chatgpt")
    XCTAssertEqual(account.account?.planType, "pro")
    XCTAssertTrue(account.requiresOpenaiAuth)

    let login = try await client.startChatGPTLogin()
    XCTAssertEqual(login.type, "chatgpt")
    XCTAssertEqual(login.loginId, "login-1")
    XCTAssertEqual(login.authUrl, "https://auth.example.test/login")

    let cancellation = try await client.cancelLogin(CancelLoginParams(loginId: "login-1"))
    XCTAssertEqual(cancellation.status, "notFound")

    let limits = try await client.readAccountRateLimits()
    XCTAssertEqual(limits.rateLimits.primary?.usedPercent, 12)
    XCTAssertEqual(limits.rateLimitsByLimitId?["codex"]?.limitId, "codex")

    guard case .notification(let accountEvent)? = await events.next() else {
      return XCTFail("Expected account/updated notification")
    }
    guard case .accountUpdated(let update) = try accountEvent.decodedCodexAccountNotification()
    else {
      return XCTFail("Expected typed account update")
    }
    XCTAssertEqual(update.authMode, "chatgpt")
    XCTAssertEqual(update.planType, "pro")

    guard case .notification(let loginEvent)? = await events.next() else {
      return XCTFail("Expected account/login/completed notification")
    }
    guard
      case .loginCompleted(let completion) =
        try loginEvent.decodedCodexAccountNotification()
    else {
      return XCTFail("Expected typed login completion")
    }
    XCTAssertTrue(completion.success)
    XCTAssertEqual(completion.loginId, "login-1")

    guard case .notification(let limitsEvent)? = await events.next() else {
      return XCTFail("Expected account/rateLimits/updated notification")
    }
    guard
      case .rateLimitsUpdated(let update) =
        try limitsEvent.decodedCodexAccountNotification()
    else {
      return XCTFail("Expected typed rate-limit update")
    }
    XCTAssertEqual(update.rateLimits.primary?.usedPercent, 13)
  }

  func testUnknownAccountNotificationRemainsLossless() throws {
    let raw = RPCNotification(
      method: "account/future",
      params: .object(["future": .bool(true)]),
      metadata: ["trace": .string("kept")]
    )

    XCTAssertEqual(try raw.decodedCodexAccountNotification(), .unknown(raw))
  }

  private func makeClient(script: String) -> CodexAppServerClient {
    CodexAppServerClient(
      configuration: AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script]
      ),
      defaultTimeoutNanoseconds: 1_000_000_000
    )
  }
}
