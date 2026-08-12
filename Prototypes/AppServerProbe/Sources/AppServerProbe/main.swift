import AppServerProbeCore
import Foundation

private struct HandshakeSummary: Codable {
    let userAgent: String
    let platformFamily: String
    let platformOS: String
}

private struct ModelSummary: Codable {
    let id: String
    let displayName: String
    let isDefault: Bool
    let hidden: Bool
    let supportedReasoningEfforts: [String]
}

private struct ModelListSummary: Codable {
    let count: Int
    let nextCursorPresent: Bool
    let models: [ModelSummary]
}

@main
private enum AppServerProbeCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let command = arguments.first ?? "handshake"
            guard ["handshake", "models"].contains(command) else {
                printUsage()
                Foundation.exit(EXIT_FAILURE)
            }

            let client = CodexAppServerClient()
            try await client.start()

            let initializeResult = try await client.initialize()
            if command == "handshake" {
                try printHandshake(initializeResult)
            } else {
                try await printModels(client)
            }

            await client.stop()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("app-server-probe: \(message)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func printHandshake(_ result: JSONValue) throws {
        guard let object = result.objectValue,
              let userAgent = object["userAgent"]?.stringValue,
              let platformFamily = object["platformFamily"]?.stringValue,
              let platformOS = object["platformOs"]?.stringValue
        else {
            throw AppServerProbeError.malformedMessage("initialize result is missing required fields")
        }

        try printJSON(HandshakeSummary(
            userAgent: userAgent,
            platformFamily: platformFamily,
            platformOS: platformOS
        ))
    }

    private static func printModels(_ client: CodexAppServerClient) async throws {
        let result = try await client.listModels(limit: 100)
        guard let object = result.objectValue,
              let modelValues = object["data"]?.arrayValue
        else {
            throw AppServerProbeError.malformedMessage("model/list result has no data array")
        }

        let models = modelValues.compactMap(makeModelSummary)
        try printJSON(ModelListSummary(
            count: models.count,
            nextCursorPresent: object["nextCursor"]?.stringValue != nil,
            models: models
        ))
    }

    private static func makeModelSummary(_ value: JSONValue) -> ModelSummary? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let displayName = object["displayName"]?.stringValue,
              let isDefault = object["isDefault"]?.boolValue,
              let hidden = object["hidden"]?.boolValue
        else { return nil }

        let efforts = object["supportedReasoningEfforts"]?.arrayValue?.compactMap { option in
            option.objectValue?["reasoningEffort"]?.stringValue
        } ?? []
        return ModelSummary(
            id: id,
            displayName: displayName,
            isDefault: isDefault,
            hidden: hidden,
            supportedReasoningEfforts: efforts
        )
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func printUsage() {
        print("""
        Usage: app-server-probe [handshake|models]

          handshake  Initialize Codex app-server and print non-sensitive platform metadata.
          models     Initialize and print the dynamic model/effort catalog.

        This probe never reads account details, threads, files, or authentication storage.
        """)
    }
}

