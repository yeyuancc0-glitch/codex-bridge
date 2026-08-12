import Foundation

actor JSONLineDecoder {
    private var parser = JSONRPCLineParser()
    private let broker: JSONRPCBroker

    init(broker: JSONRPCBroker) {
        self.broker = broker
    }

    func consume(_ data: Data) async {
        do {
            for message in try parser.ingest(data) {
                await broker.receive(message)
            }
        } catch let error as AppServerProbeError {
            await broker.terminate(with: error)
        } catch {
            await broker.terminate(with: .malformedMessage(error.localizedDescription))
        }
    }

    func finish() async {
        do {
            for message in try parser.finish() {
                await broker.receive(message)
            }
        } catch let error as AppServerProbeError {
            await broker.terminate(with: error)
        } catch {
            await broker.terminate(with: .malformedMessage(error.localizedDescription))
        }
    }
}
