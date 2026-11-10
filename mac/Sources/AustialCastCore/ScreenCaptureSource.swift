import AppKit
import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

public struct CaptureDisplay: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let width: Int
    public let height: Int
}

public struct CaptureWindow: Identifiable, Hashable, Sendable {
    public let id: CGWindowID
    public let title: String
    public let appName: String
    public let width: Int
    public let height: Int
}

public enum CaptureTarget: Hashable, Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

public enum CaptureCatalog {
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    public static func displays() async throws -> [CaptureDisplay] {
        let content = try await shareable()
        return content.displays.enumerated().map { index, d in
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == d.displayID }
            let scale = Int(screen?.backingScaleFactor ?? 2)
            return CaptureDisplay(id: d.displayID, name: screen?.localizedName ?? "Display \(index + 1)", width: d.width * scale, height: d.height * scale)
        }
    }

    public static func windows() async throws -> [CaptureWindow] {
        let content = try await shareable()
        let me = Bundle.main.bundleIdentifier
        return content.windows.compactMap { w in
            guard w.isOnScreen, w.windowLayer == 0, w.frame.width >= 200, w.frame.height >= 150,
                  let app = w.owningApplication, app.bundleIdentifier != me else { return nil }
            let title = (w.title ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            return CaptureWindow(id: w.windowID, title: title, appName: app.applicationName, width: Int(w.frame.width), height: Int(w.frame.height))
        }.sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
    }

    fileprivate static func shareable() async throws -> SCShareableContent {
        do { return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw MediaSourceError.permissionDenied }
    }
}

/// Captures a display or window (plus system audio) with ScreenCaptureKit.
public final class ScreenCaptureSource: NSObject, MediaSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public private(set) var pixelSize: (width: Int, height: Int) = (0, 0)
    public private(set) var title = "Screen"
    public let providesAudio: Bool
    public let needsIdleRepeat = true
    public var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
    public var onAudio: ((AVAudioPCMBuffer, CMTime) -> Void)?
    public var onStopped: ((Error?) -> Void)?

    private let target: CaptureTarget
    private let outputSize: (width: Int, height: Int)
    private let fps: Int
    private let showsCursor: Bool
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "austialcast.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "austialcast.capture.audio")

    /// `outputSize` is the size delivered to the encoder (already fitted to the TV and preset).
    public init(target: CaptureTarget, outputSize: (width: Int, height: Int), fps: Int, showsCursor: Bool, captureAudio: Bool) {
        self.target = target
        self.outputSize = outputSize
        self.fps = fps
        self.showsCursor = showsCursor
        self.providesAudio = captureAudio
        super.init()
    }

    /// Resolves the native size of the target without starting capture.
    public static func nativeSize(of target: CaptureTarget) async throws -> (width: Int, height: Int, title: String) {
        let content = try await CaptureCatalog.shareable()
        switch target {
        case .display(let id):
            guard let d = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { throw MediaSourceError.noDisplay }
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == d.displayID }
            let scale = screen?.backingScaleFactor ?? 2
            return (Int(CGFloat(d.width) * scale), Int(CGFloat(d.height) * scale), screen?.localizedName ?? "Display")
        case .window(let id):
            guard let w = content.windows.first(where: { $0.windowID == id }) else { throw MediaSourceError.windowGone }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            return (Int(w.frame.width * scale), Int(w.frame.height * scale), w.title ?? w.owningApplication?.applicationName ?? "Window")
        }
    }

    func preset(_ w: Int, _ h: Int, _ title: String) {
        pixelSize = (w, h)
        self.title = title
    }

    public func start() async throws {
        let content = try await CaptureCatalog.shareable()
        let filter: SCContentFilter
        switch target {
        case .display(let id):
            guard let d = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { throw MediaSourceError.noDisplay }
            let selfApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: d, excludingApplications: selfApps, exceptingWindows: [])
        case .window(let id):
            guard let w = content.windows.first(where: { $0.windowID == id }) else { throw MediaSourceError.windowGone }
            filter = SCContentFilter(desktopIndependentWindow: w)
        }
        let native = try await Self.nativeSize(of: target)
        pixelSize = (native.width, native.height)
        title = native.title

        let cfg = SCStreamConfiguration()
        cfg.width = outputSize.width
        cfg.height = outputSize.height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.queueDepth = 5
        cfg.showsCursor = showsCursor
        cfg.scalesToFit = true
        if providesAudio {
            cfg.capturesAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if providesAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        do { try await s.startCapture() } catch { throw MediaSourceError.failed("Could not start screen capture: \(error.localizedDescription)") }
        stream = s
    }

    public func stop() async {
        let s = stream
        stream = nil
        try? await s?.stopCapture()
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            onVideo?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        case .audio:
            if let pcm = Self.pcmBuffer(from: sampleBuffer) { onAudio?(pcm, CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) }
        default:
            break
        }
    }

    static func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStopped?(error)
    }
}
