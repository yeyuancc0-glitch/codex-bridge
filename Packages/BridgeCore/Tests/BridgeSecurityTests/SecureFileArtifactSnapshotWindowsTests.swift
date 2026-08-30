#if os(Windows)
  import Foundation
  import XCTest

  @testable import BridgeSecurity

  final class SecureFileArtifactSnapshotWindowsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "bridge-artifact-snapshot-\(UUID().uuidString)",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
    }

    override func tearDownWithError() throws {
      if let directory {
        try? FileManager.default.removeItem(at: directory)
      }
    }

    func testRejectsTextNamedAsExecutable() throws {
      let file = directory.appendingPathComponent("fake.exe")
      try Data("not a PE image".utf8).write(to: file)

      XCTAssertThrowsError(
        try SecureFileArtifactSnapshot(capturing: file.path, requiresExecutable: true)
      ) { error in
        XCTAssertEqual(error as? SecureFileArtifactError, .executableRequired)
      }
    }

    func testRejectsDOSHeaderWithoutPESignature() throws {
      let file = directory.appendingPathComponent("fake-header.exe")
      var data = Data(repeating: 0, count: 68)
      data[0] = 0x4D
      data[1] = 0x5A
      data[0x3C] = 64
      try data.write(to: file)

      XCTAssertThrowsError(
        try SecureFileArtifactSnapshot(capturing: file.path, requiresExecutable: true)
      ) { error in
        XCTAssertEqual(error as? SecureFileArtifactError, .executableRequired)
      }
    }

    func testRejectsPESignatureWithoutExecutableImageCharacteristic() throws {
      let file = directory.appendingPathComponent("fake-image.exe")
      var data = Data(repeating: 0, count: 88)
      data[0] = 0x4D
      data[1] = 0x5A
      data[0x3C] = 64
      data[64] = 0x50
      data[65] = 0x45
      data[68] = 0x64
      data[69] = 0x86
      try data.write(to: file)

      XCTAssertThrowsError(
        try SecureFileArtifactSnapshot(capturing: file.path, requiresExecutable: true)
      ) { error in
        XCTAssertEqual(error as? SecureFileArtifactError, .executableRequired)
      }
    }

    func testAllowsRegularFileWhenExecutableIsNotRequired() throws {
      let file = directory.appendingPathComponent("configuration.yml")
      try Data("mode: read-only\n".utf8).write(to: file)

      let snapshot = try SecureFileArtifactSnapshot(capturing: file.path)

      XCTAssertEqual(snapshot.fileSize, 16)
    }

    func testAcceptsCurrentTestProcessExecutable() throws {
      let executable = try XCTUnwrap(
        [
          Bundle.main.executableURL?.path,
          ProcessInfo.processInfo.arguments.first,
        ].compactMap { $0 }.first {
          FileManager.default.fileExists(atPath: $0)
        }
      )

      let snapshot = try SecureFileArtifactSnapshot(
        capturing: executable,
        requiresExecutable: true
      )

      XCTAssertGreaterThan(snapshot.fileSize, 0)
    }
  }
#endif
