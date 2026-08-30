#if os(Windows)
  import Foundation
  import WinSDK

  extension WindowsSecureFile {
    static func openAbsoluteRegularFileResolving(
      _ path: String,
      desiredAccess: DWORD
    ) throws -> (HANDLE, Metadata) {
      let location = try splitAbsolutePath(path)
      return try openResolving(
        rootPath: location.root,
        components: location.components,
        desiredAccess: desiredAccess,
        creationDisposition: DWORD(OPEN_EXISTING),
        finalIsDirectory: false,
        shareMode: DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
        flagsAndAttributes: DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
      )
    }

    private static func splitAbsolutePath(
      _ path: String
    ) throws -> (root: String, components: [String]) {
      let normalized = path.replacingOccurrences(of: "/", with: "\\")
      let characters = Array(normalized)
      if characters.count >= 3,
        characters[1] == ":",
        characters[2] == "\\"
      {
        let root = String(characters.prefix(2))
        let remainder = String(characters.dropFirst(3))
        return try validatedLocation(root: root, remainder: remainder)
      }

      guard normalized.hasPrefix("\\\\") else {
        throw SecureFileArtifactError.invalidPath
      }
      let pieces = normalized.dropFirst(2).split(
        separator: "\\",
        omittingEmptySubsequences: false
      ).map(String.init)
      guard pieces.count >= 3,
        validComponent(pieces[0]),
        validComponent(pieces[1])
      else {
        throw SecureFileArtifactError.invalidPath
      }
      let root = "\\\\\(pieces[0])\\\(pieces[1])"
      let components = Array(pieces.dropFirst(2))
      guard components.allSatisfy(validComponent) else {
        throw SecureFileArtifactError.invalidPath
      }
      return (root, components)
    }

    private static func validatedLocation(
      root: String,
      remainder: String
    ) throws -> (root: String, components: [String]) {
      let components = remainder.split(
        separator: "\\",
        omittingEmptySubsequences: false
      ).map(String.init)
      guard !components.isEmpty, components.allSatisfy(validComponent) else {
        throw SecureFileArtifactError.invalidPath
      }
      return (root, components)
    }

    private static func validComponent(_ value: String) -> Bool {
      !value.isEmpty && value != "." && value != ".."
    }
  }
#endif
