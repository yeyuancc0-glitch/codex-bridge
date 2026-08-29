public enum SecretStoreFactory {
  /// Platform default secret backend: Keychain on macOS, Credential Manager
  /// on Windows.
  public static func defaultStore() -> any SecretStore {
    #if canImport(Security)
      return KeychainSecretStore()
    #elseif os(Windows)
      return WindowsCredentialStore()
    #else
      fatalError("No SecretStore backend for this platform")
    #endif
  }
}
