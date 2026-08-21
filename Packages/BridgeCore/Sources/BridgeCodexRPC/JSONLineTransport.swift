@preconcurrency import Foundation

private final class SendableFileHandle: @unchecked Sendable {
  let value: FileHandle

  init(_ value: FileHandle) {
    self.value = value
  }
}

public actor JSONLineTransport {
  private static let maximumBufferedChunks = 16

  private let input: SendableFileHandle
  private let output: SendableFileHandle
  private let dispatcher: RPCDispatcher
  private let maximumLineBytes: Int
  private var readerTask: Task<Void, Never>?
  private var readContinuation: AsyncStream<Data>.Continuation?
  private var started = false

  init(
    input: FileHandle,
    output: FileHandle,
    dispatcher: RPCDispatcher,
    maximumLineBytes: Int
  ) {
    self.input = SendableFileHandle(input)
    self.output = SendableFileHandle(output)
    self.dispatcher = dispatcher
    self.maximumLineBytes = maximumLineBytes
  }

  func start(onProtocolFailure: @escaping @Sendable () -> Void) throws {
    guard !started else { throw CodexRPCError.alreadyStarted }
    started = true

    let output = output
    let dispatcher = dispatcher
    let maximumLineBytes = maximumLineBytes
    let pair = AsyncStream.makeStream(
      of: Data.self,
      bufferingPolicy: .bufferingOldest(Self.maximumBufferedChunks)
    )
    readContinuation = pair.continuation
    output.value.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        pair.continuation.finish()
      } else {
        if case .dropped = pair.continuation.yield(data) {
          pair.continuation.finish()
          Task {
            await dispatcher.terminate(
              with: .transportReadOverflow(
                maximumBufferedChunks: Self.maximumBufferedChunks
              )
            )
          }
          onProtocolFailure()
        }
      }
    }
    readerTask = Task.detached(priority: .userInitiated) {
      var parser = JSONLineParser(maximumLineBytes: maximumLineBytes)
      do {
        for await data in pair.stream {
          try Task.checkCancellation()
          for message in try parser.ingest(data) {
            try await dispatcher.receive(message)
          }
        }
        try Task.checkCancellation()
        for message in try parser.finish() {
          try await dispatcher.receive(message)
        }
      } catch is CancellationError {
        return
      } catch let error as CodexRPCError {
        await dispatcher.terminate(with: error)
        onProtocolFailure()
      } catch {
        await dispatcher.terminate(
          with: .malformedMessage(error.localizedDescription)
        )
        onProtocolFailure()
      }
    }
  }

  public func write(_ value: JSONValue) throws {
    guard started else { throw CodexRPCError.notStarted }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .withoutEscapingSlashes
      var data = try encoder.encode(value)
      data.append(0x0A)
      try input.value.write(contentsOf: data)
    } catch let error as CodexRPCError {
      throw error
    } catch {
      throw CodexRPCError.transportWriteFailed(error.localizedDescription)
    }
  }

  func stop() {
    guard started else { return }
    started = false
    output.value.readabilityHandler = nil
    readContinuation?.finish()
    readContinuation = nil
    readerTask?.cancel()
    readerTask = nil
    try? input.value.close()
    try? output.value.close()
  }
}
