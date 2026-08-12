import Foundation
import XCTest

@testable import BridgeCodexRPC

final class ThreadCatalogMethodsTests: XCTestCase {
  func testListUsesExactCWDAndResumeUsesStableWire() async throws {
    let client = CodexAppServerClient(
      configuration: AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c",
          #"""
          thread='{"id":"thread-1","cwd":"/tmp/project","ephemeral":false,"modelProvider":"openai","preview":"preview","turns":[],"name":"Title","cliVersion":"fake/1","createdAt":1,"updatedAt":2,"sessionId":"session-1","status":{"type":"idle"},"source":"appServer"}'
          IFS= read -r initialize
          printf '%s\n' '{"id":1,"result":{"userAgent":"fake/1","codexHome":"/private/fake","platformFamily":"unix","platformOs":"macos"}}'
          IFS= read -r initialized

          IFS= read -r list
          valid=1
          case "$list" in *'"method":"thread/list"'*) ;; *) valid=0 ;; esac
          case "$list" in *'"cwd":"/tmp/project"'*) ;; *) valid=0 ;; esac
          case "$list" in *'"limit":25'*) ;; *) valid=0 ;; esac
          case "$list" in *'"searchTerm":"Bridge"'*) ;; *) valid=0 ;; esac
          case "$list" in *'"useStateDbOnly":true'*) ;; *) valid=0 ;; esac
          if [ "$valid" -eq 1 ]; then
            printf '{"id":2,"result":{"data":[%s],"nextCursor":"next","backwardsCursor":null}}\n' "$thread"
          else
            printf '%s\n' '{"id":2,"error":{"code":-1,"message":"invalid list"}}'
          fi

          IFS= read -r resume
          valid=1
          case "$resume" in *'"method":"thread/resume"'*) ;; *) valid=0 ;; esac
          case "$resume" in *'"threadId":"thread-1"'*) ;; *) valid=0 ;; esac
          case "$resume" in *'"cwd":"/tmp/project"'*) ;; *) valid=0 ;; esac
          case "$resume" in *'"sandbox":"workspace-write"'*) ;; *) valid=0 ;; esac
          case "$resume" in *'"approvalPolicy":"on-request"'*) ;; *) valid=0 ;; esac
          if [ "$valid" -eq 1 ]; then
            printf '{"id":3,"result":{"thread":%s,"model":"gpt-test","modelProvider":"openai","reasoningEffort":"high","cwd":"/tmp/project","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["/tmp/project"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}\n' "$thread"
          else
            printf '%s\n' '{"id":3,"error":{"code":-1,"message":"invalid resume"}}'
          fi
          sleep 2
          """#,
        ],
        environment: ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
      ),
      defaultTimeoutNanoseconds: 1_000_000_000
    )
    addTeardownBlock { await client.stop() }
    try await client.start()
    _ = try await client.initialize(clientInfo: .bridge(version: "0.1.0"))

    let page = try await client.listThreads(
      ThreadListParams(
        limit: 25,
        cwd: .one("/tmp/project"),
        searchTerm: "Bridge"
      )
    )
    XCTAssertEqual(page.data.map(\.id), ["thread-1"])
    XCTAssertEqual(page.nextCursor, "next")

    let resumed = try await client.resumeThread(
      ThreadResumeParams(
        threadId: "thread-1",
        cwd: "/tmp/project",
        sandbox: .workspaceWrite,
        approvalPolicy: .onRequest,
        model: "gpt-test"
      )
    )
    XCTAssertEqual(resumed.thread.id, "thread-1")
    XCTAssertEqual(resumed.cwd, "/tmp/project")
    XCTAssertEqual(resumed.reasoningEffort, "high")
  }

  func testCWDFilterSupportsExactArrayWire() throws {
    let data = try JSONEncoder().encode(
      ThreadListParams(cwd: .anyOf(["/a", "/b"]))
    )
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["cwd"] as? [String], ["/a", "/b"])
  }
}
