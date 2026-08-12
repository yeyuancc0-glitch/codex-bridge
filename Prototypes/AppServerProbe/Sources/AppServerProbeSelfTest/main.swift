import AppServerProbeCore
import Foundation

@main
private enum AppServerProbeSelfTest {
    static func main() {
        do {
            try testJSONRoundTrip()
            try testIntegerIdentifier()
            try testSplitProtocolLine()
            try testProtocolContamination()
            print("app-server-probe-self-test: 4 checks passed")
        } catch {
            FileHandle.standardError.write(Data("self-test failed: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func testJSONRoundTrip() throws {
        let value: JSONValue = .object([
            "null": .null,
            "bool": .bool(true),
            "integer": .integer(42),
            "number": .number(1.5),
            "string": .string("codex"),
            "array": .array([.integer(1), .string("two")]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        try require(decoded == value, "JSON round-trip")
    }

    private static func testIntegerIdentifier() throws {
        let data = Data(#"{"id":9007199254740991,"result":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        try require(
            decoded.objectValue?["id"]?.integerValue == 9_007_199_254_740_991,
            "integer request ID preservation"
        )
    }

    private static func testSplitProtocolLine() throws {
        var parser = JSONRPCLineParser()
        let partial = try parser.ingest(Data(#"{"id":1,"res"#.utf8))
        try require(partial.isEmpty, "partial line buffering")
        let messages = try parser.ingest(Data(#"ult":{"ready":true}}"#.utf8) + Data([0x0A]))
        try require(messages.count == 1, "split line reassembly")
        try require(
            messages[0].objectValue?["result"]?.objectValue?["ready"]?.boolValue == true,
            "decoded result"
        )
    }

    private static func testProtocolContamination() throws {
        var parser = JSONRPCLineParser()
        do {
            _ = try parser.ingest(Data("diagnostic noise\n".utf8))
            throw SelfTestError.failed("stdout contamination was accepted")
        } catch let error as AppServerProbeError {
            try require(error == .protocolContamination("diagnostic noise"), "stdout contamination error")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw SelfTestError.failed(name) }
    }
}

private enum SelfTestError: Error {
    case failed(String)
}
