import Crypto
import Foundation
import XCTest

// Golden vectors pin the SHA-256 digest format shared by approval evidence,
// project command stable IDs, and file revisions. swift-crypto must produce
// byte-identical digests on every supported host platform.
final class CryptoGoldenVectorTests: XCTestCase {
  private static let vectors: [(input: String, hex: String)] = [
    ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
    ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
    (
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    ),
  ]

  func testSHA256MatchesNISTGoldenVectors() {
    for vector in Self.vectors {
      let digest = SHA256.hash(data: Data(vector.input.utf8))
      let hex = digest.map { String(format: "%02x", $0) }.joined()
      XCTAssertEqual(hex, vector.hex, "digest drift for input \(vector.input)")
    }
  }

  func testSHA256DigestLengthIsStable() {
    let digest = Data(SHA256.hash(data: Data("codex-bridge".utf8)))
    XCTAssertEqual(digest.count, 32)
  }
}
