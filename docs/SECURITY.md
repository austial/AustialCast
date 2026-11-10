# Security notes

AustialCast is designed for a **home/office LAN**. What it protects, and what it does not:

## Protections

| Threat | Mitigation |
|---|---|
| Eavesdropper on the Wi-Fi sees your screen | All frames after the first two are AES-256-GCM encrypted with keys from an ephemeral ECDH exchange (forward secrecy: no long-term key can decrypt old captures) |
| Someone on the LAN casts to your TV | Needs the 6-digit PIN shown on the TV (or a token issued after a PIN) |
| PIN brute-force | PIN is single-use and rotates after *every* attempt; max 3 attempts per connection; 5 failures per address → 1 minute lockout; ≤4 concurrent unauthenticated connections |
| Passive sniffing of the PIN proof | The proof is sent *inside* the encrypted channel, so it is not visible on the wire |
| Active man-in-the-middle | Proofs are bound to the handshake transcript `T` (both ephemeral keys). A MITM that relays traffic has different `T` on each leg and cannot produce a valid proof without the PIN/token. The Mac also verifies the TV's proof before sending any media (tested: `testForgedReceiverProofAbortsTheCast`) |
| Stolen pairing token reused from another Mac | Tokens are bound to the sender's `deviceId` on the TV and are 256-bit random secrets; tokens live in the Mac Keychain (file fallback is mode 0600) |
| Malformed / hostile peers | Length limits (16 MiB), strict type checks, on-curve key validation, sanitised device names (UI injection), media rejected before `STREAM_START` |
| Replay / reordering | GCM nonce is a strict per-direction counter; out-of-order frames fail to decrypt |

## Known limitations (be honest about the threat model)

- A PIN is only 20 bits. An attacker who performs an **active MITM during the very first pairing** gets exactly one online guess
  (PIN burns on use) — roughly a 1-in-a-million chance per pairing attempt, and the user sees the TV's PIN change. For stronger
  first-pairing guarantees you would use a PAKE (SPAKE2/OPAQUE); not implemented.
- Pairing tokens stored on the TV are protected only by Android's per-app sandbox (not hardware-backed).
- A device with local access to the TV (or a rooted TV) can read tokens or see decoded frames. Use *Settings → Remember paired
  devices = Off* on shared TVs to require the PIN every time.
- Metadata is visible: the Bonjour advertisement exposes the TV name/id; the sender name and address are visible on connect.
- No protection against a compromised Mac (it has your screen anyway).
