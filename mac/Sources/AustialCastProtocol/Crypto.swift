import CryptoKit
import Foundation

public extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self.init(bytes)
    }
}

public enum TVCrypto {
    public static func randomBytes(_ n: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    public static func sha256(_ parts: Data...) -> Data {
        var h = SHA256()
        parts.forEach { h.update(data: $0) }
        return Data(h.finalize())
    }

    public static func hmac(key: Data, _ parts: Data...) -> Data {
        var m = HMAC<SHA256>(key: SymmetricKey(data: key.isEmpty ? Data(count: 32) : key))
        parts.forEach { m.update(data: $0) }
        return Data(m.finalize())
    }

    public static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    public struct Ephemeral {
        public let privateKey: P256.KeyAgreement.PrivateKey
        public var publicX963: Data { privateKey.publicKey.x963Representation }
        public init() { privateKey = P256.KeyAgreement.PrivateKey() }
        public init(scalar: Data) throws { privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar) }
    }

    public static func ecdh(_ own: Ephemeral, peerX963: Data) throws -> Data {
        guard peerX963.count == 65, peerX963.first == 0x04 else { throw ProtocolError.malformed("public key") }
        let peer: P256.KeyAgreement.PublicKey
        do { peer = try P256.KeyAgreement.PublicKey(x963Representation: peerX963) } // validates on-curve
        catch { throw ProtocolError.malformed("public key not on curve") }
        let secret = try own.privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }

    public static func transcriptHash(hello: Data, challenge: Data) -> Data { sha256(hello, challenge) }

    public struct SessionKeys {
        public let clientToServer: PacketCipher
        public let serverToClient: PacketCipher
    }

    public static func deriveSessionKeys(shared: Data, transcript: Data) -> SessionKeys {
        func cipher(_ label: String) -> PacketCipher {
            let okm = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: shared),
                salt: transcript,
                info: Data("austialcast v1 \(label)".utf8),
                outputByteCount: 36
            ).withUnsafeBytes { Data($0) }
            return PacketCipher(key: okm.prefix(32), noncePrefix: okm.suffix(4))
        }
        return SessionKeys(clientToServer: cipher("client->server"), serverToClient: cipher("server->client"))
    }

    public static func clientProof(secret: Data, transcript: Data) -> Data {
        hmac(key: secret, Data("austialcast v1 client".utf8), transcript)
    }

    public static func serverProof(secret: Data, transcript: Data) -> Data {
        hmac(key: secret, Data("austialcast v1 server".utf8), transcript)
    }
}

/// AES-256-GCM for one direction. Nonce = 4 byte direction prefix || 64 bit big-endian counter.
public final class PacketCipher: @unchecked Sendable {
    private let key: SymmetricKey
    private let prefix: Data
    private var counter: UInt64 = 0
    private let lock = NSLock()

    public init(key: Data, noncePrefix: Data) {
        precondition(key.count == 32 && noncePrefix.count == 4)
        self.key = SymmetricKey(data: key)
        self.prefix = Data(noncePrefix)
    }

    private func nextNonce() throws -> AES.GCM.Nonce {
        var n = prefix
        var c = counter
        counter += 1
        var tail = [UInt8](repeating: 0, count: 8)
        for i in stride(from: 7, through: 0, by: -1) { tail[i] = UInt8(c & 0xff); c >>= 8 }
        n.append(contentsOf: tail)
        return try AES.GCM.Nonce(data: n)
    }

    public func seal(aad: Data, plain: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let box = try AES.GCM.seal(plain, using: key, nonce: nextNonce(), authenticating: aad)
        return box.ciphertext + box.tag
    }

    public func open(aad: Data, sealed: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard sealed.count >= gcmTagBytes else { throw ProtocolError.authenticationFailed }
        let split = sealed.count - gcmTagBytes
        let ct = sealed.prefix(split)
        let tag = sealed.suffix(gcmTagBytes)
        do {
            let box = try AES.GCM.SealedBox(nonce: nextNonce(), ciphertext: ct, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw ProtocolError.authenticationFailed
        }
    }
}
