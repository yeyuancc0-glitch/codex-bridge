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
      static let errorSuccess = DWORD(0)
      static let fileReadAttributes = DWORD(0x0000_0080)
      static let readControl = DWORD(0x0002_0000)
      static let directoryShare = DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE)
      static let directoryFlags = DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
      static let driveFixed: UInt32 = 3
      static let seFileObject: UInt32 = 1
      static let ownerSecurityInformation = 0x0000_0001
      static let daclSecurityInformation = 0x0000_0004
      static let seDaclProtected: UInt32 = 0x1000
      static let accessAllowedAceType: UInt8 = 0x00
      static let accessAllowedCompoundAceType: UInt8 = 0x04
      static let accessAllowedObjectAceType: UInt8 = 0x05
      static let accessAllowedCallbackAceType: UInt8 = 0x09
      static let accessAllowedCallbackObjectAceType: UInt8 = 0x0B
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
      guard let rootPath = localDrivePath(requestedRoot) else {
        throw PathsError.invalidRoot
      }
      let rootLeases = try prepareOwnerOnlyDirectoryTree(rootPath)
      let scratchPath = join(rootPath, "SupervisorScratch")
      let scratchLeases = try prepareOwnerOnlyDirectory(
        scratchPath, preserving: rootLeases
      )
      let tunnelRuntimePath = join(rootPath, "TunnelRuntime")
      let tunnelLeases = try prepareOwnerOnlyDirectory(
        tunnelRuntimePath, preserving: rootLeases
      )
      let leases = rootLeases + scratchLeases + tunnelLeases
      return withExtendedLifetime(leases) {
        WindowsServicePaths(
          rootURL: URL(fileURLWithPath: rootPath, isDirectory: true),
          databaseURL: URL(fileURLWithPath: join(rootPath, "service.sqlite")),
          supervisorScratchURL: URL(fileURLWithPath: scratchPath, isDirectory: true),
          tunnelRuntimeURL: URL(fileURLWithPath: tunnelRuntimePath, isDirectory: true)
        )
      }
    }

    // MARK: - Directory protection

    private final class ObjectHandleLease: @unchecked Sendable {
      let value: HANDLE

      init(_ value: HANDLE) {
        self.value = value
      }

      deinit {
        CloseHandle(value)
      }
    }

    private static func prepareOwnerOnlyDirectoryTree(
      _ path: String
    ) throws -> [ObjectHandleLease] {
      guard let segments = localDriveSegments(path) else { throw PathsError.invalidRoot }
      var current = String(path.prefix(3))
      var leases = [try openDirectoryLease(current)]
      for segment in segments {
        current = join(current, segment)
        let parent = leases[leases.count - 1]
        let (lease, created) = try openOrCreateDirectory(current, preserving: parent)
        if created {
          try validateOwnerOnlyDirectory(lease)
        }
        leases.append(lease)
      }
      guard let leaf = leases.last else { throw PathsError.invalidRoot }
      try validateOwnerOnlyDirectory(leaf)
      return leases
    }

    /// Creates or validates a directory only the current user (and SYSTEM)
    /// can reach. Pre-existing directories are audited, never silently
    /// widened: any allow-ACE outside the trusted pair fails closed, matching
    /// the macOS refusal to repair insecure data directories.
    static func prepareOwnerOnlyDirectory(_ path: String) throws {
      guard let path = normalizedDrivePath(path), isFixedDrive(path) else {
        throw PathsError.invalidRoot
      }
      _ = try prepareOwnerOnlyDirectoryTree(path)
    }

    private static func prepareOwnerOnlyDirectory(
      _ path: String,
      preserving parentLeases: [ObjectHandleLease]
    ) throws -> [ObjectHandleLease] {
      guard let parent = parentLeases.last else { throw PathsError.invalidRoot }
      let (lease, _) = try openOrCreateDirectory(path, preserving: parent)
      try validateOwnerOnlyDirectory(lease)
      return parentLeases + [lease]
    }

    private static func validateOwnerOnlyDirectory(_ lease: ObjectHandleLease) throws {
      try validateDirectoryNode(lease)
      guard try hasTrustedProtection(lease) else {
        throw PathsError.insecureDirectory
      }
    }

    private static func validateDirectoryNode(_ lease: ObjectHandleLease) throws {
      var info = FILE_ATTRIBUTE_TAG_INFO()
      guard
        GetFileInformationByHandleEx(
          lease.value,
          FileAttributeTagInfo,
          &info,
          DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)
        )
      else {
        throw PathsError.unavailable(Int32(GetLastError()))
      }
      try rejectReparse(info.FileAttributes)
      guard info.FileAttributes & Constants.fileAttributeDirectory != 0 else {
        throw PathsError.insecureDirectory
      }
    }

    private static func openOrCreateDirectory(
      _ path: String,
      preserving parent: ObjectHandleLease
    ) throws -> (ObjectHandleLease, Bool) {
      var created = false
      try withExtendedLifetime(parent) {
        created = try createOwnerOnlyDirectory(path)
      }
      return (try openDirectoryLease(path), created)
    }

    private static func openDirectoryLease(_ path: String) throws -> ObjectHandleLease {
      let lease = try openObjectLease(path)
      try validateDirectoryNode(lease)
      return lease
    }

    private static func openObjectLease(_ path: String) throws -> ObjectHandleLease {
      let wide = WideBuffer(path)
      let handle = CreateFileW(
        wide.pointer,
        Constants.fileReadAttributes | Constants.readControl,
        Constants.directoryShare,
        nil,
        DWORD(OPEN_EXISTING),
        Constants.directoryFlags,
        nil
      )
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw PathsError.unavailable(Int32(GetLastError()))
      }
      return ObjectHandleLease(handle)
    }

    static func createOwnerOnlyDirectory(_ path: String) throws -> Bool {
      guard let currentUser = WindowsSecurity.currentUserSIDString() else {
        throw PathsError.unavailable(Int32(GetLastError()))
      }
      // Elevated tokens can otherwise default ownership to Administrators.
      let sddl = WindowsSecurity.ownerOnlySDDL(userSID: currentUser.value)
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

    private static func rejectReparse(_ attributes: DWORD) throws {
      guard attributes & Constants.fileAttributeReparsePoint == 0 else {
        throw PathsError.insecureDirectory
      }
    }

    /// True when the DACL is protected and every allow-ACE names the current
    /// user or LOCAL SYSTEM.
    public static func hasTrustedProtection(_ path: String) throws -> Bool {
      guard let path = normalizedDrivePath(path), isFixedDrive(path) else {
        throw PathsError.invalidRoot
      }
      return try hasTrustedProtection(openObjectLease(path))
    }

    private static func hasTrustedProtection(_ lease: ObjectHandleLease) throws -> Bool {
      var descriptorPointer: UnsafeMutableRawPointer?
      var owner: PSID?
      var dacl: PACL?
      let result = GetSecurityInfo(
        lease.value,
        SE_OBJECT_TYPE(rawValue: Int32(Constants.seFileObject)),
        DWORD(Constants.ownerSecurityInformation | Constants.daclSecurityInformation),
        &owner,
        nil,
        &dacl,
        nil,
        &descriptorPointer
      )
      guard result == Constants.errorSuccess, let descriptorPointer else {
        throw PathsError.unavailable(Int32(result))
      }
      defer { LocalFree(descriptorPointer) }

      guard
        let currentUser = WindowsSecurity.currentUserSIDString()
      else {
        throw PathsError.unavailable(Int32(GetLastError()))
      }
      guard let owner, let ownerSID = stringSIDBox(ofSID: owner),
        ownerSID.value.caseInsensitiveCompare(currentUser.value) == .orderedSame
      else { return false }
      var daclPresent = WindowsBool(false)
      var daclDefaulted = WindowsBool(false)
      guard GetSecurityDescriptorDacl(descriptorPointer, &daclPresent, &dacl, &daclDefaulted)
      else { return false }
      var control = SECURITY_DESCRIPTOR_CONTROL()
      var revision = DWORD(0)
      _ = GetSecurityDescriptorControl(descriptorPointer, &control, &revision)
      guard daclPresent.boolValue, let dacl,
        (control & UInt16(Constants.seDaclProtected)) != 0
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
        guard header.AceType == Constants.accessAllowedAceType else {
          if isNonBasicAllowACEType(header.AceType) { return false }
          continue
        }
        // ACCESS_ALLOWED_ACE layout: ACE_HEADER (4 bytes) + DWORD mask,
        // so the SID starts at byte 8 regardless of pointer width.
        let sid = acePointer.advanced(by: 8)
        guard let sidBox = stringSIDBox(ofSID: sid) else {
          return false
        }
        guard sidBox.value == currentUser.value || sidBox.value == Constants.systemSIDString
        else {
          return false
        }
      }
      return true
    }

    static func isNonBasicAllowACEType(_ type: UInt8) -> Bool {
      switch type {
      case Constants.accessAllowedCompoundAceType,
        Constants.accessAllowedObjectAceType,
        Constants.accessAllowedCallbackAceType,
        Constants.accessAllowedCallbackObjectAceType:
        true
      default:
        false
      }
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

    static func isFixedDrive(_ path: String) -> Bool {
      guard isDriveAbsolute(path) else { return false }
      let wide = WideBuffer(String(path.prefix(3)))
      return GetDriveTypeW(wide.pointer) == Constants.driveFixed
    }

    /// Swift Foundation represents a native `C:\...` file URL as `/C:/...`
    /// on some Windows toolchains. Normalize that URL spelling before passing
    /// the path to Win32, without accepting network or non-file URLs.
    private static func localDrivePath(_ url: URL) -> String? {
      guard url.isFileURL else { return nil }
      guard let path = normalizedDrivePath(url.path) else { return nil }
      guard isFixedDrive(path), !path.contains("\0"),
        path.rangeOfCharacter(from: .controlCharacters) == nil,
        localDriveSegments(path) != nil
      else { return nil }
      return path
    }

    private static func normalizedDrivePath(_ rawPath: String) -> String? {
      var path = rawPath.replacingOccurrences(of: "/", with: "\\")
      let units = Array(path.utf16)
      if units.count >= 4, units[0] == 92, units[2] == 58, units[3] == 92,
        (65...90).contains(Int(units[1])) || (97...122).contains(Int(units[1]))
      {
        path.removeFirst()
      }
      while path.count > 3, path.hasSuffix("\\") { path.removeLast() }
      return isDriveAbsolute(path) ? path : nil
    }

    private static func localDriveSegments(_ path: String) -> [String]? {
      guard isDriveAbsolute(path) else { return nil }
      let tail = path.dropFirst(3)
      if tail.isEmpty { return [] }
      let segments = tail.split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
      guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        return nil
      }
      return segments
    }

    private static func join(_ root: String, _ component: String) -> String {
      root.hasSuffix("\\") ? root + component : root + "\\" + component
    }
  }
#endif
