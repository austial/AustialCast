import AVFoundation
import Foundation
import AustialCastProtocol

/// Encodes PCM into raw AAC-LC access units (no ADTS), 1024 samples per packet.
public final class AACEncoder: @unchecked Sendable {
    public struct Packet { public var ptsUs: Int64; public var data: Data }

    public let sampleRate: Int
    public let channels: Int
    public var configHex: String { AACConfig.audioSpecificConfigHex(sampleRate: sampleRate, channels: channels) ?? "1190" }

    private let outFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var queue: [AVAudioPCMBuffer] = []
    private var baseUs: Int64?
    private var packetsEmitted: Int64 = 0
    private let lock = NSLock()

    public init(sampleRate: Int = 48000, channels: Int = 2, bitrate: Int = 128_000) {
        self.sampleRate = sampleRate
        self.channels = channels
        var desc = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0
        )
        outFormat = AVAudioFormat(streamDescription: &desc)!
        self.bitrate = bitrate
    }

    private let bitrate: Int

    /// Feeds PCM and returns any complete AAC packets.
    public func encode(_ pcm: AVAudioPCMBuffer, ptsUs: Int64) -> [Packet] {
        lock.lock(); defer { lock.unlock() }
        if converter == nil || inputFormat != pcm.format {
            guard let c = AVAudioConverter(from: pcm.format, to: outFormat) else { return [] }
            c.bitRate = bitrate
            converter = c
            inputFormat = pcm.format
        }
        if baseUs == nil { baseUs = ptsUs }
        queue.append(pcm)
        guard let converter else { return [] }

        var packets: [Packet] = []
        while true {
            let out = AVAudioCompressedBuffer(format: outFormat, packetCapacity: 8, maximumPacketSize: max(converter.maximumOutputPacketSize, 1024))
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { [self] _, outStatus in
                if queue.isEmpty {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return queue.removeFirst()
            }
            if status == .error || error != nil { break }
            let count = Int(out.packetCount)
            if count == 0 { break }
            guard let descs = out.packetDescriptions else { break }
            for i in 0..<count {
                let d = descs[i]
                let start = Int(d.mStartOffset)
                let size = Int(d.mDataByteSize)
                guard size > 0 else { continue }
                let data = Data(bytes: out.data.advanced(by: start), count: size)
                let pts = (baseUs ?? ptsUs) + packetsEmitted * 1024 * 1_000_000 / Int64(sampleRate)
                packetsEmitted += 1
                packets.append(Packet(ptsUs: pts, data: data))
            }
            if status == .endOfStream || status == .inputRanDry { break }
        }
        return packets
    }
}
