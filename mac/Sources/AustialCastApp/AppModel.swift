import AppKit
import Combine
import Foundation
import Network
import ServiceManagement
import SwiftUI
import AustialCastCore
import AustialCastProtocol

enum SourceKind: String, CaseIterable, Identifiable {
    case display = "Entire screen"
    case window = "One window"
    var id: String { rawValue }
}

/// A TV the user picked that still needs a PIN.
struct PinRequest: Identifiable {
    let id = UUID()
    let name: String
    let target: CastTarget
    var wrongPin = false
}

@MainActor
final class AppModel: ObservableObject {
    // Discovery
    let browser = ReceiverBrowser()
    @Published var receivers: [DiscoveredReceiver] = []
    @Published var manualHost = ""

    // Cast state
    @Published var state: CastState = .idle
    @Published var stats = CastStats()
    @Published var error: String?
    @Published var pinRequest: PinRequest?
    @Published var pinInput = ""
    @Published var connectingTo: String?

    // Sources
    @Published var displays: [CaptureDisplay] = []
    @Published var windows: [CaptureWindow] = []
    @Published var hasPermission = CaptureCatalog.hasPermission
    @Published var paired: [PairedReceiver] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    // Settings (persisted)
    @AppStorage("sourceKind") var sourceKindRaw = SourceKind.display.rawValue
    @AppStorage("displayId") var displayId = 0
    @AppStorage("windowId") var windowId = 0
    @AppStorage("presetId") var presetId = QualityPreset.fullHD30.id
    @AppStorage("captureAudio") var captureAudio = true
    @AppStorage("showCursor") var showCursor = true
    @AppStorage("lastHost") var lastHost = ""

    private let tokens: TokenStore
    private let identity: DeviceIdentity
    private var session: CastSession?
    private var browserCancellable: AnyCancellable?

    var sourceKind: SourceKind {
        get { SourceKind(rawValue: sourceKindRaw) ?? .display }
        set { sourceKindRaw = newValue.rawValue }
    }

    var preset: QualityPreset {
        get { QualityPreset.byId(presetId) ?? .fullHD30 }
        set { presetId = newValue.id }
    }

    var isCasting: Bool {
        switch state {
        case .connecting, .authenticating, .streaming, .paused: return true
        default: return false
        }
    }

    var isStreaming: Bool {
        switch state {
        case .streaming, .paused: return true
        default: return false
        }
    }

    var isPaused: Bool { if case .paused = state { return true } else { return false } }

    var menuBarSymbol: String {
        switch state {
        case .streaming: return "tv.fill"
        case .paused: return "pause.rectangle"
        case .connecting, .authenticating: return "antenna.radiowaves.left.and.right"
        default: return "tv"
        }
    }

    var statusLine: String {
        switch state {
        case .idle: return receivers.isEmpty ? "Searching for TVs…" : "Ready to cast"
        case .connecting: return "Connecting to \(connectingTo ?? "TV")…"
        case .authenticating: return "Pairing with \(connectingTo ?? "TV")…"
        case .streaming(let name, let w, let h, let fps): return "Casting to \(name.isEmpty ? (connectingTo ?? "TV") : name) · \(w)×\(h) @ \(fps)"
        case .paused: return "Paused"
        case .ended(let reason): return reason ?? "Ready to cast"
        }
    }

    init() {
        let keychain = KeychainTokenStore()
        tokens = FallbackTokenStore(primary: keychain, fallback: FileTokenStore(url: FileTokenStore.defaultURL))
        identity = IdentityStore.current()
        browserCancellable = browser.$receivers.receive(on: DispatchQueue.main).sink { [weak self] in self?.receivers = $0 }
        browser.start()
        refreshPaired()
        Task { await refreshSources() }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "Could not change the login item: \(error.localizedDescription). Run the installed AustialCast.app from /Applications."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refreshPaired() { paired = tokens.all() }

    func forget(_ id: String) {
        tokens.remove(receiverId: id)
        refreshPaired()
    }

    func refreshSources() async {
        hasPermission = CaptureCatalog.hasPermission
        guard hasPermission else { return }
        if let d = try? await CaptureCatalog.displays() {
            displays = d
            if !d.contains(where: { Int($0.id) == displayId }) { displayId = Int(d.first?.id ?? 0) }
        }
        if let w = try? await CaptureCatalog.windows() {
            windows = w
            if !w.contains(where: { Int($0.id) == windowId }) { windowId = Int(w.first?.id ?? 0) }
        }
    }

    func requestPermission() {
        _ = CaptureCatalog.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: casting

    func connect(to receiver: DiscoveredReceiver) {
        start(target: .endpoint(receiver.endpoint), name: receiver.name, pin: nil)
    }

    func connectManual() {
        guard let hp = parseHostPort(manualHost) else {
            error = "Enter an address like 192.168.1.20 or 192.168.1.20:7391"
            return
        }
        lastHost = manualHost
        start(target: .host(hp.host, hp.port), name: manualHost, pin: nil)
    }

    func submitPin() {
        guard let req = pinRequest else { return }
        let pin = pinInput.filter(\.isNumber)
        guard pin.count == 6 else { return }
        start(target: req.target, name: req.name, pin: pin)
    }

    func cancelPin() {
        pinRequest = nil
        pinInput = ""
    }

    private func source() -> CastSourceChoice? {
        switch sourceKind {
        case .display:
            guard let id = displays.first(where: { Int($0.id) == displayId })?.id ?? displays.first?.id else { return nil }
            return .display(id)
        case .window:
            guard windowId != 0 else { return nil }
            return .window(CGWindowID(windowId))
        }
    }

    private func start(target: CastTarget, name: String, pin: String?) {
        guard !isCasting else { return }
        error = nil
        guard CaptureCatalog.hasPermission || CaptureCatalog.requestPermission() else {
            hasPermission = false
            error = "Allow Screen Recording for AustialCast in System Settings, then try again."
            return
        }
        guard let src = source() else {
            error = "Nothing to capture. Pick a screen or window first."
            Task { await refreshSources() }
            return
        }
        let s = CastSession(identity: identity, tokens: tokens, appVersion: "1.0.0")
        session = s
        connectingTo = name
        state = .connecting
        s.onState = { [weak self] st in Task { @MainActor in self?.apply(st) } }
        s.onStats = { [weak self] st in Task { @MainActor in self?.stats = st } }
        let request = CastRequest(target: target, pin: pin, source: src, preset: preset, captureAudio: captureAudio, showCursor: showCursor)
        Task { [weak self] in
            do {
                try await s.run(request)
                await MainActor.run { self?.finished() }
            } catch let e as SenderError {
                await MainActor.run { self?.failed(e, target: target, name: name) }
            } catch {
                await MainActor.run { self?.failed(error) }
            }
        }
    }

    private func apply(_ st: CastState) {
        state = st
        if case .streaming = st { pinRequest = nil; pinInput = ""; refreshPaired() }
    }

    private func finished() {
        session = nil
        if case .ended(let reason) = state, let reason { error = reason }
        state = .idle
        stats = CastStats()
    }

    private func failed(_ e: SenderError, target: CastTarget, name: String) {
        session = nil
        state = .idle
        switch e {
        case .pinRequired(let n):
            pinRequest = PinRequest(name: n, target: target)
            pinInput = ""
            error = nil
        case .wrongPin:
            pinRequest = PinRequest(name: name, target: target, wrongPin: true)
            pinInput = ""
            error = nil
        default:
            error = e.description
        }
    }

    private func failed(_ e: Error) {
        session = nil
        state = .idle
        error = "\(e)"
    }

    func stop() { session?.stop() }

    func togglePause() { session?.setPaused(!(session?.isPaused ?? false)) }
}
