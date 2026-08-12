@preconcurrency import Foundation

public actor CodexAppServerClient {
    private final class ProcessState: @unchecked Sendable {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
    }

    private let state = ProcessState()
    private let broker = JSONRPCBroker()
    private lazy var lineDecoder = JSONLineDecoder(broker: broker)
    private var nextRequestID: Int64 = 1
    private var started = false
    private let timeoutNanoseconds: UInt64

    public init(timeoutSeconds: UInt64 = 10) {
        timeoutNanoseconds = timeoutSeconds * 1_000_000_000
    }

    public func start(codexExecutable: String? = nil) throws {
        guard !started else { throw AppServerProbeError.alreadyStarted }

        if let codexExecutable {
            state.process.executableURL = URL(fileURLWithPath: codexExecutable)
            state.process.arguments = ["app-server", "--stdio"]
        } else {
            state.process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            state.process.arguments = ["codex", "app-server", "--stdio"]
        }

        state.process.standardInput = state.stdinPipe
        state.process.standardOutput = state.stdoutPipe
        state.process.standardError = state.stderrPipe

        let decoder = lineDecoder
        let broker = broker
        state.stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            Task {
                if data.isEmpty {
                    await decoder.finish()
                } else {
                    await decoder.consume(data)
                }
            }
        }
        state.stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        state.process.terminationHandler = { process in
            Task { await broker.terminate(with: .processExited(process.terminationStatus)) }
        }

        try state.process.run()
        started = true
    }

    public func initialize(experimentalAPI: Bool = false) async throws -> JSONValue {
        let params: JSONValue = .object([
            "clientInfo": .object([
                "name": .string("codex_bridge_probe"),
                "title": .string("Codex Bridge Probe"),
                "version": .string("0.1.0"),
            ]),
            "capabilities": .object([
                "experimentalApi": .bool(experimentalAPI),
                "requestAttestation": .bool(false),
            ]),
        ])
        let result = try await request(method: "initialize", params: params)
        try notify(method: "initialized")
        return result
    }

    public func listModels(
        cursor: String? = nil,
        limit: Int? = nil,
        includeHidden: Bool = false
    ) async throws -> JSONValue {
        var fields: [String: JSONValue] = ["includeHidden": .bool(includeHidden)]
        if let cursor { fields["cursor"] = .string(cursor) }
        if let limit { fields["limit"] = .integer(Int64(limit)) }
        return try await request(method: "model/list", params: .object(fields))
    }

    public func stop() {
        guard started else { return }
        state.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        state.stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? state.stdinPipe.fileHandleForWriting.close()
        if state.process.isRunning {
            state.process.terminate()
        }
        started = false
    }

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard started else { throw AppServerProbeError.notStarted }
        let id = nextRequestID
        nextRequestID += 1

        try write(.object([
            "id": .integer(id),
            "method": .string(method),
            "params": params,
        ]))

        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await self.broker.wait(for: id) }
            group.addTask {
                try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                throw AppServerProbeError.timeout(method: method)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw AppServerProbeError.timeout(method: method)
            }
            return result
        }
    }

    private func notify(method: String) throws {
        guard started else { throw AppServerProbeError.notStarted }
        try write(.object(["method": .string(method)]))
    }

    private func write(_ value: JSONValue) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try state.stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }
}
