import Foundation

enum WindowsSecurePathRules {
  static func validate(_ relativePath: SecureRelativePath) throws {
    try validate(components: relativePath.components)
  }

  static func validate(components: [String]) throws {
    guard !components.isEmpty else {
      throw PathSecurityError.invalidRelativePath("empty path")
    }
    for component in components {
      try validate(component: component)
    }
  }

  private static func validate(component: String) throws {
    guard !component.isEmpty, component.utf16.count <= 255 else {
      throw PathSecurityError.invalidRelativePath("invalid Windows component length")
    }
    guard component.last != ".", component.last != " " else {
      throw PathSecurityError.invalidRelativePath("Windows component ends in dot or space")
    }
    guard !component.unicodeScalars.contains(where: isForbidden) else {
      throw PathSecurityError.invalidRelativePath("Windows-reserved path character")
    }
    guard !isReservedDeviceName(component) else {
      throw PathSecurityError.invalidRelativePath("Windows-reserved device name")
    }
  }

  private static func isForbidden(_ scalar: UnicodeScalar) -> Bool {
    scalar.value < 0x20 || #"<>:"/\|?*"#.unicodeScalars.contains(scalar)
  }

  private static func isReservedDeviceName(_ component: String) -> Bool {
    let stem = component.split(separator: ".", maxSplits: 1).first.map(String.init) ?? component
    let upper = stem.uppercased()
    if ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(upper) {
      return true
    }
    for prefix in ["COM", "LPT"] {
      if upper.count == 4,
        upper.hasPrefix(prefix),
        let suffix = upper.last,
        suffix >= "1",
        suffix <= "9"
      {
        return true
      }
    }
    return false
  }
}
