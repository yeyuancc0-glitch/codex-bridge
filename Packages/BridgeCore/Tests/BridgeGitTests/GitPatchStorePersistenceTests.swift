import Darwin
import Foundation
import XCTest

@testable import BridgeGit

final class GitPatchStorePersistenceTests: XCTestCase {
  func testPersistentPatchSurvivesRestartAndEvictsLeastRecentlyUsedDocument() async throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let first = try GitPatchStore(
      persistentDirectory: directory,
      maximumDocumentCount: 2,
      maximumStoredBytes: 1_024,
      maximumPageBytes: 64
    )
    let oldest = try await first.store(Data("oldest".utf8), isTruncated: false)
    try await Task.sleep(for: .milliseconds(2))
    let retained = try await first.store(Data("retained".utf8), isTruncated: false)

    let reopened = try GitPatchStore(
      persistentDirectory: directory,
      maximumDocumentCount: 2,
      maximumStoredBytes: 1_024,
      maximumPageBytes: 64
    )
    let restored = try await reopened.page(for: retained)
    XCTAssertEqual(String(decoding: restored.bytes, as: UTF8.self), "retained")

    let afterAccessRestart = try GitPatchStore(
      persistentDirectory: directory,
      maximumDocumentCount: 2,
      maximumStoredBytes: 1_024,
      maximumPageBytes: 64
    )
    _ = try await afterAccessRestart.store(Data("newest".utf8), isTruncated: false)
    do {
      _ = try await afterAccessRestart.page(for: oldest)
      XCTFail("Expected the least recently used patch to be evicted")
    } catch {
      XCTAssertEqual(error as? GitEvidenceError, .patchNotFound)
    }
    let stillRetained = try await afterAccessRestart.page(for: retained)
    XCTAssertEqual(String(decoding: stillRetained.bytes, as: UTF8.self), "retained")
  }

  func testPersistentPatchIsVerifiedOnceThenPagedFromBoundedSnapshot() async throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let original = Data("first page|second page".utf8)
    let store = try GitPatchStore(
      persistentDirectory: directory,
      maximumStoredBytes: 1_024,
      maximumPageBytes: 10
    )
    let handle = try await store.store(original, isTruncated: false)

    let first = try await store.page(for: handle)
    XCTAssertEqual(first.bytes, original.prefix(10))

    let path = directory.appendingPathComponent(handle.rawValue)
    try Data(repeating: Character("x").asciiValue!, count: original.count).write(to: path)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: path.path
    )
    let second = try await store.page(for: handle, offset: 10)
    XCTAssertEqual(second.bytes, original.dropFirst(10).prefix(10))

    let reopened = try GitPatchStore(persistentDirectory: directory)
    do {
      _ = try await reopened.page(for: handle)
      XCTFail("Expected a restart to verify the persisted digest again")
    } catch {
      XCTAssertEqual(error as? GitEvidenceError, .patchNotFound)
    }
  }

  func testPersistentPatchRejectsContentReplacement() async throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let store = try GitPatchStore(persistentDirectory: directory)
    let handle = try await store.store(Data("trusted patch".utf8), isTruncated: false)
    let path = directory.appendingPathComponent(handle.rawValue)
    try Data("forged patch!".utf8).write(to: path)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: path.path
    )

    do {
      _ = try await store.page(for: handle)
      XCTFail("Expected the patch digest to bind the stored bytes")
    } catch {
      XCTAssertEqual(error as? GitEvidenceError, .patchNotFound)
    }
  }

  func testFailedNewWritePreservesExistingPatch() async throws {
    let directory = temporaryDirectory()
    addTeardownBlock {
      _ = chmod(directory.path, S_IRWXU)
      try? FileManager.default.removeItem(at: directory)
    }
    let store = try GitPatchStore(
      persistentDirectory: directory,
      maximumDocumentCount: 1,
      maximumStoredBytes: 1_024
    )
    let retained = try await store.store(Data("retained".utf8), isTruncated: false)
    XCTAssertEqual(chmod(directory.path, S_IRUSR | S_IXUSR), 0)

    do {
      _ = try await store.store(Data("replacement".utf8), isTruncated: false)
      XCTFail("Expected the new durable write to fail")
    } catch {
      XCTAssertEqual(error as? GitEvidenceError, .patchStoreCapacityExceeded)
    }
    let page = try await store.page(for: retained)
    XCTAssertEqual(String(decoding: page.bytes, as: UTF8.self), "retained")
  }

  func testFailedTrimRollsBackNewPatchAndPreservesBudget() async throws {
    let directory = temporaryDirectory()
    addTeardownBlock {
      if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
        for name in names {
          _ = chflags(directory.appendingPathComponent(name).path, 0)
        }
      }
      try? FileManager.default.removeItem(at: directory)
    }
    let store = try GitPatchStore(
      persistentDirectory: directory,
      maximumDocumentCount: 1,
      maximumStoredBytes: 1_024
    )
    let retained = try await store.store(Data("retained".utf8), isTruncated: false)
    let retainedPath = directory.appendingPathComponent(retained.rawValue)
    XCTAssertEqual(chflags(retainedPath.path, UInt32(UF_IMMUTABLE)), 0)

    do {
      _ = try await store.store(Data("replacement".utf8), isTruncated: false)
      XCTFail("Expected immutable LRU victim to reject the trim")
    } catch {
      XCTAssertEqual(error as? GitEvidenceError, .patchStoreCapacityExceeded)
    }
    XCTAssertEqual(try patchDocumentCount(in: directory), 1)
    XCTAssertEqual(chflags(retainedPath.path, 0), 0)
    let page = try await store.page(for: retained)
    XCTAssertEqual(String(decoding: page.bytes, as: UTF8.self), "retained")
  }

  func testTrimPreflightPreservesEveryVictimWhenLaterVictimIsImmutable() async throws {
    let directory = temporaryDirectory()
    addTeardownBlock {
      if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
        for name in names {
          _ = chflags(directory.appendingPathComponent(name).path, 0)
        }
      }
      try? FileManager.default.removeItem(at: directory)
    }
    let store = try GitPatchStore(
      persistentDirectory: directory,
      maximumDocumentCount: 3,
      maximumStoredBytes: 250
    )
    let oldest = try await store.store(Data(repeating: 1, count: 100), isTruncated: false)
    try await Task.sleep(for: .milliseconds(2))
    let immutable = try await store.store(Data(repeating: 2, count: 100), isTruncated: false)
    let immutablePath = directory.appendingPathComponent(immutable.rawValue)
    XCTAssertEqual(chflags(immutablePath.path, UInt32(UF_IMMUTABLE)), 0)

    do {
      _ = try await store.store(Data(repeating: 3, count: 180), isTruncated: false)
      XCTFail("Expected the complete trim transaction to fail before removing any victim")
    } catch {
      XCTAssertEqual(error as? GitEvidenceError, .patchStoreCapacityExceeded)
    }
    XCTAssertEqual(try patchDocumentCount(in: directory), 2)
    XCTAssertEqual(chflags(immutablePath.path, 0), 0)
    let oldestPage = try await store.page(for: oldest)
    let immutablePage = try await store.page(for: immutable)
    XCTAssertEqual(oldestPage.bytes.count, 100)
    XCTAssertEqual(immutablePage.bytes.count, 100)
  }

  func testPersistentInstancesReloadUnderSharedLockAndPreserveGlobalBudget() async throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let first = try GitPatchStore(
      persistentDirectory: directory,
      maximumDocumentCount: 1,
      maximumStoredBytes: 1_024
    )
    let second = try GitPatchStore(
      persistentDirectory: directory,
      maximumDocumentCount: 1,
      maximumStoredBytes: 1_024
    )

    async let firstHandle = first.store(Data("first".utf8), isTruncated: false)
    async let secondHandle = second.store(Data("second".utf8), isTruncated: false)
    let resolvedHandles = try await (firstHandle, secondHandle)
    let handles = [resolvedHandles.0, resolvedHandles.1]

    XCTAssertEqual(try patchDocumentCount(in: directory), 1)
    let reopened = try GitPatchStore(
      persistentDirectory: directory,
      maximumDocumentCount: 1,
      maximumStoredBytes: 1_024
    )
    var readableCount = 0
    for handle in handles {
      if (try? await reopened.page(for: handle)) != nil { readableCount += 1 }
    }
    XCTAssertEqual(readableCount, 1)
  }

  func testCommittedTrashIsNeverRestoredAfterPartialGarbageCollection() async throws {
    let directory = temporaryDirectory()
    addTeardownBlock {
      if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
        for name in names {
          _ = chflags(directory.appendingPathComponent(name).path, 0)
        }
      }
      try? FileManager.default.removeItem(at: directory)
    }
    let store = try GitPatchStore(
      persistentDirectory: directory,
      maximumDocumentCount: 3,
      maximumStoredBytes: 1_024
    )
    let first = try await store.store(Data("first".utf8), isTruncated: false)
    let second = try await store.store(Data("second".utf8), isTruncated: false)
    let transaction = String(repeating: "a", count: 32)
    let originals = [first.rawValue, second.rawValue].sorted()
    let staged = originals.map { ".trash_\(transaction)_\($0)" }
    for (original, temporary) in zip(originals, staged) {
      try FileManager.default.moveItem(
        at: directory.appendingPathComponent(original),
        to: directory.appendingPathComponent(temporary)
      )
    }
    let marker = directory.appendingPathComponent(".commit_\(transaction)")
    try Data().write(to: marker, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: marker.path
    )
    let blockedTrash = directory.appendingPathComponent(staged[1])
    XCTAssertEqual(chflags(blockedTrash.path, UInt32(UF_IMMUTABLE)), 0)

    XCTAssertThrowsError(try GitPatchStore(persistentDirectory: directory))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(staged[0]).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: blockedTrash.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(originals[0]).path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(originals[1]).path))

    XCTAssertEqual(chflags(blockedTrash.path, 0), 0)
    _ = try GitPatchStore(persistentDirectory: directory)
    XCTAssertEqual(try patchDocumentCount(in: directory), 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-git-patches-\(UUID().uuidString)",
      isDirectory: true
    )
  }

  private func patchDocumentCount(in directory: URL) throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
      $0.hasPrefix("patch_")
    }.count
  }
}
