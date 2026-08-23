import Foundation

package enum WindowsTunnelPathRules {
  package static func normalize(_ value: String) -> String {
    var result = value.replacingOccurrences(of: "/", with: "\\")
    while result.count > 3, result.hasSuffix("\\") { result.removeLast() }
    return result
  }

  package static func isLocalAbsolutePath(_ path: String) -> Bool {
    let units = Array(path.utf16)
    guard units.count >= 3, units[1] == 58, units[2] == 92 else { return false }
    return (65...90).contains(Int(units[0])) || (97...122).contains(Int(units[0]))
  }

  package static func isSafeComponent(_ component: String) -> Bool {
    guard !component.isEmpty, component != ".", component != ".." else { return false }
    guard !component.hasSuffix("."), !component.hasSuffix(" ") else { return false }
    return !component.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0...0x1F, 0x22, 0x2A, 0x2F, 0x3A, 0x3C, 0x3E, 0x3F, 0x5C, 0x7C:
        return true
      default:
        return false
      }
    }
  }

  package static func isSafeEntryName(_ name: String) -> Bool {
    guard isSafeComponent(name), name.utf16.count <= 255 else { return false }
    let stem = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
    let upper = stem.uppercased()
    guard !["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", "CLOCK$"].contains(upper) else {
      return false
    }
    for prefix in ["COM", "LPT"] where upper.count == 4 && upper.hasPrefix(prefix) {
      if let suffix = upper.last, ("1"..."9").contains(suffix) { return false }
    }
    return true
  }

  package static func isValidSHA256(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 64 else { return false }
    return bytes.allSatisfy {
      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
    }
  }
}
