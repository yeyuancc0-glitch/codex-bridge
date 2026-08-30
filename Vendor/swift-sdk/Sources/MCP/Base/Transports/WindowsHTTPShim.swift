#if os(Windows)
import Foundation
import FoundationNetworking

/// Windows compatibility for `HTTPClientTransport`.
///
/// `URLSession.bytes(for:)` is not available in FoundationNetworking on
/// Windows, so this shim provides a buffered substitute plus the minimal SSE
/// event model the transport consumes. SSE streams are therefore delivered as
/// one buffered payload instead of incrementally.
extension URLSession {
    public struct AsyncBytes: AsyncSequence {
        public typealias Element = UInt8

        public let data: Data
        public var task: URLSessionDataTask?

        public struct AsyncIterator: AsyncIteratorProtocol {
            let bytes: [UInt8]
            var index: Int = 0

            public mutating func next() async throws -> UInt8? {
                guard index < bytes.count else { return nil }
                let byte = bytes[index]
                index += 1
                return byte
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(bytes: [UInt8](data))
        }
    }

    public func bytes(for request: URLRequest) async throws -> (AsyncBytes, URLResponse) {
        let (data, response) = try await data(for: request)
        return (AsyncBytes(data: data), response)
    }
}

/// Minimal SSE event model matching the fields `HTTPClientTransport` reads.
public struct WindowsSSEEvent {
    public var event: String?
    public var id: String?
    public var retry: Int?
    public var data: String

    init(lines: [String]) {
        var event: String?
        var id: String?
        var retry: Int?
        var dataLines: [String] = []

        for line in lines {
            if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("event:") {
                event = String(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("id:") {
                id = String(line.dropFirst(3).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("retry:") {
                retry = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
            }
        }

        self.event = event
        self.id = id
        self.retry = retry
        self.data = dataLines.joined(separator: "\n")
    }
}

extension URLSession.AsyncBytes {
    /// Parses the buffered payload as an SSE event stream.
    public var events: AsyncStream<WindowsSSEEvent> {
        AsyncStream { continuation in
            let text = String(decoding: data, as: UTF8.self)
            var block: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                if line.isEmpty {
                    if !block.isEmpty {
                        continuation.yield(WindowsSSEEvent(lines: block))
                        block.removeAll()
                    }
                } else {
                    block.append(line)
                }
            }
            if !block.isEmpty {
                continuation.yield(WindowsSSEEvent(lines: block))
            }
            continuation.finish()
        }
    }
}
#endif
