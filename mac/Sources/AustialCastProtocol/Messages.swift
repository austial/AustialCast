import Foundation

public struct Hello: Codable, Equatable {
    public var `protocol`: Int = Int(protocolVersion)
    public var deviceId: String
    public var name: String
    public var platform: String
    public var appVersion: String
    public var publicKey: String
    public init(deviceId: String, name: String, platform: String = "macos", appVersion: String, publicKey: String) {
        self.deviceId = deviceId; self.name = name; self.platform = platform
        self.appVersion = appVersion; self.publicKey = publicKey
    }
}

public struct Challenge: Codable, Equatable {
    public var `protocol`: Int
    public var deviceId: String
    public var name: String
    public var publicKey: String
    public var trusted: Bool
    public var maxWidth: Int
    public var maxHeight: Int
    public var maxFps: Int
    public init(deviceId: String, name: String, publicKey: String, trusted: Bool, maxWidth: Int, maxHeight: Int, maxFps: Int) {
        self.protocol = Int(protocolVersion)
        self.deviceId = deviceId; self.name = name; self.publicKey = publicKey; self.trusted = trusted
        self.maxWidth = maxWidth; self.maxHeight = maxHeight; self.maxFps = maxFps
    }
}

public struct Auth: Codable, Equatable {
    public var mode: String
    public var proof: String
    public init(mode: String, proof: String) { self.mode = mode; self.proof = proof }
}

public struct AuthResult: Codable, Equatable {
    public var ok: Bool
    public var proof: String?
    public var token: String?
    public var reason: String?
    public var message: String?
    public var retry: Bool?
    public init(ok: Bool, proof: String? = nil, token: String? = nil, reason: String? = nil, message: String? = nil, retry: Bool? = nil) {
        self.ok = ok; self.proof = proof; self.token = token; self.reason = reason; self.message = message; self.retry = retry
    }
}

public struct AudioInfo: Codable, Equatable {
    public var codec: String = "aac"
    public var sampleRate: Int
    public var channels: Int
    public var config: String
    public init(sampleRate: Int, channels: Int, config: String) {
        self.sampleRate = sampleRate; self.channels = channels; self.config = config
    }
}

public struct StreamStart: Codable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrate: Int
    public var codec: String = "h264"
    public var audio: AudioInfo?
    public var title: String?
    public init(width: Int, height: Int, fps: Int, bitrate: Int, audio: AudioInfo? = nil, title: String? = nil) {
        self.width = width; self.height = height; self.fps = fps; self.bitrate = bitrate
        self.audio = audio; self.title = title
    }
}

public struct Control: Codable, Equatable {
    public var cmd: String
    public var bitrate: Int?
    public var message: String?
    public init(cmd: String, bitrate: Int? = nil, message: String? = nil) {
        self.cmd = cmd; self.bitrate = bitrate; self.message = message
    }
}

public enum ControlCommand {
    public static let pause = "pause"
    public static let resume = "resume"
    public static let requestKeyframe = "requestKeyframe"
    public static let setBitrate = "setBitrate"
    public static let stop = "stop"
}

public struct StatsReport: Codable, Equatable {
    public var fps: Double
    public var decoded: Int64
    public var dropped: Int64
    public var bufferMs: Int?
    public init(fps: Double, decoded: Int64, dropped: Int64, bufferMs: Int? = nil) {
        self.fps = fps; self.decoded = decoded; self.dropped = dropped; self.bufferMs = bufferMs
    }
}

public struct Bye: Codable, Equatable {
    public var reason: String
    public var message: String?
    public init(reason: String, message: String? = nil) { self.reason = reason; self.message = message }
}

public enum AuthFailure {
    public static let badPin = "bad_pin"
    public static let badToken = "bad_token"
    public static let locked = "locked"
}

public enum ByeReason {
    public static let user = "user"
    public static let busy = "busy"
    public static let timeout = "timeout"
    public static let error = "error"
    public static let replaced = "replaced"
}

public enum Messages {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ProtocolError.malformed("\(T.self)") }
    }
}

/// VIDEO_FRAME payload: flags(1) | pts_us(8, BE) | Annex-B access unit.
public enum MediaPayload {
    public static func encodeVideo(keyframe: Bool, ptsUs: Int64, data: Data) -> Data {
        var out = Data(capacity: 9 + data.count)
        out.append(keyframe ? 1 : 0)
        out.append(bigEndian: UInt64(bitPattern: ptsUs))
        out.append(data)
        return out
    }

    public static func encodeAudio(ptsUs: Int64, data: Data) -> Data {
        var out = Data(capacity: 8 + data.count)
        out.append(bigEndian: UInt64(bitPattern: ptsUs))
        out.append(data)
        return out
    }
}

public extension Data {
    mutating func append(bigEndian value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { append(UInt8((value >> UInt64(shift)) & 0xff)) }
    }

    func bigEndianUInt64(at offset: Int = 0) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(self[startIndex + offset + i]) }
        return v
    }
}
