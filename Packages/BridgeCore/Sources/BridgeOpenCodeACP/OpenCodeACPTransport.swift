import BridgeACP
import BridgeProcess
import Foundation

public typealias OpenCodeACPTransport = BridgeACP.ACPTransport
public typealias OpenCodeACPProcessTransportConfiguration =
  BridgeACP.ACPProcessTransportConfiguration

public final class OpenCodeACPProcessTransport: OpenCodeACPTransport, @unchecked Sendable {
  public let incoming: AsyncThrowingStream<Data, any Error>

  private let base: BridgeACP.ACPProcessTransport

  public static func launch(
    configuration: OpenCodeACPProcessTransportConfiguration
  ) throws -> OpenCodeACPProcessTransport {
    let base = try BridgeACP.ACPProcessTransport.launch(configuration: configuration)
    return OpenCodeACPProcessTransport(base: base)
  }

  private init(base: BridgeACP.ACPProcessTransport) {
    self.base = base
    let pair = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(256)
    )
    incoming = pair.stream
    let continuation = pair.continuation
    Task {
      do {
        for try await frame in base.incoming {
          guard case .enqueued = continuation.yield(frame) else {
            await base.close()
            return
          }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: Self.compatibilityError(for: error))
      }
    }
  }

  public func send(_ frame: Data) async throws {
    do {
      try await base.send(frame)
    } catch {
      throw Self.compatibilityError(for: error)
    }
  }

  public func close() async {
    await base.close()
  }

  public func standardErrorSnapshot() -> BoundedProcessOutput {
    base.standardErrorSnapshot()
  }

  private static func compatibilityError(for error: any Error) -> OpenCodeACPError {
    if let error = error as? OpenCodeACPError { return error }
    if let error = error as? BridgeACP.ACPError {
      switch error {
      case .invalidMessage: return .invalidMessage
      case .malformedResponse: return .malformedResponse
      case .remote(let code, let message): return .remote(code: code, message: message)
      case .requestTimedOut: return .requestTimedOut
      case .transportClosed: return .transportClosed
      case .processExited(let code): return .processExited(code)
      case .oversizedFrame: return .oversizedFrame
      }
    }
    return .transportClosed
  }
}
