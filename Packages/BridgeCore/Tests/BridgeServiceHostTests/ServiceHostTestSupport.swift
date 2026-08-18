import BridgeCodexRPC
import BridgeIPC
import BridgeMCP
import BridgeSecurity
import BridgeServiceHost
import Darwin
import Foundation
import XCTest

final class ServiceHostTestSecretStore: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [SecretReference: Data] = [:]

  func store(_ secret: Data, for reference: SecretReference) throws {
    guard !secret.isEmpty else { throw SecretStoreError.invalidSecret }
    lock.lock()
    values[reference] = secret
    lock.unlock()
  }

  func load(_ reference: SecretReference) throws -> Data {
    lock.lock()
    let value = values[reference]
    lock.unlock()
    guard let value else { throw SecretStoreError.notFound }
    return value
  }

  func remove(_ reference: SecretReference) throws {
    lock.lock()
    let removed = values.removeValue(forKey: reference)
    lock.unlock()
    guard removed != nil else { throw SecretStoreError.notFound }
  }
}

struct ServiceHostFixture {
  let root: URL
  let secrets: ServiceHostTestSecretStore
  let composition: ServiceComposition
}

func makeServiceHostFixture(
  _ testCase: XCTestCase,
  startMCP: Bool = false,
  catalogAppServer: AppServerConfiguration? = nil
) async throws -> ServiceHostFixture {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "bridge-service-host-tests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  let secrets = ServiceHostTestSecretStore()
  let unavailable = AppServerConfiguration(
    executableURL: URL(fileURLWithPath: "/bin/false"),
    arguments: []
  )
  let composition = try await ServiceComposition.make(
    configuration: ServiceCompositionConfiguration(
      appVersion: "0.2.0",
      dataRootURL: root,
      executionAppServer: unavailable,
      supervisorAppServer: unavailable,
      catalogAppServer: catalogAppServer ?? unavailable,
      clientInfo: .bridge(version: "service-host-tests")
    ),
    secretStore: secrets,
    randomBytes: { count in
      Data(
        (0..<count).map { UInt8(($0 + 17) % 255) }
      )
    }
  )
  testCase.addTeardownBlock {
    await composition.shutdown()
    try? FileManager.default.removeItem(at: root)
  }
  if startMCP {
    _ = try await composition.startLocalMCP()
  }
  return ServiceHostFixture(root: root, secrets: secrets, composition: composition)
}

func xpcClient(
  composition: ServiceComposition
) -> (BridgeServiceClient, BridgeServiceXPCListener) {
  let listener = BridgeServiceXPCListener(
    mode: .anonymous,
    composition: composition
  )
  listener.resume()
  guard let endpoint = listener.endpoint else {
    preconditionFailure("Anonymous XPC listener must expose an endpoint.")
  }
  return (BridgeServiceClient(endpoint: endpoint), listener)
}

func fileMode(_ url: URL) throws -> mode_t {
  var metadata = stat()
  guard lstat(url.path, &metadata) == 0 else {
    throw ServiceDataPathsError.systemFailure(errno)
  }
  return metadata.st_mode & 0o777
}
