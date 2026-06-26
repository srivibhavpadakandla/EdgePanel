import Foundation
import Network

/// A minimal embedded HTTP/1.1 server bound to **127.0.0.1 only**.
///
/// Built on `Network.framework`'s `NWListener` with `requiredInterfaceType =
/// .loopback`, so it is unreachable from any non-loopback interface. The
/// per-request handler is `async`, which lets later phases hold a request open
/// (the blocking permission flow) until the user acts.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let port: NWEndpoint.Port
    private let handler: Handler
    private let queue = DispatchQueue(label: "perch.http.server")
    private var listener: NWListener?

    /// Called with human-readable lifecycle messages (ready / failed / etc.).
    public var onLog: (@Sendable (String) -> Void)?

    /// Listener health: `true` = ready/listening, `false` = failed or cancelled.
    /// Fires on the server's internal queue.
    public var onState: (@Sendable (Bool) -> Void)?

    public init(port: UInt16, handler: @escaping Handler) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 8787
        self.handler = handler
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback   // refuse non-loopback interfaces
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            tcp.version = .v4
        }

        let listener = try NWListener(using: params, on: port)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onLog?("listening on http://127.0.0.1:\(self?.port.rawValue ?? 0)")
                self?.onState?(true)
            case .failed(let error):
                self?.onLog?("listener failed: \(error.localizedDescription)")
                self?.onState?(false)
            case .cancelled:
                self?.onLog?("listener cancelled")
                self?.onState?(false)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        let loopback = Self.isLoopback(conn.endpoint)
        // Defense in depth: even if the interface check is bypassed, drop
        // anything whose remote endpoint isn't loopback.
        guard loopback else {
            conn.cancel()
            return
        }
        conn.start(queue: queue)
        // Bound the time to receive a COMPLETE request, so a half-open / stalled
        // connection can't leak forever. Cancelled the moment the request parses
        // (before the handler runs) so a legitimately-held permission response is
        // never cut off.
        let receiveTimeout = DispatchWorkItem { conn.cancel() }
        queue.asyncAfter(deadline: .now() + 15, execute: receiveTimeout)
        receive(on: conn, parser: HTTPRequestParser(), loopback: loopback, receiveTimeout: receiveTimeout)
    }

    private func receive(on conn: NWConnection, parser: HTTPRequestParser, loopback: Bool, receiveTimeout: DispatchWorkItem) {
        var parser = parser
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }

            if let data, !data.isEmpty {
                switch parser.append(data) {
                case .needMore:
                    self.receive(on: conn, parser: parser, loopback: loopback, receiveTimeout: receiveTimeout)
                case .failed:
                    receiveTimeout.cancel()
                    self.send(.init(status: 400, headers: [:], body: Data("bad request".utf8)), on: conn)
                case let .complete(method, path, headers, body):
                    receiveTimeout.cancel()   // request fully received — let the handler take as long as it needs
                    let request = HTTPRequest(
                        method: method, path: path, headers: headers,
                        body: body, remoteIsLoopback: loopback
                    )
                    Task {
                        let response = await self.handler(request)
                        self.send(response, on: conn)
                    }
                }
                return
            }

            if isComplete || error != nil {
                receiveTimeout.cancel()
                conn.cancel()
            } else {
                self.receive(on: conn, parser: parser, loopback: loopback, receiveTimeout: receiveTimeout)
            }
        }
    }

    private func send(_ response: HTTPResponse, on conn: NWConnection) {
        conn.send(content: response.serialized(), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case let .hostPort(host, _):
            switch host {
            case .ipv4(let addr): return addr.isLoopback
            case .ipv6(let addr): return addr.isLoopback
            case .name(let name, _): return name == "localhost"
            @unknown default: return false
            }
        default:
            return false
        }
    }
}
