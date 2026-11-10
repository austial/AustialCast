import Foundation

public struct QualityPreset: Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var maxWidth: Int
    public var maxHeight: Int
    public var fps: Int
    public var bitrate: Int

    public init(id: String, name: String, maxWidth: Int, maxHeight: Int, fps: Int, bitrate: Int) {
        self.id = id; self.name = name; self.maxWidth = maxWidth; self.maxHeight = maxHeight
        self.fps = fps; self.bitrate = bitrate
    }

    public static let hd720p30 = QualityPreset(id: "720p30", name: "720p · 30 fps (Wi-Fi friendly)", maxWidth: 1280, maxHeight: 720, fps: 30, bitrate: 3_500_000)
    public static let fullHD30 = QualityPreset(id: "1080p30", name: "1080p · 30 fps", maxWidth: 1920, maxHeight: 1080, fps: 30, bitrate: 7_000_000)
    public static let fullHD60 = QualityPreset(id: "1080p60", name: "1080p · 60 fps (smooth)", maxWidth: 1920, maxHeight: 1080, fps: 60, bitrate: 12_000_000)
    public static let uhd30 = QualityPreset(id: "2160p30", name: "4K · 30 fps (needs fast network)", maxWidth: 3840, maxHeight: 2160, fps: 30, bitrate: 22_000_000)
    public static let all: [QualityPreset] = [.hd720p30, .fullHD30, .fullHD60, .uhd30]
    public static func byId(_ id: String) -> QualityPreset? { all.first { $0.id == id } }

    /// Output size that fits inside both the preset and the receiver's limits, keeps the source aspect
    /// ratio, never upscales and is even (H.264 requires even dimensions).
    public func outputSize(sourceWidth: Int, sourceHeight: Int, receiverMaxWidth: Int, receiverMaxHeight: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (maxWidth & ~1, maxHeight & ~1) }
        let boxW = max(2, min(maxWidth, receiverMaxWidth))
        let boxH = max(2, min(maxHeight, receiverMaxHeight))
        let scale = min(1.0, min(Double(boxW) / Double(sourceWidth), Double(boxH) / Double(sourceHeight)))
        let w = max(2, Int((Double(sourceWidth) * scale).rounded()) & ~1)
        let h = max(2, Int((Double(sourceHeight) * scale).rounded()) & ~1)
        return (w, h)
    }

    public func effectiveFps(receiverMax: Int) -> Int { max(1, min(fps, receiverMax)) }

    /// Bitrate scaled to the actual pixel count relative to the preset's full frame.
    public func bitrate(forWidth w: Int, height h: Int) -> Int {
        let full = Double(maxWidth * maxHeight)
        let ratio = min(1.0, Double(w * h) / full)
        return max(800_000, Int(Double(bitrate) * max(0.35, ratio)))
    }
}

/// Reduces the bitrate quickly when the network is congested and recovers slowly afterwards.
public struct AdaptiveBitrate: Equatable {
    public let minimum: Int
    public let maximum: Int
    public private(set) var current: Int
    private var lastCongestion: Double = -1000
    private var lastChange: Double = -1000
    public var cooldown: Double = 2.0
    public var recoveryInterval: Double = 8.0

    public init(initial: Int, minimum: Int = 800_000, maximum: Int) {
        self.minimum = min(minimum, maximum)
        self.maximum = maximum
        self.current = max(self.minimum, min(initial, maximum))
    }

    /// Returns the new bitrate if it changed.
    public mutating func onCongestion(now: Double) -> Int? {
        lastCongestion = now
        guard now - lastChange >= cooldown else { return nil }
        let next = max(minimum, Int(Double(current) * 0.7))
        guard next != current else { return nil }
        current = next
        lastChange = now
        return next
    }

    public mutating func onTick(now: Double) -> Int? {
        guard current < maximum, now - lastCongestion >= recoveryInterval, now - lastChange >= recoveryInterval else { return nil }
        let next = min(maximum, Int(Double(current) * 1.12))
        guard next != current else { return nil }
        current = next
        lastChange = now
        return next
    }

    /// The receiver explicitly asked for a bitrate.
    public mutating func request(_ bitrate: Int, now: Double) -> Int {
        current = max(minimum, min(bitrate, maximum))
        lastChange = now
        lastCongestion = now
        return current
    }
}

/// Decides per encoded frame whether the network can take it. When the TCP send buffer backs up,
/// frames are dropped until the next keyframe so the receiver never decodes a broken reference chain.
public struct SendGate {
    public struct Decision: Equatable {
        public var send: Bool
        public var requestKeyframe: Bool
        public var congested: Bool
    }

    public let maxPendingBytes: Int
    private var waitingForKeyframe = false
    private var keyframeRequested = false

    public init(maxPendingBytes: Int) { self.maxPendingBytes = maxPendingBytes }

    public var isDropping: Bool { waitingForKeyframe }

    public mutating func decide(isKeyframe: Bool, pendingBytes: Int) -> Decision {
        if waitingForKeyframe {
            if isKeyframe && pendingBytes < maxPendingBytes / 2 {
                waitingForKeyframe = false
                keyframeRequested = false
                return Decision(send: true, requestKeyframe: false, congested: false)
            }
            let ask = !keyframeRequested && pendingBytes < maxPendingBytes / 2
            if ask { keyframeRequested = true }
            return Decision(send: false, requestKeyframe: ask, congested: false)
        }
        if pendingBytes > maxPendingBytes {
            waitingForKeyframe = true
            keyframeRequested = false
            return Decision(send: false, requestKeyframe: false, congested: true)
        }
        return Decision(send: true, requestKeyframe: false, congested: false)
    }

    /// A keyframe the encoder produced on its own (periodic) also ends a drop phase.
    public mutating func reset() {
        waitingForKeyframe = false
        keyframeRequested = false
    }
}
