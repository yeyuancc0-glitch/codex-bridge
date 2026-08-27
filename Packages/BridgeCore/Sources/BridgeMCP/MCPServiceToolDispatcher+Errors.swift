import Foundation
import MCP

extension MCPServiceToolDispatcher {
  func encodeQueryError(_ error: BridgeMCPQueryError) throws -> CallTool.Result {
    try resultEncoder.encode(MCPToolErrorOutput(error: error.toolError), isError: true)
  }

  func encodeResultError(_ error: MCPToolResultEncodingError) throws -> CallTool.Result {
    switch error {
    case .resultTooLarge:
      return try resultEncoder.encode(
        MCPToolErrorOutput(
          error: .init(
            code: "result_too_large",
            category: .capabilityUnavailable,
            message: "The result is too large. Request a smaller page.",
            retryable: true,
            nextAction: "request_smaller_page"
          )
        ),
        isError: true
      )
    }
  }

  func encodeInvalidParameters(_ detail: String?) throws -> CallTool.Result {
    let message = detail.map { "Invalid tool arguments: \($0)" } ?? "Invalid tool arguments."
    return try resultEncoder.encode(
      MCPToolErrorOutput(
        error: MCPToolErrorDTO(
          code: "invalid_arguments",
          category: .callerError,
          message: message,
          retryable: false,
          nextAction: "fix_tool_arguments"
        )
      ),
      isError: true
    )
  }

}
