import Foundation
import XCTest

@testable import BridgeCodexRPC

final class TypedCodexMethodsTests: XCTestCase {
  func testExperimentalProjectMethodsAndThreadAssignmentUseTypedWire() async throws {
    let client = makeClient(
      script: #"""
        project='{"id":"project-1","name":"Fixture","roots":[{"path":"/tmp/project"}],"metadata":{"managedBy":"fixture"},"position":0,"createdAt":1,"updatedAt":2}'
        thread='{"id":"thread-1","cwd":"/tmp/project","ephemeral":false,"modelProvider":"openai","preview":"","turns":[],"name":null,"cliVersion":"fake/1","createdAt":1,"updatedAt":2,"sessionId":"session-1","status":{"type":"idle"},"source":"appServer","projectId":"project-1"}'
        IFS= read -r initialize
        case "$initialize" in *'"experimentalApi":true'*) ;; *) exit 11 ;; esac
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake/1","codexHome":"/private/fake","platformFamily":"unix","platformOs":"macos"}}'
        IFS= read -r initialized
        IFS= read -r project_list
        case "$project_list" in *'"method":"project/list"'*) ;; *) exit 12 ;; esac
        printf '{"id":2,"result":{"data":[%s],"nextCursor":null}}\n' "$project"
        IFS= read -r project_create
        case "$project_create" in *'"method":"project/create"'*) ;; *) exit 13 ;; esac
        case "$project_create" in *'"idempotencyKey":"bridge-project"'*) ;; *) exit 14 ;; esac
        printf '{"id":3,"result":{"project":%s}}\n' "$project"
        IFS= read -r thread_update
        case "$thread_update" in *'"method":"thread/metadata/update"'*) ;; *) exit 15 ;; esac
        case "$thread_update" in *'"projectId":"project-1"'*) ;; *) exit 16 ;; esac
        printf '{"id":4,"result":{"thread":%s}}\n' "$thread"
        sleep 1
        """#
    )
    addTeardownBlock { await client.stop() }
    try await client.start()
    _ = try await client.initialize(
      clientInfo: .bridge(version: "project-tests"),
      capabilities: InitializeCapabilities(experimentalAPI: true)
    )

    let listed = try await client.listProjects(ProjectListParams(limit: 100))
    XCTAssertEqual(listed.data.first?.roots, [CodexProjectRoot(path: "/tmp/project")])

    let created = try await client.createProject(
      ProjectCreateParams(
        idempotencyKey: "bridge-project",
        name: "Fixture",
        roots: [CodexProjectRoot(path: "/tmp/project")]
      )
    )
    XCTAssertEqual(created.project.id, "project-1")

    let updated = try await client.updateThreadMetadata(
      ThreadMetadataUpdateParams(threadId: "thread-1", projectId: "project-1")
    )
    XCTAssertEqual(updated.thread.projectId, "project-1")
  }

  func testTypedTaskMethodsMatchStableWireAndParseNotification() async throws {
    let client = makeClient(
      script: #"""
        thread='{"id":"thread-1","cwd":"/tmp/codex-bridge-fixture","ephemeral":true,"modelProvider":"openai","preview":"","turns":[],"name":null,"cliVersion":"fake/1","createdAt":1,"updatedAt":2,"sessionId":"session-1","status":{"type":"idle","futureStatusField":true},"source":"appServer","futureThreadField":7}'
        turn='{"id":"turn-1","status":"futureTurnStatus","error":{"message":"future failure","futureErrorField":true},"items":[],"itemsView":"full","startedAt":3,"futureTurnField":true}'

        IFS= read -r initialize
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake/1","codexHome":"/private/fake","platformFamily":"unix","platformOs":"macos"}}'
        IFS= read -r initialized

        IFS= read -r thread_start
        valid=1
        case "$thread_start" in *'"method":"thread/start"'*) ;; *) valid=0 ;; esac
        case "$thread_start" in *'"cwd":"/tmp/codex-bridge-fixture"'*) ;; *) valid=0 ;; esac
        case "$thread_start" in *'"sandbox":"read-only"'*) ;; *) valid=0 ;; esac
        case "$thread_start" in *'"approvalPolicy":"never"'*) ;; *) valid=0 ;; esac
        case "$thread_start" in *'"ephemeral":true'*) ;; *) valid=0 ;; esac
        case "$thread_start" in *'"model":"runtime-model"'*) ;; *) valid=0 ;; esac
        if [ "$valid" -eq 1 ]; then
          printf '{"id":2,"result":{"thread":%s,"model":"runtime-model","modelProvider":"openai","reasoningEffort":"future-effort","cwd":"/tmp/codex-bridge-fixture","sandbox":{"type":"readOnly","networkAccess":false,"futureSandboxField":true},"approvalPolicy":"never","approvalsReviewer":"user","serviceTier":null,"futureResponseField":true}}\n' "$thread"
        else
          printf '%s\n' '{"id":2,"error":{"code":-1,"message":"invalid thread/start"}}'
        fi

        IFS= read -r thread_read
        valid=1
        case "$thread_read" in *'"method":"thread/read"'*) ;; *) valid=0 ;; esac
        case "$thread_read" in *'"threadId":"thread-1"'*) ;; *) valid=0 ;; esac
        case "$thread_read" in *'"includeTurns":true'*) ;; *) valid=0 ;; esac
        if [ "$valid" -eq 1 ]; then
          printf '{"id":3,"result":{"thread":%s,"futureResponseField":true}}\n' "$thread"
        else
          printf '%s\n' '{"id":3,"error":{"code":-1,"message":"invalid thread/read"}}'
        fi

        IFS= read -r turn_start
        valid=1
        case "$turn_start" in *'"method":"turn/start"'*) ;; *) valid=0 ;; esac
        case "$turn_start" in *'"threadId":"thread-1"'*) ;; *) valid=0 ;; esac
        case "$turn_start" in *'"text":"begin"'*) ;; *) valid=0 ;; esac
        case "$turn_start" in *'"text_elements":[]'*) ;; *) valid=0 ;; esac
        case "$turn_start" in *'"sandboxPolicy":{'*) ;; *) valid=0 ;; esac
        case "$turn_start" in *'"type":"readOnly"'*) ;; *) valid=0 ;; esac
        case "$turn_start" in *'"networkAccess":false'*) ;; *) valid=0 ;; esac
        case "$turn_start" in *'"approvalPolicy":"on-request"'*) ;; *) valid=0 ;; esac
        case "$turn_start" in *'"model":"custom-model"'*) ;; *) valid=0 ;; esac
        case "$turn_start" in *'"effort":"custom-effort"'*) ;; *) valid=0 ;; esac
        printf '{"method":"turn/started","params":{"threadId":"thread-1","turn":%s,"futureNotificationField":true},"futureEnvelopeField":9}\n' "$turn"
        if [ "$valid" -eq 1 ]; then
          printf '{"id":4,"result":{"turn":%s,"futureResponseField":true}}\n' "$turn"
        else
          printf '%s\n' '{"id":4,"error":{"code":-1,"message":"invalid turn/start"}}'
        fi

        IFS= read -r turn_steer
        valid=1
        case "$turn_steer" in *'"method":"turn/steer"'*) ;; *) valid=0 ;; esac
        case "$turn_steer" in *'"threadId":"thread-1"'*) ;; *) valid=0 ;; esac
        case "$turn_steer" in *'"expectedTurnId":"turn-1"'*) ;; *) valid=0 ;; esac
        case "$turn_steer" in *'"text":"adjust"'*) ;; *) valid=0 ;; esac
        case "$turn_steer" in *'"text_elements":[]'*) ;; *) valid=0 ;; esac
        if [ "$valid" -eq 1 ]; then
          printf '%s\n' '{"id":5,"result":{"turnId":"turn-1","futureResponseField":true}}'
        else
          printf '%s\n' '{"id":5,"error":{"code":-1,"message":"invalid turn/steer"}}'
        fi

        IFS= read -r turn_interrupt
        valid=1
        case "$turn_interrupt" in *'"method":"turn/interrupt"'*) ;; *) valid=0 ;; esac
        case "$turn_interrupt" in *'"threadId":"thread-1"'*) ;; *) valid=0 ;; esac
        case "$turn_interrupt" in *'"turnId":"turn-1"'*) ;; *) valid=0 ;; esac
        if [ "$valid" -eq 1 ]; then
          printf '%s\n' '{"id":6,"result":{}}'
        else
          printf '%s\n' '{"id":6,"error":{"code":-1,"message":"invalid turn/interrupt"}}'
        fi
        sleep 2
        """#
    )
    addTeardownBlock { await client.stop() }
    try await client.start()
    _ = try await client.initialize(clientInfo: .bridge(version: "0.1.0"))
    var events = client.events.makeAsyncIterator()

    let startedThread = try await client.startThread(
      ThreadStartParams(
        cwd: "/tmp/codex-bridge-fixture",
        sandbox: .readOnly,
        approvalPolicy: .never,
        model: "runtime-model"
      )
    )
    XCTAssertEqual(startedThread.thread.id, "thread-1")
    XCTAssertEqual(startedThread.reasoningEffort, "future-effort")
    XCTAssertEqual(startedThread.thread.status.objectValue?["futureStatusField"], .bool(true))

    let readThread = try await client.readThread(
      ThreadReadParams(threadId: "thread-1", includeTurns: true)
    )
    XCTAssertEqual(readThread.thread.id, "thread-1")

    let startedTurn = try await client.startTurn(
      TurnStartParams(
        threadId: "thread-1",
        text: "begin",
        sandboxPolicy: .readOnly(),
        approvalPolicy: .onRequest,
        model: "custom-model",
        effort: "custom-effort"
      )
    )
    XCTAssertEqual(startedTurn.turn.id, "turn-1")
    XCTAssertEqual(startedTurn.turn.status, "futureTurnStatus")
    XCTAssertEqual(
      startedTurn.turn.error?.objectValue?["futureErrorField"], .bool(true))

    guard case .notification(let rawNotification)? = await events.next() else {
      return XCTFail("Expected turn/started notification")
    }
    XCTAssertEqual(rawNotification.metadata["futureEnvelopeField"], .integer(9))
    guard
      case .turnStarted(let notification) =
        try rawNotification.decodedCodexNotification()
    else {
      return XCTFail("Expected typed turn/started notification")
    }
    XCTAssertEqual(notification.threadId, "thread-1")
    XCTAssertEqual(notification.turn.status, "futureTurnStatus")

    let steered = try await client.steerTurn(
      TurnSteerParams(
        threadId: "thread-1",
        expectedTurnId: "turn-1",
        text: "adjust"
      )
    )
    XCTAssertEqual(steered.turnId, "turn-1")

    _ = try await client.interruptTurn(
      TurnInterruptParams(threadId: "thread-1", turnId: "turn-1")
    )
  }

  func testUnknownNotificationRemainsLossless() throws {
    let raw = RPCNotification(
      method: "future/notification",
      params: .object(["future": .bool(true)]),
      metadata: ["trace": .string("kept")]
    )

    XCTAssertEqual(try raw.decodedCodexNotification(), .unknown(raw))
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
