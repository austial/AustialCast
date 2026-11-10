import CoreGraphics
import Foundation
import AustialCastCore
import AustialCastProtocol

// austialcast — command line sender for AustialCast. Mostly for scripting, debugging and CI; the menu bar app
// (AustialCastApp) is the everyday interface.

func usage() -> Never {
    print("""
    austialcast — cast this Mac to a AustialCast receiver (Android TV / Google TV)

    USAGE
      austialcast discover [--seconds N]            find TVs on the network
      austialcast list                              list displays and windows that can be cast
      austialcast send --host IP [options]          start casting
      austialcast paired                            list TVs this Mac is paired with
      austialcast forget ID                         forget a paired TV

    SEND OPTIONS
      --host IP[:PORT]       TV address (default port \(defaultPort))
      --pin 123456           PIN shown on the TV (first time only; later casts need none)
      --display ID|main      display to capture (default: main display)
      --window ID            capture one window instead (see `austialcast list`)
      --test-pattern         send a generated test pattern instead of the screen (no permissions needed)
      --preset ID            720p30 | 1080p30 | 1080p60 | 2160p30   (default 1080p30)
      --no-audio             do not send system audio
      --no-cursor            hide the mouse cursor
      --seconds N            stop automatically after N seconds
      --token-file PATH      store pairing tokens in this JSON file (default: ~/Library/Application Support/AustialCast/tokens.json)
    """)
    exit(2)
}

func parse(_ args: [String]) -> [String: String] {
    var map: [String: String] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") { map[key] = args[i + 1]; i += 2; continue }
            map[key] = ""
        }
        i += 1
    }
    return map
}

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
let opts = parse(Array(args.dropFirst()))

func tokenStore() -> TokenStore {
    FileTokenStore(url: opts["token-file"].map { URL(fileURLWithPath: $0) } ?? FileTokenStore.defaultURL)
}

func identity() -> DeviceIdentity {
    // The CLI keeps its own stable id next to the token file so it appears as a distinct sender.
    let defaults = UserDefaults(suiteName: "app.austial.cast.cli") ?? .standard
    var id = IdentityStore.current(defaults: defaults)
    id.name += " (CLI)"
    return id
}

switch command {
case "discover":
    let browser = ReceiverBrowser()
    browser.start()
    let seconds = Double(opts["seconds"] ?? "4") ?? 4
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    if browser.receivers.isEmpty { print("No TVs found. Is AustialCast open on the TV and on the same network?") }
    for r in browser.receivers { print("\(r.name)\t\(r.id)\t\(r.endpoint)") }
    exit(0)

case "list":
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            print("Displays:")
            for d in try await CaptureCatalog.displays() { print("  \(d.id)\t\(d.name)\t\(d.width)x\(d.height)") }
            print("Windows:")
            for w in try await CaptureCatalog.windows() { print("  \(w.id)\t\(w.appName) — \(w.title)\t\(w.width)x\(w.height)") }
        } catch { log("error: \(error)") }
        sem.signal()
    }
    sem.wait()
    exit(0)

case "paired":
    let all = tokenStore().all()
    if all.isEmpty { print("No paired TVs.") }
    for p in all { print("\(p.id)\t\(p.name)") }
    exit(0)

case "forget":
    guard args.count >= 2 else { usage() }
    tokenStore().remove(receiverId: args[1])
    print("Forgot \(args[1])")
    exit(0)

case "send":
    guard let hostArg = opts["host"], let hp = parseHostPort(hostArg) else { log("error: --host is required"); usage() }
    let preset = QualityPreset.byId(opts["preset"] ?? "1080p30") ?? .fullHD30
    let source: CastSourceChoice
    if opts["test-pattern"] != nil {
        source = .testPattern(width: preset.maxWidth, height: preset.maxHeight)
    } else if let w = opts["window"], let id = UInt32(w) {
        source = .window(id)
    } else if let d = opts["display"], d != "main", let id = UInt32(d) {
        source = .display(id)
    } else {
        if !CaptureCatalog.hasPermission {
            log("Screen Recording permission is needed for the terminal app running this command.")
            _ = CaptureCatalog.requestPermission()
        }
        source = .display(CGMainDisplayID())
    }
    let request = CastRequest(target: .host(hp.host, hp.port), pin: opts["pin"], source: source, preset: preset,
                              captureAudio: opts["no-audio"] == nil, showCursor: opts["no-cursor"] == nil)
    let session = CastSession(identity: identity(), tokens: tokenStore())
    session.onState = { state in log("state: \(state)") }
    var lastPrint = Date.distantPast
    session.onStats = { s in
        if Date().timeIntervalSince(lastPrint) >= 2 {
            lastPrint = Date()
            log(String(format: "stats: %.1f fps  %.0f kbps (target %.0f)  rtt %@  dropped %d  %dx%d",
                       s.fps, s.bitrateKbps, s.targetBitrateKbps, s.rttMs.map { String(format: "%.1f ms", $0) } ?? "-", s.droppedFrames, s.width, s.height))
        }
    }
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { log("stopping…"); session.stop() }
    sigint.resume()
    if let secs = opts["seconds"].flatMap(Double.init) {
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { session.stop() }
    }
    Task {
        do {
            try await session.run(request)
            exit(0)
        } catch let e as SenderError {
            log("error: \(e)")
            exit(e.exitCode)
        } catch {
            log("error: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()

default:
    usage()
}

extension SenderError {
    var exitCode: Int32 {
        switch self {
        case .pinRequired: return 10
        case .wrongPin: return 11
        case .busy: return 12
        case .locked: return 13
        case .receiverNotAuthentic: return 14
        default: return 1
        }
    }
}
