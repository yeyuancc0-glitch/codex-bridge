#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsProcessIdentity {
    static func currentImagePath() throws -> String {
      guard let path = imagePath(for: GetCurrentProcess()) else {
        throw WindowsProcessIdentityError.currentProcessPathUnavailable
      }
      return path
    }

    static func imagePath(for processID: UInt32) -> String? {
      guard processID > 0,
        let handle = OpenProcess(
          DWORD(PROCESS_QUERY_LIMITED_INFORMATION),
          false,
          DWORD(processID)
        )
      else { return nil }
      defer { _ = CloseHandle(handle) }
      return imagePath(for: handle)
    }

    static func imagePath(for handle: HANDLE) -> String? {
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      var length = DWORD(buffer.count)
      let succeeded = buffer.withUnsafeMutableBufferPointer { raw in
        QueryFullProcessImageNameW(
          handle,
          DWORD(0),
          raw.baseAddress,
          &length
        )
      }
      guard succeeded, length > 0 else { return nil }
      return String(decoding: buffer[..<Int(length)], as: UTF16.self)
    }

    static func hasOtherProcess(at expectedPath: String) throws -> Bool {
      try !processIDs(at: expectedPath).isEmpty
    }

    static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
      normalizePath(lhs).caseInsensitiveCompare(normalizePath(rhs)) == .orderedSame
    }

    private static func processIDs(at expectedPath: String) throws -> [UInt32] {
      guard
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), DWORD(0)),
        snapshot != INVALID_HANDLE_VALUE
      else {
        throw WindowsProcessIdentityError.processSnapshotUnavailable
      }
      defer { _ = CloseHandle(snapshot) }

      var entry = PROCESSENTRY32W()
      entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
      guard Process32FirstW(snapshot, &entry) else {
        guard GetLastError() == ERROR_NO_MORE_FILES else {
          throw WindowsProcessIdentityError.processEnumerationFailed
        }
        return []
      }

      let expectedName = basename(of: expectedPath)
      var matches: [UInt32] = []
      repeat {
        let processID = entry.th32ProcessID
        if processID != GetCurrentProcessId(),
          basename(of: entry).caseInsensitiveCompare(expectedName) == .orderedSame
        {
          if let actualPath = imagePath(for: processID), pathsEqual(actualPath, expectedPath) {
            matches.append(processID)
          }
        }
      } while Process32NextW(snapshot, &entry)

      let error = GetLastError()
      guard error == ERROR_NO_MORE_FILES else {
        throw WindowsProcessIdentityError.processEnumerationFailed
      }
      return matches
    }

    private static func basename(of path: String) -> String {
      path.split(separator: "\\").last.map(String.init) ?? path
    }

    private static func basename(of entry: PROCESSENTRY32W) -> String {
      withUnsafePointer(to: entry.szExeFile) { pointer in
        pointer.withMemoryRebound(
          to: WCHAR.self,
          capacity: MemoryLayout.size(ofValue: entry.szExeFile) / MemoryLayout<WCHAR>.size
        ) {
          String(decodingCString: $0, as: UTF16.self)
        }
      }
    }

    private static func normalizePath(_ path: String) -> String {
      path.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(
        in: CharacterSet(charactersIn: "\\")
      )
    }
  }

  private enum WindowsProcessIdentityError: Error {
    case currentProcessPathUnavailable
    case processSnapshotUnavailable
    case processEnumerationFailed
  }
#endif
