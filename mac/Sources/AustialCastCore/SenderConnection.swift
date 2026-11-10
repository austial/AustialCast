import Foundation
import AustialCastProtocol

public struct DeviceIdentity: Sendable, Equatable {
    public var deviceId: String
    public var name: String
    public init(deviceId: String, name: String) { self.deviceId = deviceId; self.name = name }
}

public enum SenderError: Error, Equatable, CustomStringConvertible {
    case pinRequired(receiverName: String)
    case wrongPin(canRetry: Bool)
    case badToken
    case locked(String)
    case busy
    case rejected(String)
    /// The receiver could not prove it knows the PIN/token: possible man-in-the-middle.
    case receiverNotAuthentic
    case connectionClosed

    public var description: String {
        switch self {
        case .pinRequired(let n): return "Enter the PIN shown on \(n)"
        case .wrongPin: return "Wrong PIN. A new PIN is now shown on the TV."
        case .badToken: return "This Mac is no longer paired with the TV"
        case .locked(let m): return m
        case .busy: return "The TV is already receiving another cast"
        case .rejected(let r): return "The TV refused the connection (\(r))"
        case .receiverNotAuthentic: return "The TV failed to prove its identity — connection aborted"
        case .connectionClosed: return "The TV closed the connection"
        }
    }
}

public enum ReceiverEvent: Sendable {
    case control(Control)
    case stats(StatsReport)
    case pong(rttMs: Double)
    case bye(Bye)
    case closed
}

/// Sender side of the AustialCast protocol on top of any `ByteTransport`.
public final class SenderConnection: @unchecked Sendable {
    private let transport: ByteTransport
    private let reader: FrameReader
    private let writer: FrameWriter
    private let identity: DeviceIdentity
    private let appVersion: String
    private var transcript = Data()
    private var keys: TVCrypto.SessionKeys?
    public private(set) var challenge: Challenge?

    private var continuation: AsyncStream<ReceiverEvent>.Continuation?
    public private(set) var events: AsyncStream<ReceiverEvent>!
    private var readerTask: Task<Void, Never>?

    public var pendingBytes: Int { transport.pendingBytes }

    public init(transport: ByteTransport, identity: DeviceIdentity, appVersion: String = "1.0.0") {
        self.transport = transport
        self.reader = FrameReader(transport: transport)
        self.writer = FrameWriter(transport: transport)
        self.identity = identity
        self.appVersion = appVersion
        self.events = AsyncStream { self.continuation = $0 }
    }

    /// Exchanges HELLO/CHALLENGE and switches the connection to AES-GCM.
    public func handshake() async throws -> Challenge {
        let eph = TVCrypto.Ephemeral()
        let hello = Hello(deviceId: identity.deviceId, name: identity.name, appVersion: appVersion,
                          publicKey: eph.publicX963.base64EncodedString())
        let helloBytes = try Messages.encode(hello)
        try writer.write(.hello, helloBytes)
        let frame = try await reader.read()
        if frame.type == .bye {
            let bye = try Messages.decode(Bye.self, from: frame.payload)
            throw SenderError.rejected(bye.reason)
        }
        guard frame.type == .challenge else { throw ProtocolError.malformed("expected CHALLENGE") }
        let ch = try Messages.decode(Challenge.self, from: frame.payload)
        guard ch.protocol == Int(protocolVersion) else { throw ProtocolError.unsupportedVersion(UInt8(truncatingIfNeeded: ch.protocol)) }
        guard let peerKey = Data(base64Encoded: ch.publicKey) else { throw ProtocolError.malformed("public key encoding") }
        let shared = try TVCrypto.ecdh(eph, peerX963: peerKey)
        transcript = TVCrypto.transcriptHash(hello: helloBytes, challenge: frame.payload)
        let k = TVCrypto.deriveSessionKeys(shared: shared, transcript: transcript)
        keys = k
        writer.setCipher(k.clientToServer)
        reader.setCipher(k.serverToClient)
        challenge = ch
        return ch
    }

    /// Authenticates with the PIN currently shown on the TV. Returns the pairing token (hex) if issued.
    @discardableResult
    public func authenticate(pin: String) async throws -> Data? {
        let result = try await authenticate(mode: "pin", secret: Data(pin.utf8))
        return result.token.flatMap { Data(hex: $0) }
    }

    public func authenticate(token: Data) async throws {
        _ = try await authenticate(mode: "token", secret: token)
    }

    private func authenticate(mode: String, secret: Data) async throws -> AuthResult {
        let proof = TVCrypto.clientProof(secret: secret, transcript: transcript).hex
        try writer.write(.auth, try Messages.encode(Auth(mode: mode, proof: proof)))
        let frame = try await reader.read()
        if frame.type == .bye {
            let bye = try Messages.decode(Bye.self, from: frame.payload)
            throw bye.reason == ByeReason.busy ? SenderError.busy : SenderError.rejected(bye.reason)
        }
        guard frame.type == .authResult else { throw ProtocolError.malformed("expected AUTH_RESULT") }
        let result = try Messages.decode(AuthResult.self, from: frame.payload)
        guard result.ok else {
            switch result.reason {
            case AuthFailure.badPin: throw SenderError.wrongPin(canRetry: result.retry ?? false)
            case AuthFailure.badToken: throw SenderError.badToken
            case AuthFailure.locked: throw SenderError.locked(result.message ?? "Too many wrong PINs")
            default: throw SenderError.rejected(result.reason ?? "unknown")
            }
        }
        // Mutual authentication: the receiver must prove it knows the same secret.
        let expected = TVCrypto.serverProof(secret: secret, transcript: transcript)
        guard let got = result.proof.flatMap({ Data(hex: $0) }), TVCrypto.constantTimeEquals(got, expected) else {
            throw SenderError.receiverNotAuthentic
        }
        return result
    }

    // MARK: - Streaming

    /// Starts the background reader that turns incoming frames into `events`.
    public func startEventLoop() {
        readerTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let frame = try await self.reader.read()
                    switch frame.type {
                    case .ping:
                        try? self.writer.write(.pong, frame.payload)
                    case .pong:
                        if frame.payload.count >= 8 {
                            let sent = frame.payload.bigEndianUInt64()
                            let now = DispatchTime.now().uptimeNanoseconds / 1000
                            self.continuation?.yield(.pong(rttMs: Double(now &- sent) / 1000.0))
                        }
                    case .control:
                        if let c = try? Messages.decode(Control.self, from: frame.payload) { self.continuation?.yield(.control(c)) }
                    case .stats:
                        if let s = try? Messages.decode(StatsReport.self, from: frame.payload) { self.continuation?.yield(.stats(s)) }
                    case .bye:
                        if let b = try? Messages.decode(Bye.self, from: frame.payload) { self.continuation?.yield(.bye(b)) }
                        throw ProtocolError.closed
                    default:
                        break
                    }
                }
            } catch {}
            self.continuation?.yield(.closed)
            self.continuation?.finish()
        }
    }

    public func sendStreamStart(_ s: StreamStart) throws { try writer.write(.streamStart, try Messages.encode(s)) }
    public func sendVideoConfig(_ annexB: Data) throws { try writer.write(.videoConfig, annexB) }

    public func sendVideo(keyframe: Bool, ptsUs: Int64, data: Data) throws {
        try writer.write(.videoFrame, MediaPayload.encodeVideo(keyframe: keyframe, ptsUs: ptsUs, data: data))
    }

    public func sendAudio(ptsUs: Int64, data: Data) throws {
        try writer.write(.audioFrame, MediaPayload.encodeAudio(ptsUs: ptsUs, data: data))
    }

    public func sendControl(_ c: Control) throws { try writer.write(.control, try Messages.encode(c)) }

    public func sendPing() throws {
        var payload = Data()
        payload.append(bigEndian: DispatchTime.now().uptimeNanoseconds / 1000)
        try writer.write(.ping, payload)
    }

    public func sendBye(_ reason: String = ByeReason.user) {
        try? writer.write(.bye, (try? Messages.encode(Bye(reason: reason))) ?? Data())
    }

    public func close() {
        readerTask?.cancel()
        transport.close()
    }
}
