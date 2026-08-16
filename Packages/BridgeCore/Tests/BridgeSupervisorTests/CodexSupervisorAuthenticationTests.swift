import BridgeCodexRPC
import Foundation
import XCTest

@testable import BridgeSupervisor

final class CodexSupervisorAuthenticationTests: XCTestCase {
  func testUserMediatedLoginUsesOfficialAccountMethodsAndIsolatedHome() async throws {
    let home = try privateHome()
    let opened = OpenURLRecorder()
    let provisioner = CodexSupervisorAuthenticationProvisioner(
      configuration: CodexSupervisorAuthenticationConfiguration(
        appServer: fixtureConfiguration(script: loginScript),
        clientInfo: .bridge(version: "auth-tests"),
        requestTimeoutNanoseconds: 1_000_000_000,
        loginTimeoutNanoseconds: 2_000_000_000,
        pollIntervalNanoseconds: 10_000_000
      ),
      openAuthenticationURL: { url in await opened.open(url) }
    )

    let account = try await provisioner.ensureAuthenticated(homeURL: home)
    let openedURLs = await opened.values()

    XCTAssertEqual(account.type, "chatgpt")
    XCTAssertEqual(account.email, "user@example.com")
    XCTAssertEqual(openedURLs, [URL(string: "https://auth.openai.com/device")!])
  }

  func testAlreadyAuthenticatedAccountDoesNotOpenBrowser() async throws {
    let home = try privateHome()
    let opened = OpenURLRecorder()
    let provisioner = CodexSupervisorAuthenticationProvisioner(
      configuration: CodexSupervisorAuthenticationConfiguration(
        appServer: fixtureConfiguration(script: authenticatedScript),
        clientInfo: .bridge(version: "auth-tests"),
        requestTimeoutNanoseconds: 1_000_000_000
      ),
      openAuthenticationURL: { url in await opened.open(url) }
    )

    let account = try await provisioner.ensureAuthenticated(homeURL: home)
    let openedURLs = await opened.values()

    XCTAssertEqual(account.type, "chatgpt")
    XCTAssertTrue(openedURLs.isEmpty)
  }

  func testUnsafeLoginURLFailsClosedBeforeOpeningBrowser() async throws {
    let home = try privateHome()
    let opened = OpenURLRecorder()
    let provisioner = CodexSupervisorAuthenticationProvisioner(
      configuration: CodexSupervisorAuthenticationConfiguration(
        appServer: fixtureConfiguration(script: unsafeURLScript),
        clientInfo: .bridge(version: "auth-tests"),
        requestTimeoutNanoseconds: 1_000_000_000
      ),
      openAuthenticationURL: { url in await opened.open(url) }
    )

    do {
      _ = try await provisioner.ensureAuthenticated(homeURL: home)
      XCTFail("Expected unsafe URL rejection")
    } catch CodexSupervisorAuthenticationError.invalidAuthenticationURL {
      // Expected.
    }
    let openedURLs = await opened.values()
    XCTAssertTrue(openedURLs.isEmpty)
  }

  func testBrowserRejectionFailsClosed() async throws {
    let home = try privateHome()
    let opened = OpenURLRecorder()
    let provisioner = CodexSupervisorAuthenticationProvisioner(
      configuration: CodexSupervisorAuthenticationConfiguration(
        appServer: fixtureConfiguration(script: loginScript),
        clientInfo: .bridge(version: "auth-tests"),
        requestTimeoutNanoseconds: 1_000_000_000
      ),
      openAuthenticationURL: { url in
        _ = await opened.open(url)
        return false
      }
    )

    do {
      _ = try await provisioner.ensureAuthenticated(homeURL: home)
      XCTFail("Expected browser rejection")
    } catch CodexSupervisorAuthenticationError.browserRejected {
      // Expected.
    }
    let openedURLs = await opened.values()
    XCTAssertEqual(openedURLs, [URL(string: "https://auth.openai.com/device")!])
  }

  func testFailedMatchingLoginCompletionFailsClosed() async throws {
    let home = try privateHome()
    let opened = OpenURLRecorder()
    let provisioner = CodexSupervisorAuthenticationProvisioner(
      configuration: CodexSupervisorAuthenticationConfiguration(
        appServer: fixtureConfiguration(script: failedLoginScript),
        clientInfo: .bridge(version: "auth-tests"),
        requestTimeoutNanoseconds: 1_000_000_000,
        loginTimeoutNanoseconds: 1_000_000_000
      ),
      openAuthenticationURL: { url in await opened.open(url) }
    )

    do {
      _ = try await provisioner.ensureAuthenticated(homeURL: home)
      XCTFail("Expected login failure")
    } catch CodexSupervisorAuthenticationError.loginFailed {
      // Expected.
    }
    let openedURLs = await opened.values()
    XCTAssertEqual(openedURLs.count, 1)
  }

  func testCompletionWithoutMatchingLoginIDTimesOut() async throws {
    let home = try privateHome()
    let opened = OpenURLRecorder()
    let provisioner = CodexSupervisorAuthenticationProvisioner(
      configuration: CodexSupervisorAuthenticationConfiguration(
        appServer: fixtureConfiguration(script: mismatchedOnlyLoginScript),
        clientInfo: .bridge(version: "auth-tests"),
        requestTimeoutNanoseconds: 1_000_000_000,
        loginTimeoutNanoseconds: 50_000_000,
        pollIntervalNanoseconds: 1_000_000
      ),
      openAuthenticationURL: { url in await opened.open(url) }
    )

    do {
      _ = try await provisioner.ensureAuthenticated(homeURL: home)
      XCTFail("Expected login timeout")
    } catch CodexSupervisorAuthenticationError.loginTimedOut {
      // Expected.
    }
    let openedURLs = await opened.values()
    XCTAssertEqual(openedURLs.count, 1)
  }

  private func privateHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "bridge-supervisor-auth-home-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: home,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: home) }
    return home
  }

  private func fixtureConfiguration(script: String) -> AppServerConfiguration {
    AppServerConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", script],
      environment: ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
    )
  }

  private var loginScript: String {
    #"""
    IFS= read -r initialize
    printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
    IFS= read -r initialized
    IFS= read -r account_read
    printf '%s\n' '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}'
    IFS= read -r login_start
    printf '%s\n' '{"id":3,"result":{"type":"chatgpt","loginId":"login-1","authUrl":"https://auth.openai.com/device"}}'
    printf '%s\n' '{"method":"account/login/completed","params":{"success":true,"loginId":"other-login"}}'
    printf '%s\n' '{"method":"account/login/completed","params":{"success":true,"loginId":"login-1"}}'
    IFS= read -r account_read_after_login
    printf '%s\n' '{"id":4,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"plus","usesCodexManagedCredentials":true},"requiresOpenaiAuth":false}}'
    sleep 1
    """#
  }

  private var authenticatedScript: String {
    #"""
    IFS= read -r initialize
    printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
    IFS= read -r initialized
    IFS= read -r account_read
    printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"already@example.com","planType":"plus","usesCodexManagedCredentials":true},"requiresOpenaiAuth":false}}'
    sleep 1
    """#
  }

  private var unsafeURLScript: String {
    #"""
    IFS= read -r initialize
    printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
    IFS= read -r initialized
    IFS= read -r account_read
    printf '%s\n' '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}'
    IFS= read -r login_start
    printf '%s\n' '{"id":3,"result":{"type":"chatgpt","loginId":"login-1","authUrl":"http://localhost/callback"}}'
    sleep 1
    """#
  }

  private var failedLoginScript: String {
    #"""
    IFS= read -r initialize
    printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
    IFS= read -r initialized
    IFS= read -r account_read
    printf '%s\n' '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}'
    IFS= read -r login_start
    printf '%s\n' '{"id":3,"result":{"type":"chatgpt","loginId":"login-1","authUrl":"https://auth.openai.com/device"}}'
    printf '%s\n' '{"method":"account/login/completed","params":{"success":false,"loginId":"login-1","error":"cancelled"}}'
    sleep 1
    """#
  }

  private var mismatchedOnlyLoginScript: String {
    #"""
    IFS= read -r initialize
    printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
    IFS= read -r initialized
    IFS= read -r account_read
    printf '%s\n' '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}'
    IFS= read -r login_start
    printf '%s\n' '{"id":3,"result":{"type":"chatgpt","loginId":"login-1","authUrl":"https://auth.openai.com/device"}}'
    printf '%s\n' '{"method":"account/login/completed","params":{"success":true,"loginId":"other-login"}}'
    sleep 1
    """#
  }
}

private actor OpenURLRecorder {
  private var recorded: [URL] = []

  func open(_ url: URL) -> Bool {
    recorded.append(url)
    return true
  }

  func values() -> [URL] { recorded }
}
