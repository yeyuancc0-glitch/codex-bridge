import Foundation

public enum SecureFileArtifactReader {
  public static func read(
    at path: String,
    maximumBytes: Int
  ) throws -> Data {
    guard maximumBytes > 0,
      UInt64(maximumBytes) <= SecureFileArtifactSnapshot.defaultMaximumBytes
    else {
      throw SecureFileArtifactError.invalidMaximumBytes
    }
    return try readData(at: path, maximumBytes: maximumBytes)
  }
}
