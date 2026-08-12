import Foundation

public struct JSONRPCLineParser: Sendable {
    private static let maximumLineBytes = 8 * 1024 * 1024

    private var buffer: [UInt8] = []

    public init() {}

    public mutating func ingest(_ data: Data) throws -> [JSONValue] {
        buffer.append(contentsOf: data)
        guard buffer.count <= Self.maximumLineBytes else {
            buffer.removeAll()
            throw AppServerProbeError.malformedMessage("protocol line exceeds 8 MiB")
        }

        var messages: [JSONValue] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeFirst(newline + 1)
            if let message = try decode(line) {
                messages.append(message)
            }
        }
        return messages
    }

    public mutating func finish() throws -> [JSONValue] {
        let remainder = Data(buffer)
        buffer.removeAll()
        guard let message = try decode(remainder) else { return [] }
        return [message]
    }

    private func decode(_ line: Data) throws -> JSONValue? {
        let trimmed = line.trimmingASCIIWhitespace()
        guard !trimmed.isEmpty else { return nil }

        do {
            return try JSONDecoder().decode(JSONValue.self, from: trimmed)
        } catch {
            let preview = String(data: trimmed.prefix(160), encoding: .utf8) ?? "<non-UTF-8>"
            if preview.first != "{" {
                throw AppServerProbeError.protocolContamination(preview)
            }
            throw AppServerProbeError.malformedMessage(error.localizedDescription)
        }
    }
}

private extension Data {
    func trimmingASCIIWhitespace() -> Data {
        let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
        let bytes = Array(self)
        guard let first = bytes.firstIndex(where: { !whitespace.contains($0) }) else {
            return Data()
        }
        let last = bytes.lastIndex(where: { !whitespace.contains($0) }) ?? first
        return Data(bytes[first...last])
    }
}
