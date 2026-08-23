#if canImport(WinSDK)
  import BridgePlatform
  import Foundation
  import WinSDK

  /// Per-user service data layout for Windows, mirroring the macOS
  /// `ServiceDataPaths` semantics: an absolute local root plus fixed
  /// subdirectories, each carrying an owner-only protected DACL.
  ///
  /// `%LOCALAPPDATA%\CodexBridge\Service` is the default because the service
  /// runs inside the logged-in user session; a LocalSystem location would
  /// break Codex login, profile paths, and Credential Manager isolation.
  public struct WindowsServicePaths: Sendable {
    public enum PathsError: Error, Equatable, Sendable {
      case invalidRoot
      case unavailable(Int32)
      case insecureDirectory
    }

    private enum Constants {
      static let fileAttributeDirectory = DWORD(0x0000_0010)
      static let fileAttributeReparsePoint = DWORD(0x0000_0400)
      static let errorAlreadyExists = DWORD(183)
      static let errorFileNotFound = DWORD(2)
      static let errorPathNotFound = DWORD(3)
      static let errorSuccess = DWORD(0)
      static let tokenQuery = DWORD(0x0008)
      static let seFileObject: UInt32 = 1
      static let ownerSecurityInformation = 0x0000_0001
      static let daclSecurityInformation = 0x0000_0004
      static let seDaclProtected: UInt32 = 0x1000
      static let accessAllowedAceType: UInt8 = 0x00
      static let systemSIDString = "S-1-5-18"
    }

    public let rootURL: URL
    public let databaseURL: URL
    public let supervisorScratchURL: URL
    public let tunnelRuntimeURL: URL

    public init(
      rootURL: URL,
      databaseURL: URL,
      supervisorScratchURL: URL,
      tunnelRuntimeURL: URL
    ) {
      self.rootURL = rootURL
      self.databaseURL = databaseURL
      self.supervisorScratchURL = supervisorScratchURL
      self.tunnelRuntimeURL = tunnelRuntimeURL
    }

    public static func defaultRoot() -> URL {
      let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? ""
      return URL(fileURLWithPath: local, isDirectory: true)
        .appending(path: "CodexBridge", directoryHint: .isDirectory)
        .appending(path: "Service", directoryHint: .isDirectory)
    }

    public static func prepare(at requestedRoot: URL) throws -> WindowsServicePaths {
      guard isDriveAbsolute(requestedRoot.path) else {
        throw PathsError.invalidRoot
      }
      let root = requestedRoot.standardizedFileURL
      try prepareOwnerOnlyDirectory(root.path)
      let scratch = root.appending(path: "SupervisorScratch", directoryHint: .isDirectory)
      try prepareOwnerOnlyDirectory(scratch.path)
      let tunnelRuntime = root.appending(path: "TunnelRuntime", directoryHint: .isDirectory)
      try prepareOwnerOnlyDirectory(tunnelRuntime.path)
      return WindowsServicePaths(
        rootURL: root,
        databaseURL: root.appending(path: "service.sqlite"),
        supervisorScratchURL: scratch,
        tunnelRuntimeURL: tunnelRuntime
      )
    }

    // MARK: - Directory protection

    /// Creates or validates a directory only the current user (and SYSTEM)
    /// can reach. Pre-existing directories are audited, never silently
    /// widened: any allow-ACE outside the trusted pair fails closed, matching
    /// the macOS refusal to repair insecure data directories.
    static func prepareOwnerOnlyDirectory(_ path: String) throws {
      if !exists(path) {
        _ = try createOwnerOnlyDirectory(path)
      }
      let attributes = try fileAttributes(path)
      try rejectReparse(attributes)
      guard attributes & Constants.fileAttributeDirectory != 0 else {
        throw PathsError.insecureDirectory
      }
      guard try hasTrustedProtection(path) else {
        throw PathsError.insecureDirectory
      }
    }

    static func createOwnerOnlyDirectory(_ path: String) throws -> Bool {
      guard let currentUser = WindowsSecurity.currentUserSIDString() else {
        throw PathsError.unavailable(Int32(GetLastError()))
      }
      defer { LocalFree(UnsafeMutableRawPointer(currentUser.pointer)) }
      // D:P(...) = protected DACL; FA = FILE_ALL_ACCESS; SY = LOCAL SYSTEM.
      let sddl = "D:P(A;;FA;;;\(currentUser.value))(A;;FA;;;SY)"
      var descriptor: UnsafeMutableRawPointer?
      let sddlWide = WideBuffer(sddl)
      guard
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddlWide.pointer,
          1,
          &descriptor,
          nil
        ), let descriptor
      else {
        throw PathsError.unavailable(Int32(GetLastError()))
      }
      defer { LocalFree(descriptor) }

      var security = SECURITY_ATTRIBUTES(
        nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
        lpSecurityDescriptor: descriptor,
        bInheritHandle: false
      )
      let wide = WideBuffer(path)
      guard CreateDirectoryW(wide.pointer, &security) else {
        let code = GetLastError()
        if code == Constants.errorAlreadyExists { return false }
        throw PathsError.unavailable(Int32(code))
      }
      return true
    }

    private static func exists(_ path: String) -> Bool {
      let wide = WideBuffer(path)
      let value = GetFileAttributesW(wide.pointer)
      if value != INVALID_FILE_ATTRIBUTES {
        return true
      }
      let code = GetLastError()
      return code != Constants.errorFileNotFound && code != Constants.errorPathNotFound
    }

    private static func fileAttributes(_ path: String) throws -> DWORD {
      let wide = WideBuffer(path)
      let value = GetFileAttributesW(wide.pointer)
      guard value != INVALID_FILE_ATTRIBUTES else {
        throw PathsError.unavailable(Int32(GetLastError()))
      }
      return value
    }

    private static func rejectReparse(_ attributes: DWORD) throws {
      guard attributes & Constants.fileAttributeReparsePoint == 0 else {
        throw PathsError.insecureDirectory
      }
    }

    /// True when the DACL is protected and every allow-ACE names the current
    /// user or LOCAL SYSTEM.
    static func hasTrustedProtection(_ path: String) throws -> Bool {
      var descriptorPointer: UnsafeMutableRawPointer?
      var owner: PSID?
      var dacl: PACL?
      let result = GetNamedSecurityInfoW(
        WideBuffer(path).pointer,
        SE_OBJECT_TYPE(rawValue: Constants.seFileObject),
        DWORD(Constants.ownerSecurityInformation | Constants.daclSecurityInformation),
        &owner,
        nil,
        nil,
        nil,
        &dacl,
        &descriptorPointer
      )
      guard result == Constants.errorSuccess, let descriptorPointer else {
        throw PathsError.unavailable(Int32(GetLastError()))
      }
      defer { LocalFree(descriptorPointer) }

      guard
        let currentUser = WindowsSecurity.currentUserSIDString()
      else {
        throw PathsError.unavailable(Int32(GetLastError()))
      }
      defer { LocalFree(UnsafeMutableRawPointer(currentUser.pointer)) }

      var daclPresent = false
      var daclDefaulted = false
      guard GetSecurityDescriptorDacl(descriptorPointer, &daclPresent, &dacl, &daclDefaulted)
      else { return false }
      var control = SECURITY_DESCRIPTOR_CONTROL()
      var revision = DWORD(0)
      _ = GetSecurityDescriptorControl(descriptorPointer, &control, &revision)
      guard daclPresent, let dacl,
        (control.rawValue & Constants.seDaclProtected) != 0
      else { return false }

      var sizeInfo = ACL_SIZE_INFORMATION()
      guard
        GetAclInformation(
          dacl,
          &sizeInfo,
          DWORD(MemoryLayout<ACL_SIZE_INFORMATION>.size),
          AclSizeInformation
        )
      else { return false }

      for index in 0..<sizeInfo.AceCount {
        var acePointer: UnsafeMutableRawPointer?
        guard GetAce(dacl, DWORD(index), &acePointer), let acePointer else { return false }
        let header = acePointer.load(as: ACE_HEADER.self)
        guard header.AceType == Constants.accessAllowedAceType else { continue }
        // ACCESS_ALLOWED_ACE layout: ACE_HEADER (4 bytes) + DWORD mask,
        // so the SID starts at byte 8 regardless of pointer width.
        let sid = UnsafeRawPointer(acePointer).advanced(by: 8)
          .bindMemory(to: SID.self, capacity: 1)
        guard let sidBox = stringSIDBox(ofSID: sid) else {
          return false
        }
        defer { LocalFree(UnsafeMutableRawPointer(sidBox.pointer)) }
        guard sidBox.value == currentUser.value || sidBox.value == Constants.systemSIDString
        else {
          return false
        }
      }
      return true
    }

    private static func stringSIDBox(ofSID sid: PSID) -> WideStringBox? {
      var stringSID: UnsafeMutablePointer<WCHAR>?
      guard ConvertSidToStringSidW(sid, &stringSID), let stringSID else { return nil }
      return WideStringBox(pointer: stringSID)
    }

    private static func isDriveAbsolute(_ path: String) -> Bool {
      let units = Array(path.utf16)
      guard units.count >= 3 else { return false }
      return units[1] == 58 && units[2] == 92
        && ((65...90).contains(Int(units[0])) || (97...122).contains(Int(units[0])))
    }
  }
#endif
