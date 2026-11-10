import AVFoundation
import CoreMedia
import Foundation
import Network
import AustialCastProtocol

public enum CastTarget: @unchecked Sendable {
    case host(String, UInt16)
    case endpoint(NWEndpoint)
}

public enum CastSourceChoice: Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case testPattern(width: Int, height: Int)
}

public struct CastRequest: Sendable {
    public var target: CastTarget
    /// PIN shown on the TV; only needed for the first pairing (or when the saved token was revoked).
    public var pin: String?
    public var source: CastSourceChoice
    public var preset: QualityPreset
    public var captureAudio: Bool
    public var showCursor: Bool

    public init(target: CastTarget, pin: String? = nil, source: CastSourceChoice, preset: QualityPreset = .fullHD30,
                captureAudio: Bool = true, showCursor: Bool = true) {
        self.target = target; self.pin = pin; self.source = source; self.preset = preset
        self.captureAudio = captureAudio; self.showCursor = showCursor
    }
}

public enum CastState: Equatable, Sendable {
    case idle
    case connecting
    case authenticating
    case streaming(receiver: String, width: Int, height: Int, fps: Int)
    case paused
    case ended(String?)
}

public struct CastStats: Equatable, Sendable {
    public var fps: Double = 0
    public var bitrateKbps: Double = 0
    public var targetBitrateKbps: Double = 0
    public var rttMs: Double?
    public var droppedFrames: Int = 0
    public var width = 0
    public var height = 0

    public init(fps: Double = 0, bitrateKbps: Double = 0, targetBitrateKbps: Double = 0, rttMs: Double? = nil,
                droppedFrames: Int = 0, width: Int = 0, height: Int = 0) {
        self.fps = fps; self.bitrateKbps = bitrateKbps; self.targetBitrateKbps = targetBitrateKbps
        self.rttMs = rttMs; self.droppedFrames = droppedFrames; self.width = width; self.height = height
    }
}

public enum CastError: Error, CustomStringConvertible {
    case noSource
    case encoder(Error)
    public var description: String {
        switch self {
        case .noSource: return "Nothing to capture"
        case .encoder(let e): return "\(e)"
        }
    }
}

/// Runs one cast from connect to disconnect: handshake, capture, encode, send, congestion control.
public final class CastSession: @unchecked Sendable {
    public typealias TransportFactory = @Sendable (CastTarget) async throws -> ByteTransport

    private let identity: DeviceIdentity
    private let tokens: TokenStore
    private let transportFactory: TransportFactory
    private let appVersion: String

    public var onState: (@Sendable (CastState) -> Void)?
    public var onStats: (@Sendable (CastStats) -> Void)?

    private let lock = NSLock()
    private var connection: SenderConnection?
    private var source: MediaSource?
    private var encoder: H264Encoder?
    private var aac: AACEncoder?
    private var gate = SendGate(maxPendingBytes: 1_000_000)
    private var adaptive = AdaptiveBitrate(initial: 4_000_000, maximum: 4_000_000)
    private var paused = false
    private var stopping = false
    private var forceKeyframe = true
    private var lastConfig: Data?
    private var baseTime: CMTime?
    private var lastFrame: (buffer: CVPixelBuffer, wallClock: Double)?
    private var framesSent = 0
    private var bytesSent = 0
    private var dropped = 0
    private var rttMs: Double?
    private var statsWindowStart = Date()
    private var framesAtWindowStart = 0
    private var bytesAtWindowStart = 0
    private var timers: [DispatchSourceTimer] = []
    private let pipelineQueue = DispatchQueue(label: "austialcast.pipeline", qos: .userInteractive)
    private var fps = 30
    private var outSize = (width: 0, height: 0)
    private var receiverName = ""

    public init(identity: DeviceIdentity, tokens: TokenStore, appVersion: String = "1.0.0",
                transportFactory: @escaping TransportFactory = CastSession.defaultTransport) {
        self.identity = identity
        self.tokens = tokens
        self.appVersion = appVersion
        self.transportFactory = transportFactory
    }

    public static let defaultTransport: TransportFactory = { target in
        switch target {
        case .host(let h, let p): return try await NWTransport.connect(host: h, port: p)
        case .endpoint(let e): return try await NWTransport.connect(endpoint: e)
        }
    }

    private func emit(_ s: CastState) { onState?(s) }

    /// Runs until the cast ends. Throws for failures before streaming starts (e.g. `SenderError.pinRequired`).
    public func run(_ request: CastRequest) async throws {
        emit(.connecting)
        let transport: ByteTransport
        do { transport = try await transportFactory(request.target) }
        catch { emit(.ended(String(describing: error))); throw error }
        let conn = SenderConnection(transport: transport, identity: identity, appVersion: appVersion)
        lock.lock(); connection = conn; lock.unlock()

        let challenge: Challenge
        do {
            challenge = try await conn.handshake()
            emit(.authenticating)
            try await authenticate(conn, challenge: challenge, pin: request.pin)
        } catch {
            conn.close()
            emit(.ended(String(describing: error)))
            throw error
        }

        // Source and sizing.
        let src: MediaSource
        do { src = try await makeSource(request, challenge: challenge) }
        catch { conn.sendBye(ByeReason.error); conn.close(); emit(.ended(String(describing: error))); throw error }

        let out = request.preset.outputSize(sourceWidth: src.pixelSize.width, sourceHeight: src.pixelSize.height,
                                            receiverMaxWidth: challenge.maxWidth, receiverMaxHeight: challenge.maxHeight)
        let rate = request.preset.effectiveFps(receiverMax: challenge.maxFps)
        let bitrate = request.preset.bitrate(forWidth: out.width, height: out.height)
        lock.lock()
        fps = rate; outSize = out; receiverName = challenge.name
        adaptive = AdaptiveBitrate(initial: bitrate, minimum: 800_000, maximum: bitrate)
        gate = SendGate(maxPendingBytes: max(500_000, bitrate / 8))   // ~1 s of video in the socket buffer
        lock.unlock()

        do {
            let enc = try H264Encoder(width: out.width, height: out.height, fps: rate, bitrate: bitrate) { [weak self] o in self?.handleEncoded(o) }
            lock.lock(); encoder = enc; lock.unlock()
        } catch {
            conn.sendBye(ByeReason.error); conn.close(); emit(.ended(String(describing: error))); throw CastError.encoder(error)
        }

        var audioInfo: AudioInfo?
        if request.captureAudio && src.providesAudio {
            let a = AACEncoder()
            lock.lock(); aac = a; lock.unlock()
            audioInfo = AudioInfo(sampleRate: a.sampleRate, channels: a.channels, config: a.configHex)
        }

        do {
            try conn.sendStreamStart(StreamStart(width: out.width, height: out.height, fps: rate, bitrate: bitrate, audio: audioInfo, title: src.title))
        } catch { conn.close(); emit(.ended(String(describing: error))); throw error }

        conn.startEventLoop()
        lock.lock(); source = src; statsWindowStart = Date(); lock.unlock()
        src.onVideo = { [weak self] pb, t in self?.pipelineQueue.async { self?.handleCaptured(pb, t) } }
        src.onAudio = { [weak self] pcm, t in self?.pipelineQueue.async { self?.handleAudio(pcm, t) } }
        src.onStopped = { [weak self] err in self?.sourceStopped(err) }
        do { try await src.start() }
        catch { teardown(sendBye: true); emit(.ended(String(describing: error))); throw error }

        emit(.streaming(receiver: challenge.name, width: out.width, height: out.height, fps: rate))
        startTimers(needsIdleRepeat: src.needsIdleRepeat)

        // Block until the receiver says bye, the connection drops, or stop() closes it.
        var endReason: String?
        loop: for await event in conn.events {
            switch event {
            case .control(let c): handleControl(c)
            case .stats(let s): handleReceiverStats(s)
            case .pong(let rtt): lock.lock(); rttMs = rtt; lock.unlock()
            case .bye(let b): endReason = b.reason == ByeReason.user ? "The TV stopped the cast" : (b.message ?? b.reason); break loop
            case .closed: break loop
            }
        }
        let wasStopping: Bool
        lock.lock(); wasStopping = stopping; lock.unlock()
        teardown(sendBye: false)
        await src.stop()
        emit(.ended(wasStopping ? nil : (endReason ?? "Connection to the TV was lost")))
    }

    // MARK: control

    public func stop() {
        lock.lock(); stopping = true; let conn = connection; lock.unlock()
        conn?.sendBye(ByeReason.user)
        conn?.close()
    }

    public func setPaused(_ value: Bool) {
        lock.lock()
        guard paused != value, let conn = connection else { lock.unlock(); return }
        paused = value
        if !value { forceKeyframe = true }
        lock.unlock()
        try? conn.sendControl(Control(cmd: value ? ControlCommand.pause : ControlCommand.resume))
        emit(value ? .paused : .streaming(receiver: receiverName, width: outSize.width, height: outSize.height, fps: fps))
    }

    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }

    private func authenticate(_ conn: SenderConnection, challenge: Challenge, pin: String?) async throws {
        if challenge.trusted, let token = tokens.token(for: challenge.deviceId) {
            do { try await conn.authenticate(token: token); return }
            catch SenderError.badToken { tokens.remove(receiverId: challenge.deviceId) }
        }
        guard let pin, !pin.isEmpty else { throw SenderError.pinRequired(receiverName: challenge.name) }
        if let token = try await conn.authenticate(pin: pin) {
            tokens.save(token: token, receiverId: challenge.deviceId, name: challenge.name)
        }
    }

    private func makeSource(_ r: CastRequest, challenge: Challenge) async throws -> MediaSource {
        switch r.source {
        case .testPattern(let w, let h):
            return TestPatternSource(width: w, height: h, fps: r.preset.effectiveFps(receiverMax: challenge.maxFps), audio: r.captureAudio)
        case .display(let id):
            return try await screenSource(.display(id), r, challenge)
        case .window(let id):
            return try await screenSource(.window(id), r, challenge)
        }
    }

    private func screenSource(_ target: CaptureTarget, _ r: CastRequest, _ c: Challenge) async throws -> MediaSource {
        let native = try await ScreenCaptureSource.nativeSize(of: target)
        let out = r.preset.outputSize(sourceWidth: native.width, sourceHeight: native.height, receiverMaxWidth: c.maxWidth, receiverMaxHeight: c.maxHeight)
        let src = ScreenCaptureSource(target: target, outputSize: out, fps: r.preset.effectiveFps(receiverMax: c.maxFps),
                                      showsCursor: r.showCursor, captureAudio: r.captureAudio)
        src.setNativeSizeHint(native)
        return src
    }

    private func sourceStopped(_ error: Error?) {
        lock.lock(); let already = stopping; lock.unlock()
        if !already, error != nil { stop() }
    }

    // MARK: pipeline

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func relativeUs(_ t: CMTime) -> Int64 {
        lock.lock()
        if baseTime == nil { baseTime = t }
        let base = baseTime!
        lock.unlock()
        return Int64((CMTimeGetSeconds(CMTimeSubtract(t, base)) * 1_000_000).rounded())
    }

    private func handleCaptured(_ pb: CVPixelBuffer, _ t: CMTime) {
        lock.lock()
        lastFrame = (pb, now())
        let isPaused = paused
        let enc = encoder
        let force = forceKeyframe
        if force { forceKeyframe = false }
        lock.unlock()
        guard !isPaused, let enc else { return }
        let pts = CMTime(value: relativeUs(t), timescale: 1_000_000)
        do { try enc.encode(pb, pts: pts, forceKeyframe: force) } catch { /* transient encoder errors drop the frame */ }
    }

    private func handleAudio(_ pcm: AVAudioPCMBuffer, _ t: CMTime) {
        lock.lock()
        let a = aac, conn = connection, isPaused = paused
        lock.unlock()
        guard let a, let conn, !isPaused else { return }
        let us = relativeUs(t)
        for p in a.encode(pcm, ptsUs: us) { try? conn.sendAudio(ptsUs: p.ptsUs, data: p.data) }
    }

    private func handleEncoded(_ o: H264Encoder.Output) {
        lock.lock()
        guard let conn = connection, !stopping else { lock.unlock(); return }
        let pending = conn.pendingBytes
        let decision = gate.decide(isKeyframe: o.keyframe, pendingBytes: pending)
        var newBitrate: Int?
        if decision.congested { newBitrate = adaptive.onCongestion(now: now()); dropped += 1 }
        else if !decision.send { dropped += 1 }
        if decision.requestKeyframe { forceKeyframe = true }
        let send = decision.send
        let configChanged = o.config != nil && o.config != lastConfig
        if o.config != nil { lastConfig = o.config }
        let enc = encoder
        lock.unlock()

        if let nb = newBitrate { enc?.setBitrate(nb) }
        guard send else { return }
        do {
            // Repeat the config on every keyframe so a receiver that (re)starts mid-stream can decode.
            if let cfg = o.config { try conn.sendVideoConfig(cfg) } else if configChanged {}
            try conn.sendVideo(keyframe: o.keyframe, ptsUs: o.ptsUs, data: o.data)
            lock.lock(); framesSent += 1; bytesSent += o.data.count; lock.unlock()
        } catch {
            // Broken pipe: the event loop notices and ends the session.
        }
    }

    private func handleControl(_ c: Control) {
        switch c.cmd {
        case ControlCommand.requestKeyframe:
            lock.lock(); forceKeyframe = true; lock.unlock()
        case ControlCommand.setBitrate:
            if let b = c.bitrate {
                lock.lock(); let nb = adaptive.request(b, now: now()); let enc = encoder; lock.unlock()
                enc?.setBitrate(nb)
            }
        case ControlCommand.stop:
            stop()
        default:
            break
        }
    }

    private func handleReceiverStats(_ s: StatsReport) {
        // The TV decodes much less than we send: treat as congestion to let it recover.
        lock.lock()
        let target = Double(fps)
        let congested = s.fps > 0 && s.fps < target * 0.6 && framesSent > fps * 3
        var nb: Int?
        if congested { nb = adaptive.onCongestion(now: now()) }
        let enc = encoder
        lock.unlock()
        if let nb { enc?.setBitrate(nb) }
    }

    private func startTimers(needsIdleRepeat: Bool) {
        func makeTimer(_ interval: DispatchTimeInterval, _ block: @escaping () -> Void) {
            let t = DispatchSource.makeTimerSource(queue: pipelineQueue)
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler(handler: block)
            t.resume()
            timers.append(t)
        }
        makeTimer(.seconds(1)) { [weak self] in self?.tickSecond() }
        makeTimer(.seconds(2)) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let c = self.connection; self.lock.unlock()
            try? c?.sendPing()
        }
        if needsIdleRepeat {
            // ScreenCaptureKit only delivers frames when pixels change; resend the last one so the TV
            // keeps getting data, can start decoding late, and the connection stays alive.
            makeTimer(.milliseconds(250)) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let last = self.lastFrame, isPaused = self.paused, enc = self.encoder
                self.lock.unlock()
                guard let last, !isPaused, let enc, self.now() - last.wallClock >= 0.25 else { return }
                let pts = CMTime(value: self.relativeUs(hostTime()), timescale: 1_000_000)
                try? enc.encode(last.buffer, pts: pts, forceKeyframe: false)
            }
        }
    }

    private func tickSecond() {
        lock.lock()
        let elapsed = max(0.001, Date().timeIntervalSince(statsWindowStart))
        let frames = framesSent - framesAtWindowStart
        let bytes = bytesSent - bytesAtWindowStart
        statsWindowStart = Date(); framesAtWindowStart = framesSent; bytesAtWindowStart = bytesSent
        var nb: Int?
        if !gate.isDropping { nb = adaptive.onTick(now: now()) }
        let stats = CastStats(fps: Double(frames) / elapsed, bitrateKbps: Double(bytes) * 8 / 1000 / elapsed,
                              targetBitrateKbps: Double(adaptive.current) / 1000, rttMs: rttMs, droppedFrames: dropped,
                              width: outSize.width, height: outSize.height)
        let enc = encoder
        lock.unlock()
        if let nb { enc?.setBitrate(nb) }
        onStats?(stats)
    }

    private func teardown(sendBye: Bool) {
        lock.lock()
        timers.forEach { $0.cancel() }
        timers.removeAll()
        let conn = connection, enc = encoder
        connection = nil; encoder = nil; aac = nil; source = nil; lastFrame = nil; baseTime = nil
        lock.unlock()
        if sendBye { conn?.sendBye(ByeReason.user) }
        enc?.invalidate()
        conn?.close()
    }
}

extension ScreenCaptureSource {
    func setNativeSizeHint(_ native: (width: Int, height: Int, title: String)) {
        // pixelSize is normally filled on start(); the session needs it earlier to compute the output size.
        self.preset(native.width, native.height, native.title)
    }
}
