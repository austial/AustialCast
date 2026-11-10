import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// Synthetic source: animated colour bars, a moving box, a 16 bit frame counter drawn as blocks and a
/// 440 Hz tone. Needs no permissions, so it powers headless tests, CI and `austialcast send --test-pattern`.
public final class TestPatternSource: MediaSource, @unchecked Sendable {
    public let pixelSize: (width: Int, height: Int)
    public let title = "Test pattern"
    public let providesAudio: Bool
    public let needsIdleRepeat = false
    public var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
    public var onAudio: ((AVAudioPCMBuffer, CMTime) -> Void)?
    public var onStopped: ((Error?) -> Void)?

    private let fps: Int
    private let queue = DispatchQueue(label: "austialcast.testpattern")
    private var videoTimer: DispatchSourceTimer?
    private var audioTimer: DispatchSourceTimer?
    private var frameIndex = 0
    private var audioPhase = 0.0
    private var pool: CVPixelBufferPool?

    public init(width: Int = 1280, height: Int = 720, fps: Int = 30, audio: Bool = true) {
        pixelSize = (width, height)
        self.fps = fps
        providesAudio = audio
    }

    public func start() async throws {
        var attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: pixelSize.width, kCVPixelBufferHeightKey: pixelSize.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        attrs[kCVPixelBufferCGBitmapContextCompatibilityKey] = true
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)

        let v = DispatchSource.makeTimerSource(queue: queue)
        v.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps))
        v.setEventHandler { [weak self] in self?.emitVideo() }
        v.resume()
        videoTimer = v

        if providesAudio {
            let a = DispatchSource.makeTimerSource(queue: queue)
            a.schedule(deadline: .now(), repeating: .milliseconds(20))
            a.setEventHandler { [weak self] in self?.emitAudio() }
            a.resume()
            audioTimer = a
        }
    }

    public func stop() async {
        videoTimer?.cancel(); audioTimer?.cancel()
        videoTimer = nil; audioTimer = nil
        onStopped?(nil)
    }

    private func emitVideo() {
        guard let pool else { return }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buffer = pb else { return }
        TestPatternSource.draw(into: buffer, frame: frameIndex)
        frameIndex += 1
        onVideo?(buffer, hostTime())
    }

    private func emitAudio() {
        let frames: AVAudioFrameCount = 960
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        let step = 2 * Double.pi * 440.0 / 48000.0
        for i in 0..<Int(frames) {
            let s = Float(sin(audioPhase)) * 0.2
            audioPhase += step
            buf.floatChannelData![0][i] = s
            buf.floatChannelData![1][i] = s
        }
        onAudio?(buf, hostTime())
    }

    /// Draws one frame. Exposed for tests: the 16 bit counter lets a viewer (or test) identify frames.
    public static func draw(into buffer: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0), (1, 0, 1), (1, 0, 0), (0, 0, 1), (0.1, 0.1, 0.1)]
        let barW = CGFloat(w) / CGFloat(bars.count)
        let shift = frame / 4
        for (i, c) in bars.enumerated() {
            let k = (i + shift) % bars.count
            ctx.setFillColor(red: bars[k].0 * 0.8, green: bars[k].1 * 0.8, blue: bars[k].2 * 0.8, alpha: 1)
            _ = c
            ctx.fill(CGRect(x: CGFloat(i) * barW, y: 0, width: barW + 1, height: CGFloat(h)))
        }
        // Moving box.
        let boxSize = CGFloat(h) / 5
        let t = Double(frame % 120) / 120.0
        let x = (CGFloat(w) - boxSize) * CGFloat(0.5 + 0.5 * sin(t * 2 * .pi))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: x, y: CGFloat(h) / 2 - boxSize / 2, width: boxSize, height: boxSize))
        // 16 bit frame counter as 24px blocks (MSB left) in the top-left corner.
        let block: CGFloat = 24
        for bit in 0..<16 {
            let on = (frame >> (15 - bit)) & 1 == 1
            ctx.setFillColor(gray: on ? 1 : 0, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(bit) * block, y: CGFloat(h) - block, width: block, height: block))
        }
    }
}
