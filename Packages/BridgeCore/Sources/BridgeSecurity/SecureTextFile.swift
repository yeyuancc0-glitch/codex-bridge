import Crypto
import Foundation

public struct SecureTextFile: Equatable, Sendable {
  public let text: String
  public let bytesRead: Int
  public let lineCount: Int
  public let truncated: Bool
  public let sha256: String
  public let byteCount: Int

  public init(
    text: String,
    bytesRead: Int,
    lineCount: Int,
    truncated: Bool,
    sha256: String = "",
    byteCount: Int = 0
  ) {
    self.text = text
    self.bytesRead = bytesRead
    self.lineCount = lineCount
    self.truncated = truncated
    self.sha256 = sha256
    self.byteCount = byteCount
  }
}
