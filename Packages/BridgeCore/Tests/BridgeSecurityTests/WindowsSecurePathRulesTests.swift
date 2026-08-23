import XCTest

@testable import BridgeSecurity

final class WindowsSecurePathRulesTests: XCTestCase {
  func testAcceptsOrdinaryPortableComponents() throws {
    try WindowsSecurePathRules.validate(components: [
      "Sources",
      "file name & symbols.swift",
    ])
  }

  func testRejectsSeparatorsADSAndReservedCharacters() {
    for component in [
      #"nested\escape"#,
      "stream:secret",
      "bad?.txt",
      "bad|name",
      "control\u{001F}",
    ] {
      XCTAssertThrowsError(
        try WindowsSecurePathRules.validate(components: [component]),
        component
      ) { error in
        guard case .invalidRelativePath = error as? PathSecurityError else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
    }
  }

  func testRejectsTrailingDotsSpacesAndDeviceNames() {
    for component in [
      "name.",
      "name ",
      "CON",
      "nul.txt",
      "COM1.log",
      "lpt9",
      "CONOUT$",
    ] {
      XCTAssertThrowsError(
        try WindowsSecurePathRules.validate(components: [component]),
        component
      ) { error in
        guard case .invalidRelativePath = error as? PathSecurityError else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
    }
  }

  func testAllowsNamesThatOnlyBeginWithReservedPrefixes() throws {
    try WindowsSecurePathRules.validate(components: [
      "console.txt",
      "COM10.txt",
      "NUL-safe.txt",
    ])
  }
}
