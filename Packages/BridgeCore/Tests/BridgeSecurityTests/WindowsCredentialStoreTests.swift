#if os(Windows)
  import Foundation
  import Testing
  @testable import BridgeSecurity

  @Suite("Windows Credential Store")
  struct WindowsCredentialStoreTests {
    @Test("generic credential round trip")
    func genericCredentialRoundTrip() throws {
      let store = WindowsCredentialStore(
        service: "com.openai.codex-bridge.tests.\(UUID().uuidString.lowercased())")
      let reference = SecretReference(rawValue: "round-trip")
      let secret = Data("credential-round-trip".utf8)
      defer { try? store.remove(reference) }

      try store.store(secret, for: reference)
      #expect(try store.load(reference) == secret)
      try store.remove(reference)
      #expect(throws: SecretStoreError.notFound) {
        _ = try store.load(reference)
      }
    }
  }
#endif
