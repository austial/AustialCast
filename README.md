# AustialCast — cast your MacBook to an Android TV / Google TV

AustialCast mirrors your Mac's screen (or a single window) **with system audio** to any Android TV or Google TV
on the same network. It has two halves that speak one small, encrypted protocol:

| | What it is | Tech |
|---|---|---|
| **AustialCast for TV** (`android/app`) | Receiver app for Android TV / Google TV. Shows a PIN, decodes the stream, plays it full screen. | Kotlin, MediaCodec (H.264 + AAC), NsdManager |
| **AustialCast for Mac** (`mac/`) | Menu bar app (+ `austialcast` command line tool) that captures, encodes and sends. | Swift, ScreenCaptureKit, VideoToolbox, Network.framework |
| **Core** (`android/core`) | Protocol, crypto, receiver server and all TV-side logic, as a pure-JVM module so it is unit-testable. | Kotlin/JVM |

```
 Mac                                                     Android TV / Google TV
┌──────────────────────────────┐   Bonjour _austialcast._tcp  ┌───────────────────────────────┐
│ ScreenCaptureKit ──► H.264   │ ◄──── discovery ──────► │ NsdManager advertiser         │
│ (screen/window)     (VideoToolbox, hardware)           │                               │
│ system audio ───────► AAC    │                         │ ReceiverServer (TCP :7391)    │
│                              │   ECDH + AES-256-GCM    │   PIN / token auth            │
│ CastSession ─ congestion ctl ├────────────────────────►│   ├─► MediaCodec H.264 ► Surface
│  adaptive bitrate, pause     │   video/audio frames    │   └─► MediaCodec AAC ► AudioTrack
│                              │ ◄── keyframe requests,  │ stats overlay, settings, remote│
└──────────────────────────────┘     stats, ping ───────┘ └───────────────────────────────┘
```

## Features

**Casting**
- Mirror an **entire screen** or **one window**; mouse pointer on/off
- **System audio** (AAC-LC, 128 kbit/s) streamed with the picture
- Quality presets: 720p30 · 1080p30 · 1080p60 · 4K30 — automatically limited to what the TV supports, never upscaled
- **Adaptive bitrate**: when Wi-Fi gets congested the sender sheds bitrate, drops frames only up to the next keyframe (so the picture never smears) and recovers slowly afterwards
- **Pause / resume** from the Mac; idle screens keep streaming (static desktop doesn't starve the decoder)
- Latency-bounded receiver queue: if the TV falls behind it skips ahead instead of accumulating delay

**Pairing & security**
- Automatic **Bonjour/mDNS discovery**, or enter an IP address
- **One-time PIN** shown on the TV; afterwards the Mac is a *trusted device* and reconnects with no PIN
- **End-to-end encryption** (ephemeral ECDH P-256 → HKDF → AES-256-GCM, per-direction keys, replay protection) and **mutual authentication** — the Mac verifies the TV really knows the PIN, so a man-in-the-middle is detected (see [docs/SECURITY.md](docs/SECURITY.md))
- Brute-force protection: PINs are single-use and rotate after *every* attempt; repeated failures lock the sender's address out
- Manage / forget paired devices on both sides; the Mac keeps tokens in the Keychain

**TV experience**
- Large-type PIN screen with address for manual connect, remote-friendly settings (D-pad focus)
- **Stats overlay** (resolution, fps, bitrate, ping, dropped frames) — toggle with OK/Menu/Info on the remote, or always-on in Settings
- Press **Back twice** to stop casting; screen stays awake while casting
- Picture scaling **Fit / Fill**; **smoothness** = jitter buffer 0 / 60 / 150 ms (lowest latency vs. smoothest video)
- Optionally let a new cast **take over** from the current one

**Mac extras**
- Menu bar app with live stats, launch-at-login, Screen Recording permission helper
- `austialcast` CLI for scripting: `discover`, `list`, `send`, `paired`, `forget`; `--test-pattern` needs no permissions

## Install

### 1. TV app

Build a signed APK and sideload it (Developer options → USB/network debugging on the TV):

```bash
./scripts/build-tv-apk.sh                    # -> dist/AustialCast-TV.apk
adb connect <tv-ip>:5555
adb install -r dist/AustialCast-TV.apk
```

Open **AustialCast** from the TV's app list. It shows a PIN and the TV's address.

### 2. Mac app

```bash
./scripts/build-mac-app.sh --install         # -> /Applications/AustialCast.app
open /Applications/AustialCast.app
```

Allow **Screen Recording** (System Settings → Privacy & Security) and **Local Network** when asked.

### 3. Cast

Click the TV icon in the menu bar → pick your TV → enter the PIN (first time only) → done. Choose screen/window, quality
and audio before you start. Stop from the menu bar, or press Back twice on the TV remote.

Command line equivalent:

```bash
mac/.build/release/austialcast discover
austialcast send --host 192.168.1.20 --pin 123456 --preset 1080p60     # first time
austialcast send --host 192.168.1.20                                    # later: no PIN
austialcast send --host 192.168.1.20 --window 922 --no-audio            # one window, no sound
```

## Requirements

- Mac: macOS 14+ (Apple silicon or Intel with hardware H.264), Xcode 16+/Swift 6 toolchain
- TV: Android TV / Google TV with Android 7.0+ (API 24); H.264 decoding is universal
- Both on the same LAN (wired TV + 5 GHz Wi-Fi Mac works best). Typical bitrates: 720p30 ≈ 3.5 Mbit/s, 1080p60 ≈ 12 Mbit/s
- To build: JDK 17, Android SDK (platform 36), Gradle wrapper included

## Project layout

```
android/core    protocol (framing, crypto, messages, Annex-B), ReceiverServer, pairing, UI state machine,
                playout queue/clock, JVM sender client, headless receiver CLI           — 113 tests
android/app     Android TV app: controller, MediaCodec video/audio, NSD, activities     — 5 tests + E2E
mac/Sources/AustialCastProtocol   Swift mirror of the protocol (CryptoKit)                    — 28 tests
mac/Sources/AustialCastCore       sender: capture, VideoToolbox/AAC encoders, CastSession,
                             congestion control, discovery, token stores                 — 42 tests
mac/Sources/AustialCastApp        SwiftUI menu bar app
mac/Sources/austialcast           command line tool
protocol-vectors/            golden vectors generated by Kotlin, verified by Swift
docs/                        PROTOCOL.md, SECURITY.md
scripts/                     build + test scripts
```

## Testing

```bash
./scripts/test-all.sh              # everything
./scripts/test-all.sh --no-emulator
```

| Layer | What it proves |
|---|---|
| Kotlin unit tests | framing edge cases (1-byte reads, oversize, truncation), AES-GCM tamper/replay/reorder detection, RFC 5869/4231 vectors, off-curve key rejection, H.264 Annex-B/SPS parsing, PIN rotation + lockout, trust store, playout queue/clock, UI state machine |
| Kotlin integration tests | a real `ReceiverServer` on loopback with a real client: pairing, token reconnect, wrong PIN, lockout, busy/takeover, protocol violations, timeouts, garbage input, handshake flooding, 600-frame streams |
| Swift tests | wire compatibility with Kotlin via **golden vectors** (public keys, shared secret, sealed frames, proofs, JSON); **VideoToolbox encode → decode round-trip checking each frame's pixels**; `CastSession` against a fake receiver: pairing, token fallback, **forged receiver proof detection**, pause/resume, keyframe requests, bye/connection loss, stats |
| `scripts/e2e.sh` | Swift sender (real encoder, AAC, encryption) → Kotlin receiver server: PIN pairing, token reconnect, rejection of wrong/missing PIN, valid H.264 stream on disk |
| `scripts/e2e-emulator.sh` | Swift sender → **real TV app on an Android TV emulator**: install, PIN read from the screen, decoded colour bars verified by screenshot pixels, notices, token reconnect, no crashes |
| Android lint | enforced (`abortOnError`) |

Needs for the emulator test: `sdkmanager "emulator" "system-images;android-34;android-tv;arm64-v8a"`, an AVD named `austialcast_tv`, and
`emulator -avd austialcast_tv -no-window -no-audio -no-snapshot &`.

Not automatable without a human/hardware: real ScreenCaptureKit permission prompts, Wi-Fi behaviour, and visual quality on a physical TV.
(Real capture was verified manually: Retina display → 1662×1080@30 and system audio at ~47 AAC packets/s.)

## Troubleshooting

- **TV not listed on the Mac** — both must be on the same subnet (guest/IoT VLANs often block mDNS); use *Enter TV address manually* with the address shown on the TV. Allow *Local Network* for AustialCast in System Settings.
- **"Screen Recording permission is required"** — enable AustialCast (or your terminal for the CLI) under Privacy & Security → Screen & System Audio Recording, then relaunch.
- **Choppy video** — pick a lower preset, use 5 GHz/Ethernet; the stats overlay on the TV (press OK) shows fps, bitrate, ping and dropped frames. Switch *Smoothness* to "Balanced" for steadier motion at +60 ms latency.
- **Wrong PIN** — a new PIN appears on the TV after every attempt; five failures lock that Mac out for a minute.
- **TV only receives while AustialCast is open** on the TV (the receiver stops when you leave the app).

## Limitations / ideas

- Video-only mirroring: no remote control of the Mac from the TV, no HDR/10-bit, no multi-receiver fan-out
- The receiver runs only while its screen is open (no background service / wake-on-cast)
- Not a Chromecast/Google Cast sender; this pairs AustialCast Mac ↔ AustialCast TV (open protocol in `docs/PROTOCOL.md`, easy to implement from other platforms)
