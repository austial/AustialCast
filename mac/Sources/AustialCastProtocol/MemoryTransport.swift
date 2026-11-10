import Foundation

/// An in-memory full-duplex byte pipe. `MemoryTransport.makePair()` returns two connected ends.
/// Used by tests (and handy for simulations); not used on the wire.
public final class MemoryTransport: ByteTransport, @unchecked Sendable {
    private final class Channel: @unchecked Sendable {
        let lock = NSLock()
        var buffer = Data()
        var closed = false
        var waiter: (count: Int, cont: CheckedContinuation<Data, Error>)?

        func push(_ data: Data) {
            lock.lock()
            buffer.append(data)
            let ready = takeIfSatisfied()
            lock.unlock()
            ready?()
        }

        func close() {
            lock.lock()
            closed = true
            var cb: (() -> Void)?
            if let w = waiter { waiter = nil; cb = { w.cont.resume(throwing: ProtocolError.closed) } }
            lock.unlock()
            cb?()
        }

        // Caller holds the lock. Returns a closure to run after unlocking.
        private func takeIfSatisfied() -> (() -> Void)? {
            guard let w = waiter, buffer.count >= w.count else { return nil }
            let chunk = Data(buffer.prefix(w.count))
            buffer.removeFirst(w.count)
            waiter = nil
            return { w.cont.resume(returning: chunk) }
        }

        func read(_ count: Int) async throws -> Data {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                lock.lock()
                if buffer.count >= count {
                    let chunk = Data(buffer.prefix(count))
                    buffer.removeFirst(count)
                    lock.unlock()
                    cont.resume(returning: chunk)
                } else if closed {
                    lock.unlock()
                    cont.resume(throwing: ProtocolError.closed)
                } else {
                    waiter = (count, cont)
                    lock.unlock()
                }
            }
        }
    }

    private let incoming: Channel
    private let outgoing: Channel
    /// Everything this end wrote, for assertions about wire contents.
    public private(set) var written = Data()
    private let writtenLock = NSLock()

    private init(incoming: Channel, outgoing: Channel) {
        self.incoming = incoming
        self.outgoing = outgoing
    }

    public static func makePair() -> (MemoryTransport, MemoryTransport) {
        let a = Channel(), b = Channel()
        return (MemoryTransport(incoming: a, outgoing: b), MemoryTransport(incoming: b, outgoing: a))
    }

    public func write(_ data: Data) throws {
        outgoing.lock.lock(); let isClosed = outgoing.closed; outgoing.lock.unlock()
        if isClosed { throw ProtocolError.closed }
        writtenLock.lock(); written.append(data); writtenLock.unlock()
        outgoing.push(data)
    }

    public func read(exactly count: Int) async throws -> Data { try await incoming.read(count) }
    public var pendingBytes: Int { 0 }

    public func close() {
        outgoing.close()
        incoming.close()
    }
}
