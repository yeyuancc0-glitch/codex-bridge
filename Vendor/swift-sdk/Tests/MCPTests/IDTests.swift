import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import struct Foundation.UUID

@testable import MCP

@Suite("ID Tests")
struct IDTests {
    @Test("String ID initialization and encoding")
    func testStringID() throws {
        let id: ID = "test-id"
        #expect(id.description == "test-id")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(id)
        let decoded = try decoder.decode(ID.self, from: data)
        #expect(decoded == id)
    }

    @Test("Number ID initialization and encoding")
    func testNumberID() throws {
        let id: ID = 42
        #expect(id.description == "42")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(id)
        let decoded = try decoder.decode(ID.self, from: data)
        #expect(decoded == id)
    }

    @Test("Random ID generation")
    func testRandomID() throws {
        let id1 = ID.random
        let id2 = ID.random
        #expect(id1 != id2, "Random IDs should be unique")

        if case .string(let str) = id1 {
            #expect(!str.isEmpty)
            // Verify it's a valid UUID string
            #expect(UUID(uuidString: str) != nil)
        } else {
            #expect(Bool(false), "Random ID should be string type")
        }
    }
}
