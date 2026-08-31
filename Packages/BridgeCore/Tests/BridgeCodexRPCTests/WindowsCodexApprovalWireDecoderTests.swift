#if os(Windows)
  import Foundation
  import XCTest

  @testable import BridgeCodexRPC

  final class WindowsCodexApprovalWireDecoderTests: XCTestCase {
    func testPermissionsAndCommandEvidenceAcceptDriveAndUNCWorkingDirectories() throws {
      for cwd in [#"C:\workspace\project"#, #"\\server\share\project"#] {
        let permissions = try CodexApprovalWireDecoder.decode(
          request(method: "item/permissions/requestApproval", params: params(cwd: cwd))
        )
        guard case .permissions(let request) = permissions else {
          return XCTFail("Expected permissions request")
        }
        XCTAssertEqual(request.workingDirectory, cwd)

        let evidence = try CodexApprovalWireDecoder.decodeItemStarted(
          RPCNotification(
            method: "item/started",
            params: .object([
              "threadId": .string("thread-1"),
              "turnId": .string("turn-1"),
              "startedAtMs": .integer(1),
              "item": .object([
                "id": .string("item-1"),
                "type": .string("commandExecution"),
                "command": .string("tool"),
                "commandActions": .array([]),
                "cwd": .string(cwd),
                "status": .string("inProgress"),
              ]),
            ])
          )
        )
        guard case .commandExecution(let command) = evidence else {
          return XCTFail("Expected command evidence")
        }
        XCTAssertEqual(command.workingDirectory, cwd)
      }
    }

    func testRejectsNonNormalizedOrDeviceWorkingDirectories() {
      for cwd in [
        #"C:\workspace\project\."#,
        #"C:\workspace\project\..\private"#,
        #"\\server\share\project\..\private"#,
        #"\\?\C:\workspace\project"#,
      ] {
        assertInvalidCWD(cwd)
      }
    }

    private func params(cwd: String) -> [String: JSONValue] {
      [
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "itemId": .string("item-1"),
        "startedAtMs": .integer(1),
        "cwd": .string(cwd),
        "permissions": .object([:]),
      ]
    }

    private func request(
      method: String,
      params: [String: JSONValue]
    ) -> RPCServerRequest {
      RPCServerRequest(id: .string("request-1"), method: method, params: .object(params))
    }

    private func assertInvalidCWD(
      _ cwd: String,
      file: StaticString = #filePath,
      line: UInt = #line
    ) {
      XCTAssertThrowsError(
        try CodexApprovalWireDecoder.decode(
          request(
            method: "item/permissions/requestApproval",
            params: params(cwd: cwd)
          )
        ),
        file: file,
        line: line
      ) { error in
        XCTAssertEqual(
          error as? CodexApprovalWireError,
          .invalidField("cwd"),
          file: file,
          line: line
        )
      }
    }
  }
#endif
