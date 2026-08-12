import Foundation
import XCTest
@testable import AppServerProbeCore

final class JSONValueTests: XCTestCase {
    func testRoundTripsHeterogeneousProtocolData() throws {
        let value: JSONValue = .object([
            "null": .null,
            "bool": .bool(true),
            "integer": .integer(42),
            "number": .number(1.5),
            "string": .string("codex"),
            "array": .array([.integer(1), .string("two")]),
        ])

        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testPreservesIntegerRequestIdentifiers() throws {
        let data = Data(#"{"id":9007199254740991,"result":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(decoded.objectValue?["id"]?.integerValue, 9_007_199_254_740_991)
    }
}
