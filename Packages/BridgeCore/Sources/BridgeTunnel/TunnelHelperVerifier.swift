import Crypto
import Darwin
import Foundation
import Security

public struct TunnelCodeIdentity: Equatable, Sendable {
  fileprivate let codeDirectoryHash: Data

  public init(codeDirectoryHash: Data) {
    self.codeDirectoryHash = codeDirectoryHash
  }
}

public protocol TunnelCodeSignatureVerifier: Sendable {
  func verifyStatic(executableDescriptor: Int32) throws -> TunnelCodeIdentity
  func verifyDynamic(processID: Int32, expectedIdentity: TunnelCodeIdentity) throws
}

public struct MacOSTunnelCodeSignatureVerifier: TunnelCodeSignatureVerifier {
  private let requiresHostTeam: Bool

  public init() {
    requiresHostTeam = true
  }

  package init(requiresHostTeam: Bool) {
    self.requiresHostTeam = requiresHostTeam
  }

  public func verifyStatic(executableDescriptor: Int32) throws -> TunnelCodeIdentity {
    let requirement = try sameTeamRequirement()
    let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(executableDescriptor)")
    var code: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(descriptorURL as CFURL, [], &code) == errSecSuccess,
      let code
    else {
      throw TunnelHelperError.signatureInvalid
    }
    let flags = SecCSFlags(
      rawValue: UInt32(
        requirement != nil
          ? (kSecCSStrictValidate | kSecCSCheckAllArchitectures)
          : kSecCSCheckAllArchitectures
      )
    )
    guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
      throw TunnelHelperError.signatureInvalid
    }
    return try identity(of: code)
  }

  public func verifyDynamic(
    processID: Int32,
    expectedIdentity: TunnelCodeIdentity
  ) throws {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: processID)] as CFDictionary
    guard
      SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
      let code
    else {
      throw TunnelHelperError.signatureInvalid
    }
    let requirement = try sameTeamRequirement()
    let flags = SecCSFlags(
      rawValue: UInt32(requirement != nil ? kSecCSStrictValidate : 0)
    )
    guard SecCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
      throw TunnelHelperError.signatureInvalid
    }
    guard try identity(of: staticCode(for: code)) == expectedIdentity else {
      throw TunnelHelperError.identityMismatch
    }
  }

  private func sameTeamRequirement() throws -> SecRequirement? {
    guard requiresHostTeam else { return nil }
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
      return nil
    }
    let signingFlags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
    guard let information = try? signingInformation(of: staticCode(for: code), flags: signingFlags),
      let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
      !team.isEmpty,
      team.utf8.allSatisfy({ byte in
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
          || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
      })
    else {
      return nil
    }
    let source = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else {
      throw TunnelHelperError.hostSignatureUnavailable
    }
    return requirement
  }

  private func identity(of code: SecStaticCode) throws -> TunnelCodeIdentity {
    let information = try signingInformation(of: code, flags: [])
    guard let hash = information[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else {
      throw TunnelHelperError.signatureInvalid
    }
    return TunnelCodeIdentity(codeDirectoryHash: hash)
  }

  private func staticCode(for code: SecCode) throws -> SecStaticCode {
    var result: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &result) == errSecSuccess, let result else {
      throw TunnelHelperError.signatureInvalid
    }
    return result
  }

  private func signingInformation(
    of code: SecStaticCode,
    flags: SecCSFlags
  ) throws -> [String: Any] {
    var raw: CFDictionary?
    guard
      SecCodeCopySigningInformation(code, flags, &raw) == errSecSuccess,
      let information = raw as? [String: Any]
    else {
      throw TunnelHelperError.signatureInvalid
    }
    return information
  }
}

public struct TunnelHelperVerifier: Sendable {
  private let codeSignatureVerifier: any TunnelCodeSignatureVerifier

  public init(
    codeSignatureVerifier: any TunnelCodeSignatureVerifier = MacOSTunnelCodeSignatureVerifier()
  ) {
    self.codeSignatureVerifier = codeSignatureVerifier
  }

  package func verify(executable: URL, expectedSHA256: String) throws -> TunnelVerifiedHelper {
    let descriptor = open(executable.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw TunnelHelperError.unavailable }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else { throw TunnelHelperError.unavailable }
    guard (metadata.st_mode & S_IFMT) == S_IFREG else { throw TunnelHelperError.notRegularFile }
    guard metadata.st_mode & 0o111 != 0 else { throw TunnelHelperError.notExecutable }
    let digest = try hash(descriptor)
    guard digest == expectedSHA256 else { throw TunnelHelperError.digestMismatch }
    let identity = try codeSignatureVerifier.verifyStatic(executableDescriptor: descriptor)
    return TunnelVerifiedHelper(executable: executable, codeIdentity: identity)
  }

  package func verifyRunning(
    processID: Int32,
    expectedIdentity: TunnelCodeIdentity
  ) throws {
    try codeSignatureVerifier.verifyDynamic(
      processID: processID,
      expectedIdentity: expectedIdentity
    )
  }

  private func hash(_ descriptor: Int32) throws -> String {
    let duplicate = dup(descriptor)
    guard duplicate >= 0 else { throw TunnelHelperError.unavailable }
    let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 64 * 1024) ?? Data()
      guard !data.isEmpty else { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

package struct TunnelVerifiedHelper: Sendable {
  let executable: URL
  let codeIdentity: TunnelCodeIdentity
}

public enum TunnelHelperError: Error, Equatable, Sendable {
  case unavailable
  case notRegularFile
  case notExecutable
  case digestMismatch
  case hostSignatureUnavailable
  case signatureInvalid
  case identityMismatch
}
