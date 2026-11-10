import AVFoundation
import CoreMedia
import VideoToolbox
import XCTest
import AustialCastProtocol
@testable import AustialCastCore

/// Decodes Annex-B H.264 with VideoToolbox so tests can verify the encoder output is truly valid video.
final class TestH264Decoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private(set) var decoded: [CVPixelBuffer] = []

    func setConfig(_ annexB: Data) throws {
        let nals = AnnexB.splitNalUnits(annexB)
        guard let sps = nals.first(where: { AnnexB.nalType($0) == 7 }), let pps = nals.first(where: { AnnexB.nalType($0) == 8 }) else {
            throw NSError(domain: "test", code: 1)
        }
        var fd: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                var ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: &ptrs,
                                                                           parameterSetSizes: &sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        guard status == noErr, let fd else { throw NSError(domain: "test", code: 2) }
        format = fd
        var s: VTDecompressionSession?
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                           imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s) == noErr else {
            throw NSError(domain: "test", code: 3)
        }
        session = s
    }

    func decode(annexB: Data, ptsUs: Int64) throws {
        guard let session, let format else { throw NSError(domain: "test", code: 4) }
        var avcc = Data()
        for nal in AnnexB.splitNalUnits(annexB) {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        var block: CMBlockBuffer?
        let size = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block) == noErr, let block else { throw NSError(domain: "test", code: 5) }
        _ = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sampleSize = size
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr, let sample else {
            throw NSError(domain: "test", code: 6)
        }
        var failure: OSStatus = noErr
        let lock = NSLock()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { st, _, image, _, _ in
            lock.lock(); defer { lock.unlock() }
            if st == noErr, let image { self.decoded.append(image) } else { failure = st }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if status != noErr || failure != noErr { throw NSError(domain: "test", code: Int(status != noErr ? status : failure)) }
    }

    /// Reads the 16 bit counter drawn by TestPatternSource.
    static func readCounter(_ pb: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        var value = 0
        for bit in 0..<16 {
            let x = bit * 24 + 12, y = 12
            let blue = Int(base[y * bpr + x * 4])
            value = (value << 1) | (blue > 128 ? 1 : 0)
        }
        return value
    }
}

final class MediaTests: XCTestCase {
    private func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        return pb!
    }

    func testEncoderOutputDecodesToTheSameFrames() throws {
        let outputs = Locked<[H264Encoder.Output]>([])
        let enc = try H264Encoder(width: 640, height: 360, fps: 30, bitrate: 4_000_000) { o in outputs.mutate { $0.append(o) } }
        let total = 45
        for i in 0..<total {
            let pb = makeBuffer(640, 360)
            TestPatternSource.draw(into: pb, frame: i)
            try enc.encode(pb, pts: CMTime(value: Int64(i) * 33_333, timescale: 1_000_000), forceKeyframe: i == 0)
        }
        enc.flush()
        enc.invalidate()
        let out = outputs.value
        XCTAssertEqual(out.count, total, "low-latency encoder emits one access unit per frame")
        XCTAssertTrue(out[0].keyframe)
        let config = try XCTUnwrap(out[0].config, "keyframes carry SPS+PPS")
        XCTAssertEqual(AnnexB.splitNalUnits(config).map(AnnexB.nalType), [7, 8])
        XCTAssertTrue(AnnexB.containsIDR(out[0].data))
        for o in out { XCTAssertEqual(o.keyframe, AnnexB.containsIDR(o.data), "keyframe flag must match the bitstream") }
        XCTAssertEqual(out.map(\.ptsUs), out.map(\.ptsUs).sorted(), "no frame reordering")
        XCTAssertTrue(out.dropFirst().contains { !$0.keyframe }, "inter frames are produced")

        let dec = TestH264Decoder()
        try dec.setConfig(config)
        for o in out { try dec.decode(annexB: o.data, ptsUs: o.ptsUs) }
        XCTAssertEqual(dec.decoded.count, total)
        for (i, pb) in dec.decoded.enumerated() {
            XCTAssertEqual(CVPixelBufferGetWidth(pb), 640)
            XCTAssertEqual(TestH264Decoder.readCounter(pb), i, "decoded frame \(i) shows the wrong counter")
        }
    }

    func testForcedKeyframeAndBitrateChange() throws {
        let outputs = Locked<[H264Encoder.Output]>([])
        let enc = try H264Encoder(width: 320, height: 180, fps: 30, bitrate: 2_000_000) { o in outputs.mutate { $0.append(o) } }
        for i in 0..<20 {
            let pb = makeBuffer(320, 180)
            TestPatternSource.draw(into: pb, frame: i)
            if i == 10 { enc.setBitrate(500_000) }
            try enc.encode(pb, pts: CMTime(value: Int64(i) * 33_333, timescale: 1_000_000), forceKeyframe: i == 0 || i == 12)
        }
        enc.flush(); enc.invalidate()
        let keys = outputs.value.enumerated().filter { $0.element.keyframe }.map(\.offset)
        XCTAssertEqual(keys, [0, 12], "keyframes only where forced (interval is 2 s)")
    }

    func testEncoderRejectsInvalidDimensions() {
        XCTAssertThrowsError(try H264Encoder(width: 0, height: 0, fps: 30, bitrate: 1_000_000) { _ in })
    }

    func testAACEncoderProducesPacketsAtTheRightRate() {
        let enc = AACEncoder(sampleRate: 48000, channels: 2, bitrate: 128_000)
        XCTAssertEqual(enc.configHex, "1190")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        var packets: [AACEncoder.Packet] = []
        var phase = 0.0
        for chunk in 0..<100 { // 100 * 480 frames = 1 second
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buf.frameLength = 480
            for i in 0..<480 {
                let s = Float(sin(phase)) * 0.5
                phase += 2 * .pi * 440 / 48000
                buf.floatChannelData![0][i] = s; buf.floatChannelData![1][i] = s
            }
            packets += enc.encode(buf, ptsUs: Int64(chunk) * 10_000)
        }
        XCTAssertTrue((43...48).contains(packets.count), "1 s of audio is ~46.9 AAC packets, got \(packets.count)")
        XCTAssertTrue(packets.allSatisfy { $0.data.count > 0 && $0.data.count < 2000 }, "sizes: \(packets.map(\.data.count))")
        for (a, b) in zip(packets, packets.dropFirst()) {
            XCTAssertEqual(Double(b.ptsUs - a.ptsUs), 21_333, accuracy: 2, "1024 samples @ 48 kHz")
        }
    }

    func testAACEncoderHandlesFormatChangeMidStream() {
        let enc = AACEncoder()
        for rate in [48000.0, 44100.0] {
            let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
            let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 4800)!
            buf.frameLength = 4800
            _ = enc.encode(buf, ptsUs: 0) // must not crash
        }
    }

    func testTestPatternSourceDeliversVideoAndAudio() async throws {
        let src = TestPatternSource(width: 320, height: 180, fps: 30, audio: true)
        let video = Locked(0), audio = Locked(0)
        src.onVideo = { pb, _ in
            XCTAssertEqual(CVPixelBufferGetWidth(pb), 320)
            video.mutate { $0 += 1 }
        }
        src.onAudio = { pcm, _ in
            XCTAssertEqual(pcm.frameLength, 960)
            audio.mutate { $0 += 1 }
        }
        try await src.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        await src.stop()
        XCTAssertGreaterThan(video.value, 12)
        XCTAssertGreaterThan(audio.value, 20)
    }

    func testFrameCounterIsReadableFromPattern() {
        for n in [0, 1, 255, 256, 4660, 65535] {
            let pb = makeBuffer(640, 360)
            TestPatternSource.draw(into: pb, frame: n)
            XCTAssertEqual(TestH264Decoder.readCounter(pb), n)
        }
    }
}

final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}
