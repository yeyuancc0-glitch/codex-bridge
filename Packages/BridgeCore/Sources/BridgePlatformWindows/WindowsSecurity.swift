#if canImport(WinSDK)
  import Foundation
  import WinSDK

  /// Shared Win32 string/SID plumbing for the Windows platform modules.
  public enum WindowsSecurity {
    public static let tokenQuery = DWORD(0x0008)

    public static func currentUserSIDString() -> WideStringBox? {
      var token: HANDLE?
      guard OpenProcessToken(GetCurrentProcess(), tokenQuery, &token), let token else {
        return nil
      }
      defer { CloseHandle(token) }
      return stringSID(ofToken: token)
    }

    public static func processUserSIDString(_ process: HANDLE) -> WideStringBox? {
      var token: HANDLE?
      guard OpenProcessToken(process, tokenQuery, &token), let token else { return nil }
      defer { CloseHandle(token) }
      return stringSID(ofToken: token)
    }

    public static func stringSID(ofToken token: HANDLE) -> WideStringBox? {
      var returnedLength = DWORD(0)
      _ = GetTokenInformation(
        token, TOKEN_INFORMATION_CLASS(rawValue: TokenUser.rawValue), nil, 0, &returnedLength
      )
      guard returnedLength > 0 else { return nil }
      let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(returnedLength),
        alignment: MemoryLayout<Int>.alignment
      )
      defer { buffer.deallocate() }
      guard
        GetTokenInformation(
          token,
          TOKEN_INFORMATION_CLASS(rawValue: TokenUser.rawValue),
          buffer,
          returnedLength,
          &returnedLength
        )
      else { return nil }
      let sid = buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid
      guard let sid else { return nil }
      var stringSID: UnsafeMutablePointer<WCHAR>?
      guard ConvertSidToStringSidW(sid, &stringSID), let stringSID else { return nil }
      return WideStringBox(pointer: stringSID)
    }

    /// SDDL protected DACL granting full access only to the given user and
    /// LOCAL SYSTEM.
    public static func ownerOnlySDDL(userSID: String) -> String {
      "D:P(A;;GA;;;\(userSID))(A;;GA;;;SY)"
    }
  }

  public final class WideStringBox: @unchecked Sendable {
    public let pointer: UnsafeMutablePointer<WCHAR>

    public init(pointer: UnsafeMutablePointer<WCHAR>) {
      self.pointer = pointer
    }

    public var value: String {
      var units: [UInt16] = []
      var index = 0
      while pointer[index] != 0 {
        units.append(UInt16(pointer[index]))
        index += 1
      }
      return String(decoding: units, as: UTF16.self)
    }

    deinit {
      LocalFree(UnsafeMutableRawPointer(pointer))
    }
  }

  public final class WideBuffer: @unchecked Sendable {
    public let pointer: UnsafeMutablePointer<WCHAR>

    public init(_ value: String) {
      var units = Array(value.utf16)
      units.append(0)
      pointer = .allocate(capacity: units.count)
      units.withUnsafeBufferPointer { buffer in
        pointer.initialize(from: buffer.baseAddress!, count: buffer.count)
      }
    }

    deinit {
      pointer.deallocate()
    }
  }
#endif
