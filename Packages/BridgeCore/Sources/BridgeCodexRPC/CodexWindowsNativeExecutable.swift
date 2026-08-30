#if os(Windows)
  import BridgeSecurity
  import Foundation

  enum CodexWindowsNativeExecutable {
    static func isValid(
      at path: String,
      architecture: CodexWindowsArchitecture
    ) -> Bool {
      guard path.lowercased().hasSuffix(".exe"),
        let header = try? SecureFileArtifactReader.readPrefix(
          at: path, maximumBytes: 64 * 1_024)
      else {
        return false
      }
      return PortableExecutableHeader(header).matches(architecture)
    }

    static func isRegularFile(at path: String) -> Bool {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
        return false
      }
      return attributes[.type] as? FileAttributeType == .typeRegular
    }
  }

  private struct PortableExecutableHeader {
    private let bytes: [UInt8]

    init(_ data: Data) {
      bytes = Array(data)
    }

    func matches(_ architecture: CodexWindowsArchitecture) -> Bool {
      guard bytes.count >= 0x40, bytes[0] == 0x4D, bytes[1] == 0x5A,
        let offset = uint32(at: 0x3C), offset <= UInt32(bytes.count - 24)
      else {
        return false
      }
      let headerOffset = Int(offset)
      guard Array(bytes[headerOffset..<(headerOffset + 4)]) == [0x50, 0x45, 0, 0],
        let machine = uint16(at: headerOffset + 4),
        let characteristics = uint16(at: headerOffset + 22),
        characteristics & 0x0002 != 0
      else {
        return false
      }
      return architecture.accepts(machine: machine)
    }

    private func uint16(at offset: Int) -> UInt16? {
      guard offset >= 0, offset <= bytes.count - 2 else { return nil }
      return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func uint32(at offset: Int) -> UInt32? {
      guard offset >= 0, offset <= bytes.count - 4 else { return nil }
      return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
    }
  }
#endif
