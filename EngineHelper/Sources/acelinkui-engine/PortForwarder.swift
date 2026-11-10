import Foundation
import Network

/// Forwards TCP connections from 127.0.0.1:port to the same port of the VM, so the
/// engine answers at the same address as it did under Docker (`--publish`).
final class PortForwarder: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "acelinkui-engine.forwarder")

    init(port: UInt16, to host: String) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!
        )
        listener = try NWListener(using: parameters)
        let target = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!
        )
        listener.newConnectionHandler = { [queue] client in
            let upstream = NWConnection(to: target, using: .tcp)
            Self.pipe(client, upstream)
            Self.pipe(upstream, client)
            client.start(queue: queue)
            upstream.start(queue: queue)
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                FileHandle.standardError.write(Data("Cannot listen on port \(port): \(error)\n".utf8))
                exit(1)
            }
        }
        listener.start(queue: queue)
    }

    /// Copies everything `from` receives to `to`, and closes both when either side ends.
    private static func pipe(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        from.cancel()
                        to.cancel()
                    }
                })
            }
            if isComplete || error != nil {
                // Let the other side finish reading what was already sent.
                to.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    to.cancel()
                    from.cancel()
                })
                return
            }
            pipe(from, to)
        }
    }
}
