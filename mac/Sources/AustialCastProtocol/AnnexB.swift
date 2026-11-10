import Foundation

/// H.264 helpers: converting VideoToolbox's length-prefixed (AVCC) output to Annex-B and parsing NAL units.
public enum AnnexB {
    public static let startCode = Data([0, 0, 0, 1])

    /// Converts AVCC (`nalLengthSize` byte big-endian lengths) to Annex-B. Returns nil if malformed.
    public static func fromAVCC(_ data: Data, nalLengthSize: Int = 4) -> Data? {
        guard (1...4).contains(nalLengthSize) else { return nil }
        var out = Data(capacity: data.count + 16)
        var i = data.startIndex
        while i < data.endIndex {
            guard i + nalLengthSize <= data.endIndex else { return nil }
            var len = 0
            for k in 0..<nalLengthSize { len = (len << 8) | Int(data[i + k]) }
            i += nalLengthSize
            guard len > 0, i + len <= data.endIndex else { return nil }
            out.append(startCode)
            out.append(data[i..<(i + len)])
            i += len
        }
        return out
    }

    public static func buildConfig(sps: Data, pps: Data) -> Data {
        startCode + sps + startCode + pps
    }

    public static func splitNalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 4 <= bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        var units: [Data] = []
        for (k, s) in starts.enumerated() {
            let begin = s.0 + s.1
            var end = k + 1 < starts.count ? starts[k + 1].0 : bytes.count
            while end > begin, bytes[end - 1] == 0 { end -= 1 }
            if end > begin { units.append(Data(bytes[begin..<end])) }
        }
        return units
    }

    public static func nalType(_ nal: Data) -> Int { nal.isEmpty ? -1 : Int(nal[nal.startIndex] & 0x1f) }

    public static func containsIDR(_ accessUnit: Data) -> Bool {
        splitNalUnits(accessUnit).contains { nalType($0) == 5 }
    }
}

/// Builds the 2 byte AAC AudioSpecificConfig (object type 2 = AAC-LC) as hex.
public enum AACConfig {
    private static let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    public static func audioSpecificConfigHex(sampleRate: Int, channels: Int) -> String? {
        guard let idx = rates.firstIndex(of: sampleRate), (1...7).contains(channels) else { return nil }
        let value = (2 << 11) | (idx << 7) | (channels << 3)
        return String(format: "%04x", value)
    }
}
