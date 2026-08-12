import CryptoKit
import Foundation
import XCTest

@testable import BridgeTunnel

final class TunnelHelperVerifierTests: XCTestCase {
  func testRejectsDigestMismatchSymlinkAndNonExecutable() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("helper")
    try Data("fixture".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let verifier = TunnelHelperVerifier(codeSignatureVerifier: IdentityVerifier())
    XCTAssertThrowsError(
      try verifier.verify(executable: executable, expectedSHA256: String(repeating: "0", count: 64))
    ) { XCTAssertEqual($0 as? TunnelHelperError, .digestMismatch) }

    let digest = SHA256.hash(data: Data("fixture".utf8)).map { String(format: "%02x", $0) }.joined()
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
    XCTAssertThrowsError(try verifier.verify(executable: executable, expectedSHA256: digest)) {
      XCTAssertEqual($0 as? TunnelHelperError, .notExecutable)
    }

    let symlink = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: executable)
    XCTAssertThrowsError(try verifier.verify(executable: symlink, expectedSHA256: digest))
  }
}

private struct IdentityVerifier: TunnelCodeSignatureVerifier {
  func verifyStatic(executableDescriptor _: Int32) throws -> TunnelCodeIdentity {
    TunnelCodeIdentity(codeDirectoryHash: Data("fixture".utf8))
  }

  func verifyDynamic(processID _: Int32, expectedIdentity _: TunnelCodeIdentity) throws {}
}
