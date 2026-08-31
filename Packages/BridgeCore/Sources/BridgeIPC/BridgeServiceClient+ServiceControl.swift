#if os(Windows)
  import Foundation

  extension BridgeServiceClient {
    public func shutdownService() async throws -> IPCServiceShutdownResponse {
      let response: IPCServiceShutdownResponse = try await call(
        operation: .shutdownService,
        payload: Optional<IPCMutationResponse>.none
      )
      return response
    }
  }
#endif
