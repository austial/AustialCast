# AustialCast wire protocol v1

One TCP connection per cast (default port **7391**, advertised as Bonjour service `_austialcast._tcp`
with TXT keys `id`, `name`, `v`). Everything is big-endian. Reference implementations:
Kotlin `android/core/.../protocol`, Swift `mac/Sources/AustialCastProtocol`. Golden vectors in
`protocol-vectors/vectors.json` pin the byte-level behaviour.

## Frame

```
 0       2      3     4              8
 +-------+------+-----+--------------+------------------+
 | "TC"  | ver  | typ | payload len  | payload          |
 +-------+------+-----+--------------+------------------+
   magic   =1     see   u32 (<=16 MiB)
```

| typ | name | direction | payload |
|---|---|---|---|
| 1 | HELLO | S→R | JSON `{protocol, deviceId, name, platform, appVersion, publicKey}` |
| 2 | CHALLENGE | R→S | JSON `{protocol, deviceId, name, publicKey, trusted, maxWidth, maxHeight, maxFps}` |
| 3 | AUTH | S→R | JSON `{mode: "pin"|"token", proof: hex}` |
| 4 | AUTH_RESULT | R→S | JSON `{ok, proof?, token?, reason?, message?, retry?}` |
| 5 | STREAM_START | S→R | JSON `{width, height, fps, bitrate, codec:"h264", audio?:{codec:"aac", sampleRate, channels, config: hex ASC}, title?}` |
| 6 | VIDEO_CONFIG | S→R | Annex-B SPS + PPS (repeated before every keyframe) |
| 7 | VIDEO_FRAME | S→R | `flags(1: bit0=keyframe) \| pts_us(8) \| Annex-B access unit` |
| 8 | AUDIO_FRAME | S→R | `pts_us(8) \| raw AAC-LC access unit (no ADTS)` |
| 9 / 10 | PING / PONG | both | 8 byte sender timestamp, echoed back (RTT) |
| 11 | CONTROL | both | JSON `{cmd, bitrate?, message?}`; cmds `pause resume requestKeyframe setBitrate stop`; unknown cmds are ignored |
| 12 | STATS | R→S | JSON `{fps, decoded, dropped, bufferMs?}` |
| 13 | BYE | both | JSON `{reason, message?}` (`user busy timeout error rejected replaced`) |

S = sender (Mac), R = receiver (TV). JSON is UTF-8; unknown fields are ignored. All media timestamps are µs since the
first sample of the cast.

## Handshake and key schedule

1. S → R `HELLO` with an ephemeral P-256 public key (X9.63 uncompressed, base64).
2. R → S `CHALLENGE` with its own ephemeral key. `trusted=true` means R holds a pairing token for `deviceId`.
3. Both compute `Z = ECDH(own, peer)` (32 byte X coordinate) and the transcript hash
   `T = SHA-256(HELLO_bytes ‖ CHALLENGE_bytes)` over the exact bytes on the wire (peer keys are validated to be on the curve).
4. Per direction: `HKDF-SHA256(ikm=Z, salt=T, info="austialcast v1 client->server" | "austialcast v1 server->client", L=36)` →
   32 byte AES-256 key ‖ 4 byte nonce prefix.
5. **From here on every frame payload is sealed with AES-256-GCM**: nonce = prefix ‖ u64 counter (starts at 0, +1 per frame
   per direction), AAD = the 8 byte header (whose length field includes the 16 byte tag). Sealed payload = ciphertext ‖ tag.
   Any tamper, replay or reorder fails authentication and closes the connection.
6. S → R `AUTH`:
   - `pin`: `proof = HMAC-SHA256(key=ASCII PIN, "austialcast v1 client" ‖ T)`
   - `token`: same with the 32 byte pairing token as key
7. R verifies, replies `AUTH_RESULT`. On success `proof = HMAC(secret, "austialcast v1 server" ‖ T)` — S **must** verify it
   (mutual authentication). After a successful *PIN* auth R includes a fresh 32 byte `token` (hex) which S stores for
   future PIN-less reconnects.
8. Up to 3 AUTH attempts per connection. A wrong PIN rotates the PIN on R; after 5 failures in a minute the sender
   address is locked out for a minute (`reason: "locked"`).
9. If R is already receiving (and takeover is off) it sends `BYE {busy}`.

## Streaming

S sends `STREAM_START`, then `VIDEO_CONFIG` + `VIDEO_FRAME`s (first frame must be an IDR) and optional `AUDIO_FRAME`s. Video is
H.264 Main profile, no B-frames, Annex-B, ≤2 s keyframe interval. R may send `CONTROL requestKeyframe` at any time and
`CONTROL setBitrate` to ask for a lower bitrate. S pings every 2 s; R closes after 10 s of silence. Either side ends with `BYE`.

When S drops frames because of congestion it drops everything up to the next keyframe so references are never broken.
