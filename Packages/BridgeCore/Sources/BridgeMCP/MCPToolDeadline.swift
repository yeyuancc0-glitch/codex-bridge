import Foundation

func withToolDeadline<Output: Sendable>(
  until deadline: ContinuousClock.Instant,
  operation: @escaping @Sendable () async throws -> Output
) async throws -> Output {
  try await ToolDeadlineRace<Output>().run(until: deadline, operation: operation)
}

private actor ToolDeadlineRace<Output: Sendable> {
  private struct Pending {
    let continuation: CheckedContinuation<Output, any Error>
    let operationTask: Task<Void, Never>
    let timeoutTask: Task<Void, Never>
  }

  private var pending: Pending?

  func run(
    until deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable () async throws -> Output
  ) async throws -> Output {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        begin(until: deadline, continuation: continuation, operation: operation)
      }
    } onCancel: {
      Task { await self.cancel() }
    }
  }

  private func begin(
    until deadline: ContinuousClock.Instant,
    continuation: CheckedContinuation<Output, any Error>,
    operation: @escaping @Sendable () async throws -> Output
  ) {
    let operationTask = Task {
      do {
        finish(.success(try await operation()))
      } catch {
        finish(.failure(error))
      }
    }
    let timeoutTask = Task {
      do {
        try await ContinuousClock().sleep(until: deadline)
      } catch {
        return
      }
      finish(.failure(BridgeMCPQueryError.timeout))
    }
    pending = Pending(
      continuation: continuation,
      operationTask: operationTask,
      timeoutTask: timeoutTask
    )
  }

  private func finish(_ result: Result<Output, any Error>) {
    guard let pending else { return }
    self.pending = nil
    pending.operationTask.cancel()
    pending.timeoutTask.cancel()
    pending.continuation.resume(with: result)
  }

  private func cancel() {
    finish(.failure(CancellationError()))
  }
}
