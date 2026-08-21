import Foundation

package struct CodexReconciliationTurn: Decodable, Equatable, Sendable {
  package let id: String
  package let status: String

  package init(id: String, status: String) {
    self.id = id
    self.status = status
  }
}

package struct CodexReconciliationThread: Decodable, Equatable, Sendable {
  package let id: String
  package let cwd: String
  package let status: JSONValue
  package let turns: [CodexReconciliationTurn]

  package init(
    id: String,
    cwd: String,
    status: JSONValue,
    turns: [CodexReconciliationTurn]
  ) {
    self.id = id
    self.cwd = cwd
    self.status = status
    self.turns = turns
  }
}

package struct ThreadReconciliationReadResponse: Decodable, Equatable, Sendable {
  package let thread: CodexReconciliationThread

  package init(thread: CodexReconciliationThread) {
    self.thread = thread
  }
}

extension CodexAppServerClient {
  package func readThreadForReconciliation(
    _ params: ThreadReadParams
  ) async throws -> ThreadReconciliationReadResponse {
    return try await request(
      method: "thread/read",
      params: params,
      response: ThreadReconciliationReadResponse.self
    )
  }
}
