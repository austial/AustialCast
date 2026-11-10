import CoreMedia
import Foundation
import AustialCastProtocol
import VideoToolbox

public enum EncoderError: Error, CustomStringConvertible {
    case createFailed(OSStatus)
    case encodeFailed(OSStatus)
    public var description: String {
        switch self {
        case .createFailed(let s): return "Could not create the H.264 encoder (\(s))"
        case .encodeFailed(let s): return "H.264 encoding failed (\(s))"
        }
    }
}

/// Low-latency hardware H.264 encoder producing Annex-B access units.
public final class H264Encoder: @unchecked Sendable {
    public struct Output {
        public var keyframe: Bool
        public var ptsUs: Int64
        /// Annex-B access unit (start-code delimited NAL units, no SPS/PPS).
        public var data: Data
        /// SPS+PPS in Annex-B, present on keyframes.
        public var config: Data?
    }

    public typealias Handler = @Sendable (Output) -> Void

    private var session: VTCompressionSession?
    private let handler: Handler
    public let width: Int
    public let height: Int
    public private(set) var fps: Int

    public init(width: Int, height: Int, fps: Int, bitrate: Int, keyframeIntervalSeconds: Int = 2, handler: @escaping Handler) throws {
        self.width = width
        self.height = height
        self.fps = fps
        self.handler = handler

        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s
        )
        guard status == noErr, let s else { throw EncoderError.createFailed(status) }
        session = s

        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(s, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyframeIntervalSeconds as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * keyframeIntervalSeconds) as CFNumber)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        applyBitrate(bitrate)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    private func applyBitrate(_ bps: Int) {
        guard let s = session else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        // Cap bursts at 1.5x the average over one second (bytes, seconds).
        let limits = [Int(Double(bps) * 1.5 / 8.0), 1] as CFArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    public func setBitrate(_ bps: Int) { applyBitrate(bps) }

    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool = false) throws {
        guard let s = session else { return }
        let props: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
        let handler = self.handler
        let status = VTCompressionSessionEncodeFrame(
            s, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: CMTimeScale(max(1, fps))), frameProperties: props, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sb = sampleBuffer, let out = H264Encoder.convert(sb) else { return }
            handler(out)
        }
        if status != noErr { throw EncoderError.encodeFailed(status) }
    }

    public func flush() {
        guard let s = session else { return }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
    }

    public func invalidate() {
        guard let s = session else { return }
        session = nil
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(s)
    }

    deinit { invalidate() }

    static func convert(_ sb: CMSampleBuffer) -> Output? {
        guard CMSampleBufferDataIsReady(sb), let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == noErr else { return nil }

        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }

        var nalLen: Int32 = 4
        var config: Data?
        if keyframe, let fd = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen)
            var sps: Data?, pps: Data?
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    let nal = Data(bytes: ptr, count: size)
                    switch AnnexB.nalType(nal) {
                    case 7: sps = nal
                    case 8: pps = nal
                    default: break
                    }
                }
            }
            if let sps, let pps { config = AnnexB.buildConfig(sps: sps, pps: pps) }
        }
        guard let annexB = AnnexB.fromAVCC(avcc, nalLengthSize: Int(nalLen)) else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let us = Int64((CMTimeGetSeconds(pts) * 1_000_000).rounded())
        return Output(keyframe: keyframe, ptsUs: us, data: annexB, config: config)
    }
}
