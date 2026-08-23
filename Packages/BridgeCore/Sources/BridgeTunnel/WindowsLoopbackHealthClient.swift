#if canImport(WinSDK)
  import BridgePlatformWindows
  import Foundation
  import WinSDK

  struct TunnelHealthSnapshot: Equatable, Sendable {
    let isReady: Bool
    let pollTimestamp: TimeInterval?
  }

  struct LoopbackHealthClient: Sendable {
    static let urlFileName = "health.url"

    func snapshot(
      urlFileDirectory: WindowsSecureRunDirectory,
      expectedPeerPID: UInt32
    ) throws -> TunnelHealthSnapshot {
      let port = try Self.healthPort(in: urlFileDirectory)
      guard expectedPeerPID > 0,
        try WindowsTCPListenerTable.ownsListeningPort(
          port: port,
          processID: expectedPeerPID
        )
      else {
        throw TunnelHealthError.unexpectedPeer
      }

      let ready = try WindowsLoopbackHTTPClient.request(path: "/readyz", port: port)
      let readyBodyText = String(decoding: ready.body, as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      let isReady =
        ready.status == 200
        && (readyBodyText == "ready" || readyBodyText == "ok" || readyBodyText.isEmpty)
      let metrics = try? WindowsLoopbackHTTPClient.request(path: "/metrics", port: port)
      let pollTime =
        metrics != nil && metrics!.status == 200
        ? Self.pollTimestamp(in: metrics!.body)
        : nil
      return TunnelHealthSnapshot(isReady: isReady, pollTimestamp: pollTime)
    }

    package static func healthPort(in directory: WindowsSecureRunDirectory) throws -> Int {
      let data = try directory.readRegularFile(
        name: Self.urlFileName,
        maximumBytes: WindowsHealthConstants.maximumURLBytes
      )
      return try parseHealthURL(data)
    }

    package static func parseHealthURL(_ data: Data) throws -> Int {
      guard data.count <= WindowsHealthConstants.maximumURLBytes,
        let rawValue = String(data: data, encoding: .utf8)
      else {
        throw TunnelHealthError.invalidURLFile
      }
      let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty,
        value.utf8.count <= WindowsHealthConstants.maximumURLBytes,
        value.rangeOfCharacter(from: .controlCharacters) == nil,
        let components = URLComponents(string: value),
        components.scheme == "http",
        components.host == "127.0.0.1",
        components.user == nil,
        components.password == nil,
        components.query == nil,
        components.fragment == nil,
        components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
        let port = components.port,
        (1...65_535).contains(port)
      else {
        throw TunnelHealthError.invalidURLFile
      }
      return port
    }

    package static func pollTimestamp(in body: Data) -> TimeInterval? {
      let text = String(decoding: body, as: UTF8.self)
      for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2 || fields.count == 3 else { continue }
        let metric = fields[0].split(separator: "{").first
        guard metric == "commands_poll_last_successful_timestamp_seconds" else { continue }
        guard let value = Double(fields[1]), value.isFinite else { continue }
        if fields.count == 3 {
          guard let sampleTimestamp = Double(fields[2]), sampleTimestamp.isFinite else {
            continue
          }
        }
        return value
      }
      return nil
    }
  }

  package struct HTTPResponse {
    let status: Int
    let body: Data

    init(data: Data) throws {
      guard data.count <= WindowsHealthConstants.maximumResponseBytes else {
        throw TunnelHealthError.responseTooLarge
      }
      let delimiter = Data([13, 10, 13, 10])
      guard let split = data.range(of: delimiter) else {
        throw TunnelHealthError.invalidResponse
      }
      let headData = data[..<split.lowerBound]
      guard headData.allSatisfy({ $0 < 0x80 }),
        let head = String(data: headData, encoding: .ascii)
      else {
        throw TunnelHealthError.invalidResponse
      }
      let lines = head.components(separatedBy: "\r\n")
      guard let firstLine = lines.first else {
        throw TunnelHealthError.invalidResponse
      }
      let parts = firstLine.split(separator: " ", omittingEmptySubsequences: false)
      guard parts.count >= 2,
        parts[0] == "HTTP/1.1" || parts[0] == "HTTP/1.0",
        parts[1].utf8.count == 3,
        parts[1].utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
        let status = Int(parts[1]),
        (100...599).contains(status)
      else {
        throw TunnelHealthError.invalidResponse
      }

      var contentLength: Int?
      var usesChunkedEncoding = false
      for line in lines.dropFirst() {
        guard !line.isEmpty, let separator = line.firstIndex(of: ":") else {
          throw TunnelHealthError.invalidResponse
        }
        let rawName = line[..<separator]
        guard rawName == rawName.trimmingCharacters(in: .whitespaces) else {
          throw TunnelHealthError.invalidResponse
        }
        let name = rawName.lowercased()
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard Self.isHeaderName(name), Self.isHeaderValue(value) else {
          throw TunnelHealthError.invalidResponse
        }
        switch name {
        case "content-length":
          guard contentLength == nil, let length = Self.decimalLength(value) else {
            throw TunnelHealthError.invalidResponse
          }
          contentLength = length
        case "transfer-encoding":
          guard !usesChunkedEncoding, value.lowercased() == "chunked" else {
            throw TunnelHealthError.invalidResponse
          }
          usesChunkedEncoding = true
        default:
          continue
        }
      }
      guard !(contentLength != nil && usesChunkedEncoding) else {
        throw TunnelHealthError.invalidResponse
      }

      let rawBody = Data(data[split.upperBound...])
      self.status = status
      if usesChunkedEncoding {
        self.body = try Self.decodeChunked(rawBody)
      } else if let length = contentLength {
        guard rawBody.count == length else {
          throw TunnelHealthError.invalidResponse
        }
        self.body = rawBody
      } else {
        throw TunnelHealthError.invalidResponse
      }
    }

    private static func isHeaderName(_ name: String) -> Bool {
      guard !name.isEmpty else { return false }
      return name.utf8.allSatisfy { byte in
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
          || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
          || byte == UInt8(ascii: "-")
      }
    }

    private static func isHeaderValue(_ value: String) -> Bool {
      value.unicodeScalars.allSatisfy { scalar in
        scalar.value == 9 || (0x20...0x7E).contains(scalar.value)
      }
    }

    private static func decimalLength(_ value: String) -> Int? {
      let digits = value.trimmingCharacters(in: .whitespaces)
      guard !digits.isEmpty,
        digits.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
      else {
        return nil
      }
      var result = 0
      for digit in digits.utf8 {
        let value = Int(digit - UInt8(ascii: "0"))
        guard result <= (Int.max - value) / 10 else { return nil }
        result = result * 10 + value
      }
      guard result <= WindowsHealthConstants.maximumResponseBytes else { return nil }
      return result
    }

    private static func decodeChunked(_ data: Data) throws -> Data {
      let delimiter = Data([13, 10])
      var result = Data()
      var index = data.startIndex
      while true {
        guard let lineEnd = data[index...].range(of: delimiter) else {
          throw TunnelHealthError.invalidResponse
        }
        let sizeLine = data[index..<lineEnd.lowerBound]
        guard !sizeLine.isEmpty,
          !sizeLine.contains(59),
          let chunkSize = Self.hexLength(sizeLine)
        else {
          throw TunnelHealthError.invalidResponse
        }
        index = lineEnd.upperBound
        if chunkSize == 0 {
          return try Self.decodeChunkTrailers(data, from: index, body: result)
        }
        guard chunkSize <= WindowsHealthConstants.maximumResponseBytes - result.count,
          let chunkEnd = data.index(index, offsetBy: chunkSize, limitedBy: data.endIndex),
          let contentEnd = data.index(
            chunkEnd, offsetBy: delimiter.count, limitedBy: data.endIndex),
          Data(data[chunkEnd..<contentEnd]) == delimiter
        else {
          throw TunnelHealthError.invalidResponse
        }
        result.append(data[index..<chunkEnd])
        index = contentEnd
      }
    }

    private static func decodeChunkTrailers(
      _ data: Data,
      from start: Data.Index,
      body: Data
    ) throws -> Data {
      let delimiter = Data([13, 10])
      var index = start
      while true {
        guard let lineEnd = data[index...].range(of: delimiter) else {
          throw TunnelHealthError.invalidResponse
        }
        let line = data[index..<lineEnd.lowerBound]
        index = lineEnd.upperBound
        if line.isEmpty {
          guard index == data.endIndex else { throw TunnelHealthError.invalidResponse }
          return body
        }
        guard line.allSatisfy({ $0 < 0x80 }),
          let separator = line.firstIndex(of: 58),
          separator != line.startIndex,
          Self.isHeaderName(String(decoding: line[..<separator], as: UTF8.self)),
          line[line.index(after: separator)...].allSatisfy({
            $0 == 9 || (0x20...0x7E).contains($0)
          })
        else {
          throw TunnelHealthError.invalidResponse
        }
      }
    }

    private static func hexLength(_ value: Data.SubSequence) -> Int? {
      var result = 0
      for byte in value {
        let digit: Int
        switch byte {
        case 48...57:
          digit = Int(byte - 48)
        case 65...70:
          digit = Int(byte - 55)
        case 97...102:
          digit = Int(byte - 87)
        default:
          return nil
        }
        guard result <= (WindowsHealthConstants.maximumResponseBytes - digit) / 16 else {
          return nil
        }
        result = result * 16 + digit
      }
      return result
    }
  }

  package enum WindowsTCPTableParseError: Error, Equatable, Sendable {
    case malformed
  }

  package struct WindowsTCPListenerRecord: Equatable, Sendable {
    package let port: Int
    package let processID: UInt32
    package let state: UInt32
  }

  package enum WindowsTCPListenerTable {
    package static func ownsListeningPort(
      in data: Data,
      port: Int,
      processID: UInt32
    ) throws -> Bool {
      let records = try parse(data)
      return records.contains {
        $0.state == WindowsHealthConstants.listenState
          && $0.port == port && $0.processID == processID
      }
    }

    package static func ownsListeningPort(
      port: Int,
      processID: UInt32
    ) throws -> Bool {
      let table = try WindowsTCPTableProvider.listenerTable()
      do {
        return try ownsListeningPort(in: table, port: port, processID: processID)
      } catch {
        throw TunnelHealthError.unavailable
      }
    }

    package static func parse(_ data: Data) throws -> [WindowsTCPListenerRecord] {
      let headerBytes = MemoryLayout<DWORD>.stride
      let rowBytes = MemoryLayout<DWORD>.stride * 6
      let alignment = MemoryLayout<DWORD>.alignment
      guard data.count >= headerBytes,
        let count = littleEndianUInt32(in: data, at: 0),
        count <= WindowsHealthConstants.maximumTCPRows
      else {
        throw WindowsTCPTableParseError.malformed
      }
      let firstRow = (headerBytes + alignment - 1) / alignment * alignment
      guard firstRow <= data.count else {
        throw WindowsTCPTableParseError.malformed
      }
      let rowCount = Int(count)
      guard rowCount <= (data.count - firstRow) / rowBytes else {
        throw WindowsTCPTableParseError.malformed
      }

      var records: [WindowsTCPListenerRecord] = []
      records.reserveCapacity(rowCount)
      for index in 0..<rowCount {
        let offset = firstRow + index * rowBytes
        guard let state = littleEndianUInt32(in: data, at: offset),
          let localPortValue = littleEndianUInt32(
            in: data, at: offset + MemoryLayout<DWORD>.stride * 2),
          let processID = littleEndianUInt32(in: data, at: offset + MemoryLayout<DWORD>.stride * 5),
          localPortValue & 0xFFFF_0000 == 0
        else {
          throw WindowsTCPTableParseError.malformed
        }
        let networkPort = UInt16(truncatingIfNeeded: localPortValue)
        let port = Int(UInt16(bigEndian: networkPort))
        records.append(
          WindowsTCPListenerRecord(port: port, processID: processID, state: state)
        )
      }
      return records
    }

    private static func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32? {
      guard offset >= 0, offset <= data.count - MemoryLayout<DWORD>.size else { return nil }
      return UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
    }
  }

  private enum WindowsHealthConstants {
    static let maximumURLBytes = 2_048
    static let maximumResponseBytes = 1 * 1_024 * 1_024
    static let maximumTCPTableBytes = 4 * 1_024 * 1_024
    static let maximumTCPRows: UInt32 = 16_384
    static let listenState: UInt32 = 2
    static let ipv4Family: ULONG = 2
    static let ownerPIDListenerTable = TCP_TABLE_CLASS(rawValue: Int32(3))
    static let insufficientBuffer: DWORD = 122
    static let noError: DWORD = 0
    static let winsockVersion: WORD = 0x0202
    static let socketAddressBytes = 16
    static let socketTimeoutMilliseconds: DWORD = 2_000
    static let solSocket: Int32 = 0xFFFF
    static let receiveTimeout: Int32 = 0x1006
    static let sendTimeout: Int32 = 0x1005
  }

  private enum WindowsTCPTableProvider {
    static func listenerTable() throws -> Data {
      var size = DWORD(0)
      var status = GetExtendedTcpTable(
        nil,
        &size,
        false,
        WindowsHealthConstants.ipv4Family,
        WindowsHealthConstants.ownerPIDListenerTable,
        0
      )
      if status == WindowsHealthConstants.noError, size == 0 { return Data() }
      guard status == WindowsHealthConstants.insufficientBuffer,
        size > 0,
        size <= WindowsHealthConstants.maximumTCPTableBytes
      else {
        throw TunnelHealthError.unavailable
      }

      for _ in 0..<3 {
        var buffer = [UInt8](repeating: 0, count: Int(size))
        var providedSize = size
        status = buffer.withUnsafeMutableBytes { bytes in
          GetExtendedTcpTable(
            bytes.baseAddress,
            &providedSize,
            false,
            WindowsHealthConstants.ipv4Family,
            WindowsHealthConstants.ownerPIDListenerTable,
            0
          )
        }
        if status == WindowsHealthConstants.insufficientBuffer,
          providedSize > size,
          providedSize <= WindowsHealthConstants.maximumTCPTableBytes
        {
          size = providedSize
          continue
        }
        guard status == WindowsHealthConstants.noError else {
          throw TunnelHealthError.unavailable
        }
        return Data(buffer)
      }
      throw TunnelHealthError.unavailable
    }
  }

  private enum WindowsLoopbackHTTPClient {
    static func request(path: String, port: Int) throws -> HTTPResponse {
      let session = try WindowsWinsockSession()
      let descriptor = try openSocket()
      defer { closesocket(descriptor) }
      try setTimeouts(descriptor)
      try connect(descriptor, port: port)
      let request = Data(
        "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n".utf8
      )
      try send(request, on: descriptor)
      return try withExtendedLifetime(session) {
        try readResponse(on: descriptor)
      }
    }

    private static func openSocket() throws -> SOCKET {
      let descriptor = WinSDK.socket(
        Int32(WindowsHealthConstants.ipv4Family),
        Int32(1),  // SOCK_STREAM
        Int32(6)  // IPPROTO_TCP
      )
      guard descriptor != SOCKET.max else { throw TunnelHealthError.unavailable }
      return descriptor
    }

    private static func setTimeouts(_ descriptor: SOCKET) throws {
      var timeout = WindowsHealthConstants.socketTimeoutMilliseconds
      let receiveStatus = withUnsafePointer(to: &timeout) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<DWORD>.size) {
          setsockopt(
            descriptor,
            WindowsHealthConstants.solSocket,
            WindowsHealthConstants.receiveTimeout,
            $0,
            Int32(MemoryLayout<DWORD>.size)
          )
        }
      }
      let sendStatus = withUnsafePointer(to: &timeout) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<DWORD>.size) {
          setsockopt(
            descriptor,
            WindowsHealthConstants.solSocket,
            WindowsHealthConstants.sendTimeout,
            $0,
            Int32(MemoryLayout<DWORD>.size)
          )
        }
      }
      guard receiveStatus == 0, sendStatus == 0 else {
        throw TunnelHealthError.unavailable
      }
    }

    private static func connect(_ descriptor: SOCKET, port: Int) throws {
      guard (1...65_535).contains(port) else { throw TunnelHealthError.invalidURLFile }
      let address = UnsafeMutableRawPointer.allocate(
        byteCount: WindowsHealthConstants.socketAddressBytes,
        alignment: MemoryLayout<SOCKADDR>.alignment
      )
      defer { address.deallocate() }
      address.initializeMemory(
        as: UInt8.self,
        repeating: 0,
        count: WindowsHealthConstants.socketAddressBytes
      )
      address.storeBytes(
        of: UInt16(WindowsHealthConstants.ipv4Family), toByteOffset: 0, as: UInt16.self)
      address.storeBytes(of: UInt16(port).bigEndian, toByteOffset: 2, as: UInt16.self)
      let loopback = [UInt8(127), 0, 0, 1]
      loopback.withUnsafeBytes { bytes in
        address.advanced(by: 4).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
      }
      let status = WinSDK.connect(
        descriptor,
        address.assumingMemoryBound(to: SOCKADDR.self),
        Int32(WindowsHealthConstants.socketAddressBytes)
      )
      guard status == 0 else { throw TunnelHealthError.unavailable }
    }

    private static func send(_ data: Data, on descriptor: SOCKET) throws {
      try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
          throw TunnelHealthError.unavailable
        }
        var offset = 0
        while offset < bytes.count {
          let count = WinSDK.send(
            descriptor,
            baseAddress.advanced(by: offset).assumingMemoryBound(to: CChar.self),
            Int32(bytes.count - offset),
            0
          )
          guard count > 0 else { throw TunnelHealthError.unavailable }
          offset += Int(count)
        }
      }
    }

    private static func readResponse(on descriptor: SOCKET) throws -> HTTPResponse {
      var response = Data()
      var chunk = [UInt8](repeating: 0, count: 16 * 1_024)
      while response.count <= WindowsHealthConstants.maximumResponseBytes {
        let count = chunk.withUnsafeMutableBytes { bytes in
          WinSDK.recv(
            descriptor,
            bytes.baseAddress!.assumingMemoryBound(to: CChar.self),
            Int32(bytes.count),
            0
          )
        }
        if count == 0 { break }
        guard count > 0 else { throw TunnelHealthError.unavailable }
        let received = Int(count)
        guard response.count <= WindowsHealthConstants.maximumResponseBytes - received else {
          throw TunnelHealthError.responseTooLarge
        }
        response.append(contentsOf: chunk.prefix(received))
      }
      guard !response.isEmpty else { throw TunnelHealthError.invalidResponse }
      return try HTTPResponse(data: response)
    }
  }

  private final class WindowsWinsockSession: @unchecked Sendable {
    init() throws {
      var data = WSADATA()
      guard WSAStartup(WindowsHealthConstants.winsockVersion, &data) == 0 else {
        throw TunnelHealthError.unavailable
      }
    }

    deinit {
      _ = WSACleanup()
    }
  }

  enum TunnelHealthError: Error, Equatable, Sendable {
    case unavailable
    case invalidURLFile
    case invalidResponse
    case responseTooLarge
    case unexpectedPeer
  }
#endif
