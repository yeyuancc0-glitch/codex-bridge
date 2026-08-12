import Foundation

actor JSONRPCBroker {
    private var pending: [Int64: CheckedContinuation<JSONValue, any Error>] = [:]
    private var stored: [Int64: Result<JSONValue, AppServerProbeError>] = [:]
    private var terminalError: AppServerProbeError?
    private(set) var serverMessageCount = 0

    func receive(_ message: JSONValue) {
        guard let object = message.objectValue else {
            terminate(with: .malformedMessage("top-level value is not an object"))
            return
        }

        if object["method"] != nil {
            serverMessageCount += 1
            return
        }

        guard let id = object["id"]?.integerValue else {
            terminate(with: .malformedMessage("response has no integer id"))
            return
        }

        let result = makeResult(from: object)
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(with: result.mapError { $0 as any Error })
        } else {
            stored[id] = result
        }
    }

    func wait(for id: Int64) async throws -> JSONValue {
        if let result = stored.removeValue(forKey: id) {
            return try result.get()
        }
        if let terminalError {
            throw terminalError
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func terminate(with error: AppServerProbeError) {
        guard terminalError == nil else { return }
        terminalError = error
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func cancel(id: Int64) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func makeResult(
        from object: [String: JSONValue]
    ) -> Result<JSONValue, AppServerProbeError> {
        if let result = object["result"] {
            return .success(result)
        }

        guard let error = object["error"]?.objectValue else {
            return .failure(.malformedMessage("response has neither result nor error"))
        }

        let code = error["code"]?.integerValue.flatMap(Int.init(exactly:))
        let message = error["message"]?.stringValue ?? "Unknown remote error"
        return .failure(.remote(code: code, message: message))
    }
}

