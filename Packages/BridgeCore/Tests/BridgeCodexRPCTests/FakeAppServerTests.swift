import Darwin
import Foundation
import XCTest

@testable import BridgeCodexRPC

final class FakeAppServerTests: XCTestCase {
  func testReassemblesFragmentedResponse() async throws {
    let client = makeClient(
      script: #"""
        IFS= read -r request
        printf '%s' '{"id":1,"res'
        sleep 0.05
        printf '%s\n' 'ult":{"ok":true}}'
        sleep 2
        """#
    )
    addTeardownBlock { await client.stop() }
    try await client.start()

    let response = try await client.performRequest(
      method: "test/fragmented",
      params: .object([:])
    )

    XCTAssertEqual(response.objectValue?["ok"], .bool(true))
  }

  func testConcurrentOutOfOrderResponsesAndEarlyNotification() async throws {
    let client = makeClient(
      script: #"""
        IFS= read -r first
        IFS= read -r second
        id1=$(printf '%s' "$first" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
        id2=$(printf '%s' "$second" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
        method1=$(printf '%s' "$first" | /usr/bin/sed -E 's/.*"method":"([^"]+)".*/\1/')
        method2=$(printf '%s' "$second" | /usr/bin/sed -E 's/.*"method":"([^"]+)".*/\1/')
        printf '%s\n' '{"method":"future/notification","params":{"phase":"before"},"futureMetadata":7}'
        printf '{"id":%s,"result":{"method":"%s"}}\n' "$id2" "$method2"
        printf '{"id":%s,"result":{"method":"%s"}}\n' "$id1" "$method1"
        sleep 2
        """#
    )
    addTeardownBlock { await client.stop() }
    try await client.start()
    var events = client.events.makeAsyncIterator()

    async let first = client.performRequest(
      method: "test/first", params: .object([:]))
    async let second = client.performRequest(
      method: "test/second", params: .object([:]))

    guard case .notification(let notification)? = await events.next() else {
      return XCTFail("Expected a notification before the responses")
    }
    XCTAssertEqual(notification.method, "future/notification")
    XCTAssertEqual(notification.metadata["futureMetadata"], .integer(7))

    let firstResponse = try await first
    let secondResponse = try await second
    XCTAssertEqual(firstResponse.objectValue?["method"], .string("test/first"))
    XCTAssertEqual(secondResponse.objectValue?["method"], .string("test/second"))
  }

  func testStringIDServerRequestCanBeAnswered() async throws {
    let client = makeClient(
      script: #"""
        IFS= read -r request
        printf '%s\n' '{"id":"approval-7","method":"future/requestApproval","params":{"scope":"test"},"futureMetadata":9}'
        IFS= read -r reply
        valid=1
        case "$reply" in *'"id":"approval-7"'*) ;; *) valid=0 ;; esac
        case "$reply" in *'"result"'*) ;; *) valid=0 ;; esac
        printf '{"id":1,"result":{"valid":%s}}\n' "$([ "$valid" -eq 1 ] && printf true || printf false)"
        sleep 2
        """#
    )
    addTeardownBlock { await client.stop() }
    try await client.start()
    var events = client.events.makeAsyncIterator()

    let responseTask = Task {
      try await client.performRequest(
        method: "test/waiting", params: .object([:]))
    }
    guard case .serverRequest(let request)? = await events.next() else {
      return XCTFail("Expected a server request")
    }

    XCTAssertEqual(request.id, .string("approval-7"))
    XCTAssertEqual(request.method, "future/requestApproval")
    XCTAssertEqual(request.params?.objectValue?["scope"], .string("test"))
    XCTAssertEqual(request.metadata["futureMetadata"], .integer(9))

    try await client.performResponse(
      to: request.id, result: .object(["decision": .string("decline")]))
    let response = try await responseTask.value
    XCTAssertEqual(response.objectValue?["valid"], .bool(true))
  }

  func testRequestTimesOutOnceAndIgnoresLateResponse() async throws {
    let client = makeClient(
      script: #"""
        IFS= read -r request
        sleep 0.15
        printf '%s\n' '{"id":1,"result":{"late":true}}'
        sleep 2
        """#,
      timeoutNanoseconds: 30_000_000
    )
    addTeardownBlock { await client.stop() }
    try await client.start()

    do {
      _ = try await client.performRequest(
        method: "test/timeout", params: .object([:]))
      XCTFail("Expected timeout")
    } catch {
      XCTAssertEqual(error as? CodexRPCError, .timeout(method: "test/timeout"))
    }

    try await Task.sleep(nanoseconds: 200_000_000)
  }

  func testCancellationRemovesPendingRequestBeforeLateResponse() async throws {
    let client = makeClient(
      script: #"""
        IFS= read -r request
        sleep 0.15
        printf '%s\n' '{"id":1,"result":{"late":true}}'
        sleep 2
        """#
    )
    addTeardownBlock { await client.stop() }
    try await client.start()

    let task = Task {
      try await client.performRequest(
        method: "test/cancel", params: .object([:]))
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }

    try await Task.sleep(nanoseconds: 200_000_000)
  }

  func testProcessExitFailsPendingRequest() async throws {
    let client = makeClient(
      script: #"""
        IFS= read -r request
        exit 23
        """#
    )
    addTeardownBlock { await client.stop() }
    try await client.start()

    do {
      _ = try await client.performRequest(
        method: "test/exit", params: .object([:]))
      XCTFail("Expected process exit")
    } catch {
      XCTAssertEqual(error as? CodexRPCError, .processExited(23))
    }
  }

  func testStdoutContaminationFailsPendingRequest() async throws {
    let client = makeClient(
      script: #"""
        IFS= read -r request
        printf '%s\n' 'debug output on stdout'
        sleep 2
        """#
    )
    addTeardownBlock { await client.stop() }
    try await client.start()

    do {
      _ = try await client.performRequest(
        method: "test/contamination", params: .object([:]))
      XCTFail("Expected stdout contamination failure")
    } catch {
      XCTAssertEqual(
        error as? CodexRPCError,
        .protocolContamination("debug output on stdout")
      )
    }
  }

  func testInitializeModelListAndBoundedStderr() async throws {
    let client = makeClient(
      script: #"""
        IFS= read -r initialize
        valid=1
        case "$initialize" in *'"experimentalApi":false'*) ;; *) valid=0 ;; esac
        case "$initialize" in *'"requestAttestation":false'*) ;; *) valid=0 ;; esac
        printf '%s' '0123456789abcdefghijklmnop' >&2
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake/1","codexHome":"/private/fake","platformFamily":"unix","platformOs":"macos","futureField":true}}'
        IFS= read -r initialized
        case "$initialized" in *'"method":"initialized"'*) ;; *) valid=0 ;; esac
        case "$initialized" in *'"id"'*) valid=0 ;; esac
        IFS= read -r models
        if [ "$valid" -eq 1 ]; then
          printf '%s\n' '{"id":2,"result":{"data":[{"id":"future","model":"gpt-future","displayName":"Future","description":"test","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"future-effort","description":"Future effort"}],"defaultReasoningEffort":"future-effort","isDefault":true,"unknownModelField":{"kept":true}}],"nextCursor":null,"unknownTopLevel":true}}'
        else
          printf '%s\n' '{"id":2,"error":{"code":-1,"message":"invalid handshake"}}'
        fi
        sleep 2
        """#,
      stderrBufferBytes: 8
    )
    addTeardownBlock { await client.stop() }
    try await client.start()

    let initialized = try await client.initialize(clientInfo: .bridge(version: "0.1.0"))
    XCTAssertEqual(initialized.userAgent, "fake/1")
    XCTAssertEqual(initialized.platformOS, "macos")

    let models = try await client.listModels()
    XCTAssertEqual(models.data.count, 1)
    XCTAssertEqual(models.data[0].id, "future")
    XCTAssertEqual(models.data[0].defaultReasoningEffort, "future-effort")
    XCTAssertEqual(
      models.data[0].supportedReasoningEfforts[0].reasoningEffort,
      "future-effort"
    )

    try await Task.sleep(nanoseconds: 30_000_000)
    let stderr = await client.stderrSnapshot()
    XCTAssertLessThanOrEqual(stderr.count, 8)
    XCTAssertEqual(String(decoding: stderr, as: UTF8.self), "ijklmnop")
  }

  func testConcurrentInitializeSendsHandshakeOnce() async throws {
    let client = makeClient(
      script: #"""
        IFS= read -r initialize
        sleep 0.05
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake/1","codexHome":"/private/fake","platformFamily":"unix","platformOs":"macos"}}'
        IFS= read -r initialized
        sleep 2
        """#
    )
    addTeardownBlock { await client.stop() }
    try await client.start()

    let first = Task {
      try await client.initialize(clientInfo: .bridge(version: "0.1.0"))
    }
    let second = Task {
      try await client.initialize(clientInfo: .bridge(version: "0.1.0"))
    }

    var successfulResponses = 0
    var duplicateErrors = 0
    for task in [first, second] {
      do {
        _ = try await task.value
        successfulResponses += 1
      } catch CodexRPCError.alreadyInitialized {
        duplicateErrors += 1
      }
    }
    XCTAssertEqual(successfulResponses, 1)
    XCTAssertEqual(duplicateErrors, 1)
  }

  func testPublicRequestCannotInterleaveWithInitializeHandshake() async throws {
    let client = makeClient(
      script: #"""
        IFS= read -r initialize
        sleep 0.1
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake/1","codexHome":"/private/fake","platformFamily":"unix","platformOs":"macos"}}'
        IFS= read -r initialized
        sleep 2
        """#
    )
    addTeardownBlock { await client.stop() }
    try await client.start()

    let initialization = Task {
      try await client.initialize(clientInfo: .bridge(version: "0.1.0"))
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    do {
      _ = try await client.request(method: "test/interleaved", params: .object([:]))
      XCTFail("Expected request to be rejected until initialized notification is sent")
    } catch {
      XCTAssertEqual(error as? CodexRPCError, .notInitialized)
    }
    _ = try await initialization.value
  }

  func testLaunchFailureFinishesEventStream() async throws {
    let client = CodexAppServerClient(
      configuration: AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/definitely/missing/codex-bridge-fixture"),
        arguments: []
      )
    )
    var events = client.events.makeAsyncIterator()

    do {
      try await client.start()
      XCTFail("Expected launch failure")
    } catch {
      guard case .processLaunchFailed = error as? CodexRPCError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    let event = await events.next()
    XCTAssertNil(event)
  }

  func testStoppedClientIsExplicitlyOneShot() async throws {
    let client = makeClient(script: "sleep 2")
    try await client.start()
    await client.stop()

    do {
      try await client.start()
      XCTFail("Expected one-shot lifecycle")
    } catch {
      XCTAssertEqual(error as? CodexRPCError, .alreadyStarted)
    }
  }

  func testStopForceReapsProcessThatIgnoresTerminate() async throws {
    let pidURL = FileManager.default.temporaryDirectory.appending(
      path: "codex-bridge-stop-\(UUID().uuidString).pid")
    addTeardownBlock { try? FileManager.default.removeItem(at: pidURL) }
    let client = makeClient(
      script: "trap '' TERM; printf '%s' \"$$\" > '\(pidURL.path)'; while :; do sleep 1; done"
    )
    try await client.start()
    let pid = try await waitForPID(at: pidURL)

    await client.stop()

    let status = Darwin.kill(pid, 0)
    let killError = errno
    XCTAssertEqual(status, -1)
    XCTAssertEqual(killError, ESRCH)
  }

  func testEventBufferBackpressuresInsteadOfDroppingApprovalRequests() async throws {
    let client = makeClient(
      script: #"""
        IFS= read -r request
        printf '%s\n' '{"id":"approval-1","method":"future/requestApproval"}'
        printf '%s\n' '{"id":"approval-2","method":"future/requestApproval"}'
        printf '%s\n' '{"id":1,"result":{"ok":true}}'
        sleep 2
        """#,
      eventBufferLimit: 1
    )
    addTeardownBlock { await client.stop() }
    try await client.start()
    let response = Task {
      try await client.performRequest(method: "test/backpressure", params: .object([:]))
    }
    try await Task.sleep(for: .milliseconds(50))
    var events = client.events.makeAsyncIterator()

    guard case .serverRequest(let first)? = await events.next(),
      case .serverRequest(let second)? = await events.next()
    else {
      return XCTFail("Expected both approval requests")
    }
    XCTAssertEqual(first.id, .string("approval-1"))
    XCTAssertEqual(second.id, .string("approval-2"))
    let responseValue = try await response.value
    XCTAssertEqual(responseValue.objectValue?["ok"], .bool(true))
  }

  private func makeClient(
    script: String,
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    stderrBufferBytes: Int = 64 * 1024,
    eventBufferLimit: Int = 256
  ) -> CodexAppServerClient {
    CodexAppServerClient(
      configuration: AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script],
        stderrBufferBytes: stderrBufferBytes
      ),
      defaultTimeoutNanoseconds: timeoutNanoseconds,
      eventBufferLimit: eventBufferLimit
    )
  }

  private func waitForPID(at url: URL) async throws -> pid_t {
    for _ in 0..<100 {
      if let data = try? Data(contentsOf: url),
        let value = Int32(String(decoding: data, as: UTF8.self))
      {
        return value
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw CodexRPCError.timeout(method: "fixture process id")
  }
}
