import BridgeProcess
import Foundation

@testable import BridgeAntigravityCLI

enum AntigravityCLITestSupport {
  static func temporaryDirectory(prefix: String) throws -> String {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true).path
    try FileManager.default.createDirectory(
      atPath: path,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return path
  }

  static func data(_ json: String) -> Data {
    Data(json.utf8)
  }

  static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: data(json))
  }

  static func initializationFrame(
    conversationID: String = "conversation-1",
    cwd: String,
    permissionMode: String = "request-review",
    model: String = "gemini-test"
  ) -> Data {
    data(
      """
      {"event":"init","conversation_id":"\(conversationID)","init":{"cwd":"\(cwd)","tools":["read_file","search"],"permission_mode":"\(permissionMode)","model":"\(model)","agent":"antigravity"}}
      """
    )
  }

  static func resultFrame(
    conversationID: String = "conversation-1",
    status: String = "SUCCESS",
    response: String = "Done.",
    error: String? = nil,
    totalTokens: Int? = nil
  ) throws -> Data {
    let errorValue = error.map { "\"\($0)\"" } ?? "null"
    let usageValue =
      totalTokens.map {
        "\"usage\":{\"input_tokens\":1,\"output_tokens\":\($0 - 1),\"total_tokens\":\($0)}"
      } ?? "\"usage\":null"
    return data(
      """
      {"event":"result","conversation_id":"\(conversationID)","result":{"conversation_id":"\(conversationID)","status":"\(status)","response":"\(response)","error":\(errorValue),"duration_seconds":0.1,"num_turns":1,\(usageValue)}}
      """
    )
  }

  static func stepUpdateFrame(
    conversationID: String = "conversation-1",
    stepIndex: Int = 0,
    state: String = "ACTIVE",
    stepType: String = "agent_response",
    textDelta: String? = "Hello",
    toolName: String? = nil,
    toolInfo: String = "null",
    usage: String = "null"
  ) -> Data {
    let textValue = textDelta.map { "\"\($0)\"" } ?? "null"
    let toolNameValue = toolName.map { "\"\($0)\"" } ?? "null"
    return data(
      """
      {"event":"step_update","step_update":{"conversation_id":"\(conversationID)","step_index":\(stepIndex),"state":"\(state)","step_type":"\(stepType)","tool_name":\(toolNameValue),"text_delta":\(textValue),"duration_seconds":0.2,"usage":\(usage),"tool_info":\(toolInfo),"subagent_info":null}}
      """
    )
  }
}

actor ScriptedAntigravityTransport: AntigravityCLITransport {
  typealias Handler = @Sendable (Data, ScriptedAntigravityTransport) async throws -> Void

  nonisolated let incoming: AsyncThrowingStream<Data, any Error>

  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let standardError: BoundedProcessOutput
  private var handler: Handler?
  private var sentFrames: [Data] = []
  private var interruptCount = 0
  private var closed = false

  init(
    bufferLimit: Int = 256,
    standardError: BoundedProcessOutput = BoundedProcessOutput(
      head: "",
      tail: "",
      byteCount: 0,
      truncated: false
    )
  ) {
    let pair = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(max(1, bufferLimit))
    )
    incoming = pair.stream
    continuation = pair.continuation
    self.standardError = standardError
  }

  func setHandler(_ handler: @escaping Handler) {
    self.handler = handler
  }

  func send(_ frame: Data) async throws {
    guard !closed else { throw AntigravityCLIError.transportClosed }
    sentFrames.append(frame)
    if let handler {
      try await handler(frame, self)
    }
  }

  func emit(_ frame: Data) throws {
    guard !closed else { throw AntigravityCLIError.transportClosed }
    let result = continuation.yield(frame)
    if case .dropped = result {
      closed = true
      continuation.finish(throwing: AntigravityCLIError.transportClosed)
      throw AntigravityCLIError.transportClosed
    }
  }

  func finish(throwing error: (any Error)? = nil) {
    guard !closed else { return }
    closed = true
    if let error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
  }

  func sentFramesValue() -> [Data] {
    sentFrames
  }

  func interruptCountValue() -> Int {
    interruptCount
  }

  func standardErrorSnapshot() async -> BoundedProcessOutput {
    standardError
  }

  func interrupt() async {
    interruptCount += 1
  }

  func close() async {
    finish()
  }
}

actor RecordingAntigravityCommandRunner: AntigravityCLICommandRunning {
  struct Call: Equatable, Sendable {
    let argv: [String]
    let workingDirectory: String?
    let environment: [String: String]
    let timeout: Duration
  }

  private let result: AntigravityCLICommandResult
  private var recordedCalls: [Call] = []

  init(result: AntigravityCLICommandResult) {
    self.result = result
  }

  func run(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String],
    timeout: Duration
  ) async throws -> AntigravityCLICommandResult {
    recordedCalls.append(
      Call(
        argv: argv,
        workingDirectory: workingDirectory,
        environment: environment,
        timeout: timeout
      )
    )
    return result
  }

  func calls() -> [Call] {
    recordedCalls
  }
}
