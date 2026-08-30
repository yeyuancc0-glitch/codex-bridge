import BridgeSecurity
import Foundation

#if os(Windows)
  import Crypto
  import WinSDK
#endif

public struct ServiceAgentFileIdentity: Codable, Equatable, Sendable {
  public static let maximumFileBytes: UInt64 = 1_073_741_824
  public static let maximumConfigurationBytes: UInt64 = 256 * 1_024

  public let canonicalPath: String
  public let device: UInt64
  public let inode: UInt64
  public let fileSize: UInt64
  public let modificationTimeNanoseconds: Int64
  public let sha256: String

  public init(
    canonicalPath: String,
    device: UInt64,
    inode: UInt64,
    fileSize: UInt64,
    modificationTimeNanoseconds: Int64,
    sha256: String
  ) throws {
    #if os(Windows)
      let validPath = true
    #else
      let validPath = canonicalPath.hasPrefix("/")
    #endif
    guard validPath,
      canonicalPath.utf8.count <= 16 * 1_024,
      !canonicalPath.contains("\0"),
      canonicalPath.rangeOfCharacter(from: .controlCharacters) == nil,
      inode > 0,
      fileSize > 0,
      fileSize <= Self.maximumFileBytes,
      modificationTimeNanoseconds >= 0,
      Self.isLowercaseSHA256(sha256)
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
    }
    self.canonicalPath = canonicalPath
    self.device = device
    self.inode = inode
    self.fileSize = fileSize
    self.modificationTimeNanoseconds = modificationTimeNanoseconds
    self.sha256 = sha256
  }

  public init(capturing path: String, requiresExecutable: Bool = false) throws {
    do {
      let snapshot = try SecureFileArtifactSnapshot(
        capturing: path,
        requiresExecutable: requiresExecutable,
        maximumBytes: Self.maximumFileBytes
      )
      try self.init(
        canonicalPath: snapshot.canonicalPath,
        device: snapshot.device,
        inode: snapshot.inode,
        fileSize: snapshot.fileSize,
        modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
        sha256: snapshot.sha256
      )
    } catch let error as SecureFileArtifactError {
      throw Self.map(error)
    }
  }

  public init(capturing path: String, role: ServiceAgentInstallationArtifactRole) throws {
    try self.init(capturing: path, requiresExecutable: role.requiresExecutable)
  }

  private static func map(_ error: SecureFileArtifactError) -> ServiceStoreError {
    switch error {
    case .invalidPath, .openFailed:
      .invalidArgument("agentInstallation.artifactPath")
    case .changed:
      .invalidArgument("agentInstallation.artifactChanged")
    default:
      .invalidArgument("agentInstallation.artifactIdentity")
    }
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }
}

#if os(Windows)
  /// Compatibility inspection used by the executable identity adapter.
  enum ServiceAgentArtifactInspection {
    struct Snapshot: Equatable {
      var device: UInt64
      var inode: UInt64
      var size: UInt64
      var lastWriteFileTime: UInt64
      var attributes: DWORD
    }

    static func open(_ path: String) -> HANDLE {
      path.withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(GENERIC_READ),
          DWORD(FILE_SHARE_READ),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
    }

    static func snapshot(_ handle: HANDLE) -> Snapshot? {
      var information = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &information) else { return nil }
      let lastWrite = information.ftLastWriteTime
      return Snapshot(
        device: UInt64(information.dwVolumeSerialNumber),
        inode: (UInt64(information.nFileIndexHigh) << 32) | UInt64(information.nFileIndexLow),
        size: (UInt64(information.nFileSizeHigh) << 32) | UInt64(information.nFileSizeLow),
        lastWriteFileTime: (UInt64(lastWrite.dwHighDateTime) << 32)
          | UInt64(lastWrite.dwLowDateTime),
        attributes: information.dwFileAttributes
      )
    }

    static func digest(_ handle: HANDLE, errorField: String) throws -> String {
      var hasher = SHA256()
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      while true {
        var readBytes: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes { bytes in
          ReadFile(handle, bytes.baseAddress, DWORD(bytes.count), &readBytes, nil)
        }
        guard succeeded else { throw ServiceStoreError.invalidArgument(errorField) }
        if readBytes == 0 { break }
        hasher.update(data: Data(buffer.prefix(Int(readBytes))))
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func modificationTimeNanoseconds(
      _ fileTime: UInt64,
      errorField: String
    ) throws -> Int64 {
      let unixEpochFileTime: UInt64 = 116_444_736_000_000_000
      guard fileTime >= unixEpochFileTime else {
        throw ServiceStoreError.invalidArgument(errorField)
      }
      let nanoseconds = Int64((fileTime - unixEpochFileTime) * 100)
      guard nanoseconds >= 0 else {
        throw ServiceStoreError.invalidArgument(errorField)
      }
      return nanoseconds
    }
  }
#endif
