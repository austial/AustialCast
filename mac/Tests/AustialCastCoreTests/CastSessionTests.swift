import XCTest
import AustialCastProtocol
@testable import AustialCastCore

/// A scriptable receiver speaking the server side of the protocol over an in-memory pipe.
final class FakeReceiver: @unchecked Sendable {
    struct Options {
        var pin = "123456"
        var deviceId = "tv-1"
        var name = "Fake TV"
        var trustedToken: Data?          // token the receiver accepts for this sender
        var forgeServerProof = false     // simulate a man-in-the-middle that does not know the PIN
        var busy = false
        var issueToken = true
    }

    let transport: MemoryTransport
    private let opts: Options
    private let reader: FrameReader
    private let writer: FrameWriter
    private let lock = NSLock()
    private var _frames: [Frame] = []
    private var _modes: [String] = []
    private var _streamStart: StreamStart?
    private(set) var issuedToken: Data?
    private var task: Task<Void, Never>?

    var frames: [Frame] { lock.lock(); defer { lock.unlock() }; return _frames }
    var authModes: [String] { lock.lock(); defer { lock.unlock() }; return _modes }
    var streamStart: StreamStart? { lock.lock(); defer { lock.unlock() }; return _streamStart }

    init(transport: MemoryTransport, options: Options = Options()) {
        self.transport = transport
        self.opts = options
        reader = FrameReader(transport: transport)
        writer = FrameWriter(transport: transport)
    }

    func start() { task = Task { await self.serve() } }
    func stop() { task?.cancel(); transport.close() }

    func send(_ type: FrameType, _ payload: Data = Data()) { try? writer.write(type, payload) }
    func sendControl(_ c: Control) { send(.control, try! Messages.encode(c)) }

    private func serve() async {
        do {
            let helloFrame = try await reader.read()
            let hello = try Messages.decode(Hello.self, from: helloFrame.payload)
            let eph = TVCrypto.Ephemeral()
            let challengeBytes = try Messages.encode(Challenge(
                deviceId: opts.deviceId, name: opts.name, publicKey: eph.publicX963.base64EncodedString(),
                trusted: opts.trustedToken != nil, maxWidth: 1920, maxHeight: 1080, maxFps: 30))
            try writer.write(.challenge, challengeBytes)
            let shared = try TVCrypto.ecdh(eph, peerX963: Data(base64Encoded: hello.publicKey)!)
            let transcript = TVCrypto.transcriptHash(hello: helloFrame.payload, challenge: challengeBytes)
            let keys = TVCrypto.deriveSessionKeys(shared: shared, transcript: transcript)
            reader.setCipher(keys.clientToServer)
            writer.setCipher(keys.serverToClient)

            authLoop: for _ in 0..<3 {
                let f = try await reader.read()
                let auth = try Messages.decode(Auth.self, from: f.payload)
                lock.lock(); _modes.append(auth.mode); lock.unlock()
                let secret: Data
                switch auth.mode {
                case "pin": secret = Data(opts.pin.utf8)
                case "token":
                    guard let t = opts.trustedToken else { fallthrough }
                    secret = t
                default:
                    try writer.write(.authResult, try Messages.encode(AuthResult(ok: false, reason: AuthFailure.badToken, retry: true)))
                    continue authLoop
                }
                guard TVCrypto.constantTimeEquals(Data(hex: auth.proof) ?? Data(), TVCrypto.clientProof(secret: secret, transcript: transcript)) else {
                    try writer.write(.authResult, try Messages.encode(AuthResult(ok: false, reason: auth.mode == "pin" ? AuthFailure.badPin : AuthFailure.badToken, retry: true)))
                    continue authLoop
                }
                var token: Data?
                if auth.mode == "pin", opts.issueToken { token = TVCrypto.randomBytes(32); issuedToken = token }
                let proofSecret = opts.forgeServerProof ? Data("not-the-secret".utf8) : secret
                try writer.write(.authResult, try Messages.encode(AuthResult(ok: true, proof: TVCrypto.serverProof(secret: proofSecret, transcript: transcript).hex, token: token?.hex)))
                break authLoop
            }
            if opts.busy { send(.bye, try Messages.encode(Bye(reason: ByeReason.busy))); return }
            while !Task.isCancelled {
                let f = try await reader.read()
                if f.type == .ping { send(.pong, f.payload) }
                if f.type == .streamStart { lock.lock(); _streamStart = try? Messages.decode(StreamStart.self, from: f.payload); lock.unlock() }
                lock.lock(); _frames.append(f); lock.unlock()
                if f.type == .bye { break }
            }
        } catch {
            // connection ended
        }
    }

    func waitFor(_ timeout: TimeInterval = 8, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func expect(_ predicate: () -> Bool, _ message: String = "condition not reached", file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await waitFor(8, predicate)
        XCTAssertTrue(ok, message, file: file, line: line)
    }

    func expect(_ timeout: TimeInterval, _ predicate: () -> Bool, _ message: String = "condition not reached", file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await waitFor(timeout, predicate)
        XCTAssertTrue(ok, message, file: file, line: line)
    }

    func videoFrames() -> [(keyframe: Bool, pts: Int64, data: Data)] {
        frames.filter { $0.type == .videoFrame }.map { f in
            (f.payload[f.payload.startIndex] & 1 == 1, Int64(bitPattern: f.payload.bigEndianUInt64(at: 1)), f.payload.dropFirst(9))
        }
    }
}

final class CastSessionTests: XCTestCase {
    private func makeSession(_ transport: MemoryTransport, tokens: TokenStore = MemoryTokenStore()) -> CastSession {
        CastSession(identity: DeviceIdentity(deviceId: "mac-1", name: "Test Mac"), tokens: tokens) { _ in transport }
    }

    private func request(pin: String? = "123456", audio: Bool = true) -> CastRequest {
        CastRequest(target: .host("test", 1), pin: pin, source: .testPattern(width: 640, height: 360), preset: .hd720p30, captureAudio: audio)
    }

    private func runInBackground(_ session: CastSession, _ req: CastRequest) -> Task<Void, Error> {
        Task { try await session.run(req) }
    }

    func testPairsStreamsAndStops() async throws {
        let (client, server) = MemoryTransport.makePair()
        let receiver = FakeReceiver(transport: server)
        receiver.start()
        let tokens = MemoryTokenStore()
        let session = makeSession(client, tokens: tokens)
        let states = Locked<[CastState]>([])
        session.onState = { s in states.mutate { $0.append(s) } }
        let run = runInBackground(session, request())

        await receiver.expect({ receiver.videoFrames().count >= 25 && receiver.frames.contains { $0.type == .audioFrame } }, "receiver should get video and audio")
        session.stop()
        try await run.value

        let start = try XCTUnwrap(receiver.streamStart)
        XCTAssertEqual(start.width, 640)
        XCTAssertEqual(start.height, 360)
        XCTAssertEqual(start.fps, 30)
        XCTAssertEqual(start.audio?.config, "1190")
        XCTAssertEqual(start.title, "Test pattern")
        XCTAssertEqual(receiver.authModes, ["pin"])

        let types = receiver.frames.map(\.type)
        let firstConfig = try XCTUnwrap(types.firstIndex(of: .videoConfig))
        XCTAssertLessThan(firstConfig, try XCTUnwrap(types.firstIndex(of: .videoFrame)), "config precedes the first frame")
        let video = receiver.videoFrames()
        XCTAssertTrue(video[0].keyframe)
        XCTAssertTrue(AnnexB.containsIDR(video[0].data))
        XCTAssertEqual(video.map(\.pts), video.map(\.pts).sorted())
        assertClose(video[0].pts, 0, accuracy: 100_000)
        XCTAssertEqual(tokens.token(for: "tv-1"), receiver.issuedToken, "pairing token is stored")
        XCTAssertTrue(receiver.frames.contains { $0.type == .bye }, "sender says goodbye")
        XCTAssertEqual(states.value.first, .connecting)
        XCTAssertTrue(states.value.contains(.authenticating))
        XCTAssertTrue(states.value.contains { if case .streaming(let n, 640, 360, 30) = $0 { return n == "Fake TV" } else { return false } })
        XCTAssertEqual(states.value.last, .ended(nil), "user-initiated stop is not an error")
        receiver.stop()
    }

    func testWithoutAudioNoAudioFramesAreSent() async throws {
        let (client, server) = MemoryTransport.makePair()
        let receiver = FakeReceiver(transport: server)
        receiver.start()
        let session = makeSession(client)
        let run = runInBackground(session, request(audio: false))
        await receiver.expect({ receiver.videoFrames().count >= 10 })
        session.stop()
        try await run.value
        XCTAssertNil(receiver.streamStart?.audio)
        XCTAssertFalse(receiver.frames.contains { $0.type == .audioFrame })
        receiver.stop()
    }

    func testTrustedReconnectUsesTokenWithoutPin() async throws {
        let token = TVCrypto.randomBytes(32)
        let tokens = MemoryTokenStore()
        tokens.save(token: token, receiverId: "tv-1", name: "Fake TV")
        let (client, server) = MemoryTransport.makePair()
        var o = FakeReceiver.Options(); o.trustedToken = token
        let receiver = FakeReceiver(transport: server, options: o)
        receiver.start()
        let session = makeSession(client, tokens: tokens)
        let run = runInBackground(session, request(pin: nil))
        await receiver.expect({ receiver.videoFrames().count >= 5 })
        session.stop()
        try await run.value
        XCTAssertEqual(receiver.authModes, ["token"])
        receiver.stop()
    }

    func testRevokedTokenFallsBackToPin() async throws {
        let tokens = MemoryTokenStore()
        tokens.save(token: Data(repeating: 1, count: 32), receiverId: "tv-1", name: "Fake TV")
        let (client, server) = MemoryTransport.makePair()
        var o = FakeReceiver.Options(); o.trustedToken = Data(repeating: 2, count: 32) // TV re-paired meanwhile
        let receiver = FakeReceiver(transport: server, options: o)
        receiver.start()
        let session = makeSession(client, tokens: tokens)
        let run = runInBackground(session, request(pin: "123456"))
        await receiver.expect({ receiver.videoFrames().count >= 5 })
        session.stop()
        try await run.value
        XCTAssertEqual(receiver.authModes, ["token", "pin"])
        XCTAssertEqual(tokens.token(for: "tv-1"), receiver.issuedToken, "new token replaces the revoked one")
        receiver.stop()
    }

    func testPinRequiredWhenNotPaired() async throws {
        let (client, server) = MemoryTransport.makePair()
        let receiver = FakeReceiver(transport: server)
        receiver.start()
        let session = makeSession(client)
        do {
            try await session.run(request(pin: nil))
            XCTFail("expected pinRequired")
        } catch let e as SenderError {
            XCTAssertEqual(e, .pinRequired(receiverName: "Fake TV"))
        }
        receiver.stop()
    }

    func testWrongPinIsReported() async throws {
        let (client, server) = MemoryTransport.makePair()
        let receiver = FakeReceiver(transport: server)
        receiver.start()
        let session = makeSession(client)
        do {
            try await session.run(request(pin: "000000"))
            XCTFail("expected wrongPin")
        } catch let e as SenderError {
            XCTAssertEqual(e, .wrongPin(canRetry: true))
        }
        receiver.stop()
    }

    func testForgedReceiverProofAbortsTheCast() async throws {
        let (client, server) = MemoryTransport.makePair()
        var o = FakeReceiver.Options(); o.forgeServerProof = true
        let receiver = FakeReceiver(transport: server, options: o)
        receiver.start()
        let tokens = MemoryTokenStore()
        let session = makeSession(client, tokens: tokens)
        do {
            try await session.run(request())
            XCTFail("a receiver that cannot prove the PIN must be rejected")
        } catch let e as SenderError {
            XCTAssertEqual(e, .receiverNotAuthentic)
        }
        XCTAssertNil(tokens.token(for: "tv-1"), "no token may be stored from an unauthenticated receiver")
        XCTAssertFalse(receiver.frames.contains { $0.type == .videoFrame })
        receiver.stop()
    }

    func testBusyReceiver() async throws {
        let (client, server) = MemoryTransport.makePair()
        var o = FakeReceiver.Options(); o.busy = true
        let receiver = FakeReceiver(transport: server, options: o)
        receiver.start()
        let session = makeSession(client)
        let states = Locked<[CastState]>([])
        session.onState = { s in states.mutate { $0.append(s) } }
        // Busy is signalled by BYE right after a successful auth, so the cast ends quickly.
        try? await session.run(request())
        if case .ended(let reason)? = states.value.last { XCTAssertNotNil(reason) } else { XCTFail("expected ended state") }
        receiver.stop()
    }

    func testReceiverKeyframeRequestIsHonoured() async throws {
        let (client, server) = MemoryTransport.makePair()
        let receiver = FakeReceiver(transport: server)
        receiver.start()
        let session = makeSession(client)
        let run = runInBackground(session, request())
        await receiver.expect({ receiver.videoFrames().count >= 12 })
        let before = receiver.videoFrames().count
        receiver.sendControl(Control(cmd: ControlCommand.requestKeyframe))
        await receiver.expect({ receiver.videoFrames().dropFirst(before).contains { $0.keyframe } },
                      "a keyframe should follow the request (periodic interval is 2 s)")
        session.stop()
        try await run.value
        receiver.stop()
    }

    func testPauseStopsVideoAndResumeStartsWithKeyframe() async throws {
        let (client, server) = MemoryTransport.makePair()
        let receiver = FakeReceiver(transport: server)
        receiver.start()
        let session = makeSession(client)
        let run = runInBackground(session, request())
        await receiver.expect({ receiver.videoFrames().count >= 8 })

        session.setPaused(true)
        XCTAssertTrue(session.isPaused)
        await receiver.expect({ receiver.frames.contains { $0.type == .control } })
        try await Task.sleep(nanoseconds: 200_000_000) // let in-flight frames drain
        let atPause = receiver.videoFrames().count
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(receiver.videoFrames().count, atPause, "no video while paused")

        session.setPaused(false)
        await receiver.expect({ receiver.videoFrames().count > atPause + 3 })
        XCTAssertTrue(receiver.videoFrames()[atPause].keyframe, "first frame after resume is a keyframe")
        let controls = receiver.frames.filter { $0.type == .control }.compactMap { try? Messages.decode(Control.self, from: $0.payload).cmd }
        XCTAssertEqual(controls, [ControlCommand.pause, ControlCommand.resume])
        session.stop()
        try await run.value
        receiver.stop()
    }

    func testReceiverByeEndsTheCastWithAMessage() async throws {
        let (client, server) = MemoryTransport.makePair()
        let receiver = FakeReceiver(transport: server)
        receiver.start()
        let session = makeSession(client)
        let states = Locked<[CastState]>([])
        session.onState = { s in states.mutate { $0.append(s) } }
        let run = runInBackground(session, request())
        await receiver.expect({ receiver.videoFrames().count >= 5 })
        receiver.send(.bye, try Messages.encode(Bye(reason: ByeReason.user)))
        try await run.value
        XCTAssertEqual(states.value.last, .ended("The TV stopped the cast"))
        receiver.stop()
    }

    func testConnectionLossIsReported() async throws {
        let (client, server) = MemoryTransport.makePair()
        let receiver = FakeReceiver(transport: server)
        receiver.start()
        let session = makeSession(client)
        let states = Locked<[CastState]>([])
        session.onState = { s in states.mutate { $0.append(s) } }
        let run = runInBackground(session, request())
        await receiver.expect({ receiver.videoFrames().count >= 5 })
        receiver.stop()
        try await run.value
        XCTAssertEqual(states.value.last, .ended("Connection to the TV was lost"))
    }

    func testStatsAreReported() async throws {
        let (client, server) = MemoryTransport.makePair()
        let receiver = FakeReceiver(transport: server)
        receiver.start()
        let session = makeSession(client)
        let stats = Locked<[CastStats]>([])
        session.onStats = { s in stats.mutate { $0.append(s) } }
        let run = runInBackground(session, request())
        await receiver.expect(6, { stats.value.count >= 2 })
        session.stop()
        try await run.value
        let last = try XCTUnwrap(stats.value.last)
        XCTAssertEqual(last.fps, 30, accuracy: 8)
        XCTAssertEqual(last.width, 640)
        XCTAssertGreaterThan(last.targetBitrateKbps, 100)
        receiver.stop()
    }

    func testTransportFailureSurfacesError() async {
        struct Boom: Error {}
        let session = CastSession(identity: DeviceIdentity(deviceId: "m", name: "M"), tokens: MemoryTokenStore()) { _ in throw Boom() }
        do { try await session.run(request()); XCTFail() } catch { XCTAssertTrue(error is Boom) }
    }
}

extension XCTestCase {
    func assertClose(_ a: Int64, _ b: Int64, accuracy: Int64, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(a - b), accuracy, file: file, line: line)
    }
}
