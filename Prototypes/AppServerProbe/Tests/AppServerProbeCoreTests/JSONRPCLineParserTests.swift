import Foundation
import XCTest
@testable import AppServerProbeCore

final class JSONRPCLineParserTests: XCTestCase {
    func testReassemblesSplitProtocolLines() throws {
        var parser = JSONRPCLineParser()

        XCTAssertTrue(try parser.ingest(Data(#"{"id":1,"res"#.utf8)).isEmpty)
        let messages = try parser.ingest(Data(#"ult":{"ready":true}}"#.utf8) + Data([0x0A]))

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(
            messages[0].objectValue?["result"]?.objectValue?["ready"]?.boolValue,
            true
        )
    }

    func testRejectsStdoutContamination() throws {
        var parser = JSONRPCLineParser()

        XCTAssertThrowsError(try parser.ingest(Data("diagnostic noise\n".utf8))) { error in
            XCTAssertEqual(
                error as? AppServerProbeError,
                .protocolContamination("diagnostic noise")
            )
        }
    }
}
