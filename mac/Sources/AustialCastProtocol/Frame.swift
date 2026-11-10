import Foundation

public let protocolVersion: UInt8 = 1
public let defaultPort: UInt16 = 7391
public let serviceType = "_austialcast._tcp"
public let headerSize = 8
public let maxPayload = 16 * 1024 * 1024
public let gcmTagBytes = 16

public enum FrameType: UInt8, CaseIterable, Sendable {
    case hello = 1, challenge, auth, authResult, streamStart, videoConfig, videoFrame
    case audioFrame, ping, pong, control, stats, bye
}

public enum ProtocolError: Error, Equatable, CustomStringConvertible {
    case badMagic
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case invalidLength(Int)
    case payloadTooLarge(Int)
    case authenticationFailed
    case malformed(String)
    case closed
    case rejected(String)

    public var description: String {
        switch self {
        case .badMagic: return "bad magic"
        case .unsupportedVersion(let v): return "unsupported protocol version \(v)"
        case .unknownType(let t): return "unknown frame type \(t)"
        case .invalidLength(let l): return "invalid payload length \(l)"
        case .payloadTooLarge(let l): return "payload too large (\(l))"
        case .authenticationFailed: return "frame authentication failed"
        case .malformed(let m): return "malformed message: \(m)"
        case .closed: return "connection closed"
        case .rejected(let r): return "rejected by receiver: \(r)"
        }
    }
}

public struct Frame: Sendable {
    public let type: FrameType
    public let payload: Data
    public init(type: FrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

/// The byte pipe underneath a connection. Implemented over Network.framework in production
/// and by an in-memory pipe in tests.
public protocol ByteTransport: AnyObject, Sendable {
    /// Queues bytes for sending, preserving order. Must not block.
    func write(_ data: Data) throws
    /// Reads exactly `count` bytes or throws `ProtocolError.closed`.
    func read(exactly count: Int) async throws -> Data
    /// Bytes handed to `write` that the OS has not accepted yet (for congestion control).
    var pendingBytes: Int { get }
    func close()
}

/// Builds the 8 byte header: magic "TC", version, type, length (big endian).
public func buildHeader(type: UInt8, length: Int) -> Data {
    var h = Data(count: headerSize)
    h[0] = 0x54
    h[1] = 0x43
    h[2] = protocolVersion
    h[3] = type
    h[4] = UInt8((length >> 24) & 0xff)
    h[5] = UInt8((length >> 16) & 0xff)
    h[6] = UInt8((length >> 8) & 0xff)
    h[7] = UInt8(length & 0xff)
    return h
}

public final class FrameWriter: @unchecked Sendable {
    private let transport: ByteTransport
    private let lock = NSLock()
    private var cipher: PacketCipher?

    public init(transport: ByteTransport) { self.transport = transport }

    public func setCipher(_ c: PacketCipher?) {
        lock.lock(); cipher = c; lock.unlock()
    }

    /// Seals (if encryption is on) and queues a frame. Sealing and queueing happen under one lock so
    /// the on-wire order always matches the nonce counter order.
    public func write(_ type: FrameType, _ payload: Data = Data()) throws {
        lock.lock()
        defer { lock.unlock() }
        let sealedSize = payload.count + (cipher == nil ? 0 : gcmTagBytes)
        guard sealedSize <= maxPayload else { throw ProtocolError.payloadTooLarge(payload.count) }
        let header = buildHeader(type: type.rawValue, length: sealedSize)
        let body = try cipher?.seal(aad: header, plain: payload) ?? payload
        var out = header
        out.append(body)
        try transport.write(out)
    }
}

public final class FrameReader: @unchecked Sendable {
    private let transport: ByteTransport
    private var cipher: PacketCipher?
    private let lock = NSLock()

    public init(transport: ByteTransport) { self.transport = transport }

    public func setCipher(_ c: PacketCipher?) {
        lock.lock(); cipher = c; lock.unlock()
    }

    public func read() async throws -> Frame {
        let header = try await transport.read(exactly: headerSize)
        guard header[header.startIndex] == 0x54, header[header.startIndex + 1] == 0x43 else { throw ProtocolError.badMagic }
        let version = header[header.startIndex + 2]
        guard version == protocolVersion else { throw ProtocolError.unsupportedVersion(version) }
        let rawType = header[header.startIndex + 3]
        guard let type = FrameType(rawValue: rawType) else { throw ProtocolError.unknownType(rawType) }
        let b = header.startIndex
        let length = Int(header[b + 4]) << 24 | Int(header[b + 5]) << 16 | Int(header[b + 6]) << 8 | Int(header[b + 7])
        guard length >= 0, length <= maxPayload else { throw ProtocolError.invalidLength(length) }
        let body = length == 0 ? Data() : try await transport.read(exactly: length)
        lock.lock(); let c = cipher; lock.unlock()
        guard let c else { return Frame(type: type, payload: body) }
        guard length >= gcmTagBytes else { throw ProtocolError.invalidLength(length) }
        return Frame(type: type, payload: try c.open(aad: Data(header), sealed: body))
    }
}
