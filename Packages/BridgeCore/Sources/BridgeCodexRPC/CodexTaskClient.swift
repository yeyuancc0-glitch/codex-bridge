package protocol CodexTaskClient: Sendable {
  func startThread(_ params: ThreadStartParams) async throws -> ThreadStartResponse
  func readThread(_ params: ThreadReadParams) async throws -> ThreadReadResponse
}

extension CodexAppServerClient: CodexTaskClient {}
