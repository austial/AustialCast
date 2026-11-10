import Foundation
import Network
import AustialCastProtocol

public enum TransportError: Error, CustomStringConvertible {
    case timedOut
    case failed(String)
    public var description: String {
        switch self {
        case .timedOut: return "Timed out connecting to the TV"
        case .failed(let m): return m
        }
    }
}

/// `ByteTransport` over a Network.framework TCP connection.
public final class NWTransport: ByteTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "austialcast.transport")
    private let lock = NSLock()
    private var pending = 0
    private var failure: Error?

    public var pendingBytes: Int { lock.lock(); defer { lock.unlock() }; return pending }

    private init(connection: NWConnection) { self.connection = connection }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.connectionTimeout = 8
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        return params
    }

    public static func connect(host: String, port: UInt16 = defaultPort, timeout: TimeInterval = 8) async throws -> NWTransport {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw TransportError.failed("invalid port") }
        return try await connect(endpoint: .hostPort(host: NWEndpoint.Host(host), port: p), timeout: timeout)
    }

    public static func connect(endpoint: NWEndpoint, timeout: TimeInterval = 8) async throws -> NWTransport {
        let transport = NWTransport(connection: NWConnection(to: endpoint, using: parameters()))
        try await transport.start(timeout: timeout)
        return transport
    }

    private func start(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.fire() { cont.resume() }
                case .failed(let e):
                    self?.noteFailure(e)
                    if once.fire() { cont.resume(throwing: TransportError.failed(e.localizedDescription)) }
                case .waiting(let e):
                    // Unreachable host / no route / local network denied: surface instead of hanging.
                    if once.fire() {
                        self?.connection.cancel()
                        cont.resume(throwing: TransportError.failed(e.localizedDescription))
                    }
                case .cancelled:
                    if once.fire() { cont.resume(throwing: TransportError.failed("cancelled")) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if once.fire() {
                    self?.connection.cancel()
                    cont.resume(throwing: TransportError.timedOut)
                }
            }
        }
    }

    private func noteFailure(_ e: Error) {
        lock.lock(); if failure == nil { failure = e }; lock.unlock()
    }

    public func write(_ data: Data) throws {
        lock.lock()
        if failure != nil { lock.unlock(); throw ProtocolError.closed }
        pending += data.count
        lock.unlock()
        let n = data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            self.pending -= n
            if let error, self.failure == nil { self.failure = error }
            self.lock.unlock()
        })
    }

    public func read(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let data, data.count == count {
                    cont.resume(returning: data)
                } else if error != nil || isComplete || data == nil {
                    cont.resume(throwing: ProtocolError.closed)
                } else {
                    cont.resume(throwing: ProtocolError.closed)
                }
            }
        }
    }

    /// Graceful close: queued data (e.g. a BYE frame) is flushed and a FIN is sent before the socket is
    /// torn down. A short watchdog guarantees the connection is cancelled even if the peer stalls.
    public func close() {
        let conn = connection
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            conn.cancel()
        })
        queue.asyncAfter(deadline: .now() + 1.0) { conn.cancel() }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
