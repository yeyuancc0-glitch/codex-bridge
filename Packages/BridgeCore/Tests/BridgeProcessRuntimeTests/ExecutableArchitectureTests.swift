import BridgePlatform
import BridgeProcessRuntime
import Foundation
import XCTest

final class ExecutableArchitectureTests: XCTestCase {
  func testParsesSupportedPEMachines() throws {
    XCTAssertEqual(
      try PortableExecutableInspector.architecture(in: fixture(machine: 0x8664)),
      .amd64
    )
    XCTAssertEqual(
      try PortableExecutableInspector.architecture(in: fixture(machine: 0xAA64)),
      .arm64
    )
    XCTAssertEqual(
      try PortableExecutableInspector.architecture(in: fixture(machine: 0x014C)),
      .i386
    )
  }

  func testRejectsMalformedAndUnknownHeaders() {
    XCTAssertThrowsError(try PortableExecutableInspector.architecture(in: Data())) { error in
      XCTAssertEqual(error as? PortableExecutableError, .invalidHeader)
    }
    XCTAssertThrowsError(
      try PortableExecutableInspector.architecture(in: fixture(machine: 0xFFFF))
    ) { error in
      XCTAssertEqual(
        error as? PortableExecutableError,
        .unsupportedArchitecture(0xFFFF)
      )
    }
  }

  func testFileInspectorAcceptsVeryLargeHeaderLimitWithoutTrapping() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-bridge-pe-\(UUID().uuidString).exe"
    )
    try fixture(machine: 0x8664).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertEqual(
      try PortableExecutableInspector.architecture(at: url, maximumHeaderOffset: Int.max),
      .amd64
    )
  }

  func testArchitecturePolicyAllowsArm64NativeAndX64EmulationOnly() {
    XCTAssertTrue(
      WindowsExecutableArchitecturePolicy.supports(executable: .arm64, process: .arm64)
    )
    XCTAssertTrue(
      WindowsExecutableArchitecturePolicy.supports(executable: .amd64, process: .arm64)
    )
    XCTAssertFalse(
      WindowsExecutableArchitecturePolicy.supports(executable: .i386, process: .arm64)
    )
    XCTAssertTrue(
      WindowsExecutableArchitecturePolicy.supports(executable: .amd64, process: .amd64)
    )
    XCTAssertFalse(
      WindowsExecutableArchitecturePolicy.supports(executable: .arm64, process: .amd64)
    )
  }

  private func fixture(machine: UInt16) -> Data {
    var data = Data(repeating: 0, count: 0x90)
    data[0] = 0x4D
    data[1] = 0x5A
    data[0x3C] = 0x80
    data[0x80] = 0x50
    data[0x81] = 0x45
    data[0x84] = UInt8(machine & 0xFF)
    data[0x85] = UInt8(machine >> 8)
    return data
  }
}
