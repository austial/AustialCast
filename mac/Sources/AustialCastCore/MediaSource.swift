import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public enum MediaSourceError: Error, CustomStringConvertible {
    case permissionDenied
    case noDisplay
    case windowGone
    case failed(String)
    public var description: String {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is required. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch."
        case .noDisplay: return "No display available to capture"
        case .windowGone: return "The selected window is no longer available"
        case .failed(let m): return m
        }
    }
}

/// Anything that produces screen frames (and optionally audio): real capture or the test pattern.
public protocol MediaSource: AnyObject {
    /// Native pixel size of the content.
    var pixelSize: (width: Int, height: Int) { get }
    var title: String { get }
    var providesAudio: Bool { get }
    /// True if idle frames should be re-sent so a static screen keeps the stream alive.
    var needsIdleRepeat: Bool { get }
    var onVideo: ((CVPixelBuffer, CMTime) -> Void)? { get set }
    var onAudio: ((AVAudioPCMBuffer, CMTime) -> Void)? { get set }
    var onStopped: ((Error?) -> Void)? { get set }
    func start() async throws
    func stop() async
}

func hostTime() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
