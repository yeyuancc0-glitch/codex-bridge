import Foundation
import XCTest

@testable import BridgeSecurity

final class KeychainSecretStoreTests: XCTestCase {
  func testReferenceValidationAndGeneration() throws {
    XCTAssertThrowsError(try SecretReference(validating: ""))
    XCTAssertThrowsError(try SecretReference(validating: "contains/slash"))
    XCTAssertThrowsError(try SecretReference(validating: String(repeating: "a", count: 129)))

    let reference = SecretReference.random(prefix: "runtime-key")
    XCTAssertTrue(reference.rawValue.hasPrefix("runtime-key."))
    XCTAssertLessThanOrEqual(reference.rawValue.utf8.count, 128)

    let profileID = UUID()
    XCTAssertEqual(
      SecretReference.runtimeKey(profileID: profileID).rawValue,
      "tunnel-runtime-key.\(profileID.uuidString.lowercased())"
    )
    XCTAssertEqual(
      SecretReference.mcpPathSecret(profileID: profileID).rawValue,
      "mcp-path-secret.\(profileID.uuidString.lowercased())"
    )
  }

  func testRealKeychainRoundTripUpdateAndRemoval() throws {
    let store = KeychainSecretStore(service: "com.openai.codex-bridge.tests.\(UUID().uuidString)")
    let reference = SecretReference.random(prefix: "round-trip")
    let initial = Data("fixture-secret-one".utf8)
    let replacement = Data("fixture-secret-two".utf8)
    defer { try? store.remove(reference) }

    try store.store(initial, for: reference)
    XCTAssertEqual(try store.load(reference), initial)

    try store.store(replacement, for: reference)
    XCTAssertEqual(try store.load(reference), replacement)

    try store.remove(reference)
    XCTAssertThrowsError(try store.load(reference)) { error in
      XCTAssertEqual(error as? SecretStoreError, .notFound)
    }
  }

  func testRejectsInvalidSecretSizesBeforeKeychainAccess() {
    let store = KeychainSecretStore(service: "com.openai.codex-bridge.tests")
    let reference = SecretReference.random(prefix: "size")

    XCTAssertThrowsError(try store.store(Data(), for: reference)) { error in
      XCTAssertEqual(error as? SecretStoreError, .invalidSecret)
    }
    XCTAssertThrowsError(
      try store.store(
        Data(repeating: 0, count: KeychainSecretStore.maximumSecretBytes + 1),
        for: reference
      )
    ) { error in
      XCTAssertEqual(error as? SecretStoreError, .invalidSecret)
    }
  }
}
