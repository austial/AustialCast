import XCTest
@testable import AustialCastProtocol

final class FrameAndCryptoTests: XCTestCase {
    func testHexRoundTrip() {
        let d = Data([0, 1, 0x7f, 0x80, 0xff])
        XCTAssertEqual(d.hex, "00017f80ff")
        XCTAssertEqual(Data(hex: "00017F80FF"), d)
        XCTAssertNil(Data(hex: "abc"))
        XCTAssertNil(Data(hex: "zz"))
    }

    func testHeaderLayout() {
        XCTAssertEqual(buildHeader(type: 9, length: 2), Data([0x54, 0x43, 1, 9, 0, 0, 0, 2]))
        XCTAssertEqual(buildHeader(type: 7, length: 0x01020304), Data([0x54, 0x43, 1, 7, 1, 2, 3, 4]))
    }

    func testRoundTripAllFrameTypes() async throws {
        let (a, b) = MemoryTransport.makePair()
        let w = FrameWriter(transport: a), r = FrameReader(transport: b)
        for t in FrameType.allCases {
            try w.write(t, Data(repeating: t.rawValue, count: Int(t.rawValue) * 3))
        }
        for t in FrameType.allCases {
            let f = try await r.read()
            XCTAssertEqual(f.type, t)
            XCTAssertEqual(f.payload, Data(repeating: t.rawValue, count: Int(t.rawValue) * 3))
        }
    }

    func testRejectsBadMagicVersionTypeAndLength() async throws {
        func read(_ bytes: [UInt8]) async -> Error? {
            let (a, b) = MemoryTransport.makePair()
            try? a.write(Data(bytes))
            do { _ = try await FrameReader(transport: b).read(); return nil } catch { return error }
        }
        let e1 = await read([0, 0, 1, 9, 0, 0, 0, 0])
        let e2 = await read([0x54, 0x43, 9, 9, 0, 0, 0, 0])
        let e3 = await read([0x54, 0x43, 1, 99, 0, 0, 0, 0])
        let e4 = await read([0x54, 0x43, 1, 7, 0x7f, 0xff, 0xff, 0xff])
        XCTAssertEqual(e1 as? ProtocolError, .badMagic)
        XCTAssertEqual(e2 as? ProtocolError, .unsupportedVersion(9))
        XCTAssertEqual(e3 as? ProtocolError, .unknownType(99))
        XCTAssertEqual(e4 as? ProtocolError, .invalidLength(0x7fffffff))
    }

    func testClosedTransportSurfacesAsClosed() async {
        let (a, b) = MemoryTransport.makePair()
        a.close()
        do { _ = try await FrameReader(transport: b).read(); XCTFail() } catch { XCTAssertEqual(error as? ProtocolError, .closed) }
    }

    func testWriterRejectsOversizedPayload() {
        let (a, _) = MemoryTransport.makePair()
        XCTAssertThrowsError(try FrameWriter(transport: a).write(.videoFrame, Data(count: maxPayload + 1)))
    }

    private func cipherPair() -> (PacketCipher, PacketCipher) {
        let key = Data((0..<32).map { UInt8($0) }), prefix = Data([1, 2, 3, 4])
        return (PacketCipher(key: key, noncePrefix: prefix), PacketCipher(key: key, noncePrefix: prefix))
    }

    func testEncryptedRoundTripAndNoPlaintextOnWire() async throws {
        let (a, b) = MemoryTransport.makePair()
        let (enc, dec) = cipherPair()
        let w = FrameWriter(transport: a), r = FrameReader(transport: b)
        w.setCipher(enc); r.setCipher(dec)
        let secret = Data("SECRET-SCREEN-CONTENT".utf8)
        try w.write(.videoFrame, secret)
        XCTAssertNil(a.written.range(of: secret))
        let f = try await r.read()
        XCTAssertEqual(f.payload, secret)
    }

    func testTamperingIsDetected() async throws {
        let (enc, dec) = cipherPair()
        let (a, _) = MemoryTransport.makePair()
        let w = FrameWriter(transport: a); w.setCipher(enc)
        try w.write(.videoFrame, Data(count: 64))
        var wire = a.written
        wire[12] ^= 1
        let (c, d) = MemoryTransport.makePair()
        try c.write(wire)
        let r = FrameReader(transport: d); r.setCipher(dec)
        do { _ = try await r.read(); XCTFail("expected failure") } catch { XCTAssertEqual(error as? ProtocolError, .authenticationFailed) }
    }

    func testReplayAndReorderAreDetected() async throws {
        let (enc, dec) = cipherPair()
        let (a, _) = MemoryTransport.makePair()
        let w = FrameWriter(transport: a); w.setCipher(enc)
        try w.write(.control, Data("one".utf8))
        let first = a.written
        try w.write(.control, Data("two".utf8))
        let second = a.written.suffix(from: first.count)
        let (c, d) = MemoryTransport.makePair()
        try c.write(Data(second)); try c.write(first)
        let r = FrameReader(transport: d); r.setCipher(dec)
        do { _ = try await r.read(); XCTFail() } catch { XCTAssertEqual(error as? ProtocolError, .authenticationFailed) }
    }

    func testHKDFRfc5869Case1() {
        let ikm = Data(repeating: 0x0b, count: 22)
        let salt = Data(hex: "000102030405060708090a0b0c")!
        let info = Data(hex: "f0f1f2f3f4f5f6f7f8f9")!
        // Use CryptoKit HKDF directly, mirroring how deriveSessionKeys is built.
        let okm = TestHKDF.derive(ikm: ikm, salt: salt, info: info, count: 42)
        XCTAssertEqual(okm.hex, "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    }

    func testRejectsOffCurvePublicKey() throws {
        let a = TVCrypto.Ephemeral()
        var bad = a.publicX963
        bad[64] ^= 1
        XCTAssertThrowsError(try TVCrypto.ecdh(a, peerX963: bad))
        XCTAssertThrowsError(try TVCrypto.ecdh(a, peerX963: Data(count: 10)))
    }

    func testEcdhAgrees() throws {
        let a = TVCrypto.Ephemeral(), b = TVCrypto.Ephemeral()
        XCTAssertEqual(try TVCrypto.ecdh(a, peerX963: b.publicX963), try TVCrypto.ecdh(b, peerX963: a.publicX963))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(TVCrypto.constantTimeEquals(Data([1, 2]), Data([1, 2])))
        XCTAssertFalse(TVCrypto.constantTimeEquals(Data([1, 2]), Data([1, 3])))
        XCTAssertFalse(TVCrypto.constantTimeEquals(Data([1]), Data([1, 2])))
    }

    func testMediaPayloadBigEndian() {
        let d = MediaPayload.encodeAudio(ptsUs: 1, data: Data([9]))
        XCTAssertEqual(d, Data([0, 0, 0, 0, 0, 0, 0, 1, 9]))
        XCTAssertEqual(d.bigEndianUInt64(), 1)
    }
}

import CryptoKit
enum TestHKDF {
    static func derive(ikm: Data, salt: Data, info: Data, count: Int) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: count)
            .withUnsafeBytes { Data($0) }
    }
}
