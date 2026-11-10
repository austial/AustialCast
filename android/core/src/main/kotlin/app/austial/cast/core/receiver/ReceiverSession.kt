package app.austial.cast.core.receiver

import app.austial.cast.core.protocol.Auth
import app.austial.cast.core.protocol.AuthFailure
import app.austial.cast.core.protocol.AuthResult
import app.austial.cast.core.protocol.Bye
import app.austial.cast.core.protocol.ByeReason
import app.austial.cast.core.protocol.Challenge
import app.austial.cast.core.protocol.Control
import app.austial.cast.core.protocol.ControlCommand
import app.austial.cast.core.protocol.Crypto
import app.austial.cast.core.protocol.Frame
import app.austial.cast.core.protocol.FrameReader
import app.austial.cast.core.protocol.FrameType
import app.austial.cast.core.protocol.FrameWriter
import app.austial.cast.core.protocol.Hello
import app.austial.cast.core.protocol.MediaPayload
import app.austial.cast.core.protocol.PROTOCOL_VERSION
import app.austial.cast.core.protocol.ProtocolException
import app.austial.cast.core.protocol.StreamStart
import app.austial.cast.core.protocol.decodeMessage
import app.austial.cast.core.protocol.encodeMessage
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** One TCP connection: handshake, authentication, then the media loop. */
internal class ReceiverSession(
    private val socket: Socket,
    private val server: ReceiverServer,
) : Runnable {
    private val listener get() = server.listener
    private val finished = CountDownLatch(1)
    private lateinit var reader: FrameReader
    private lateinit var writer: FrameWriter

    @Volatile private var terminated: EndReason? = null
    @Volatile private var peer: PeerInfo? = null
    @Volatile private var streamStarted = false
    @Volatile private var authenticated = false
    private var pendingCounted = true

    @Volatile var lastRttMs: Long? = null
        private set

    fun awaitFinished(ms: Long) {
        finished.await(ms, TimeUnit.MILLISECONDS)
    }

    /** Forces the session to end; the media loop notices the closed socket. */
    fun terminate(reason: EndReason, byeReason: String) {
        terminated = reason
        try {
            if (::writer.isInitialized) writer.write(FrameType.BYE, encodeMessage(Bye(byeReason)))
        } catch (_: IOException) {
        }
        ReceiverServer.closeQuietly(socket)
    }

    fun send(type: FrameType, payload: ByteArray) {
        try {
            writer.write(type, payload)
        } catch (_: IOException) {
            // The read loop will see the broken connection and clean up.
        }
    }

    private fun leavePending() {
        if (pendingCounted) {
            pendingCounted = false
            server.pending.decrementAndGet()
        }
    }

    override fun run() {
        var endReason = EndReason.DISCONNECTED
        try {
            socket.tcpNoDelay = true
            socket.soTimeout = server.config.handshakeTimeoutMs
            reader = FrameReader(BufferedInputStream(socket.getInputStream(), 64 * 1024))
            writer = FrameWriter(BufferedOutputStream(socket.getOutputStream(), 64 * 1024))
            if (handshake()) {
                leavePending()
                socket.soTimeout = server.config.idleTimeoutMs
                endReason = mediaLoop()
            } else {
                endReason = EndReason.ERROR
            }
        } catch (e: SocketTimeoutException) {
            endReason = EndReason.TIMEOUT
        } catch (e: EOFException) {
            endReason = EndReason.DISCONNECTED
        } catch (e: ProtocolException) {
            endReason = EndReason.ERROR
            sendBye(ByeReason.ERROR, e.message)
            if (terminated == null) safely { listener.onError(e) }
        } catch (e: IOException) {
            endReason = EndReason.DISCONNECTED
        } catch (e: Exception) {
            endReason = EndReason.ERROR
            safely { listener.onError(e) }
        } finally {
            leavePending()
            terminated?.let { endReason = it }
            val wasActive = authenticated && streamStarted
            server.release(this)
            ReceiverServer.closeQuietly(socket)
            val p = peer
            if (wasActive && p != null) {
                safely { listener.onStreamEnded(p, endReason) }
            } else {
                safely { listener.onConnectionClosed(p, endReason) }
            }
            finished.countDown()
        }
    }

    private fun sendBye(reason: String, message: String? = null) {
        try {
            writer.write(FrameType.BYE, encodeMessage(Bye(reason, message)))
        } catch (_: IOException) {
        }
    }

    private inline fun safely(block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            try {
                listener.onError(t)
            } catch (_: Throwable) {
            }
        }
    }

    private fun sanitize(text: String, fallback: String): String {
        val cleaned = text.filter { !it.isISOControl() }.trim().take(64)
        return cleaned.ifEmpty { fallback }
    }

    // ---- handshake ------------------------------------------------------------------------

    private fun handshake(): Boolean {
        val helloFrame = reader.read() ?: return false
        if (helloFrame.type != FrameType.HELLO) throw ProtocolException("expected HELLO")
        val hello = decodeMessage<Hello>(helloFrame.payload)
        if (hello.protocol != PROTOCOL_VERSION) throw ProtocolException("unsupported protocol ${hello.protocol}")
        if (hello.deviceId.isBlank() || hello.deviceId.length > 128) throw ProtocolException("invalid deviceId")

        val remote = (socket.remoteSocketAddress as? InetSocketAddress)?.address?.hostAddress ?: "unknown"
        val info = PeerInfo(
            deviceId = hello.deviceId,
            name = sanitize(hello.name, "Unknown device"),
            platform = sanitize(hello.platform, "unknown"),
            remoteAddress = remote,
        )
        peer = info

        val peerKey = try {
            Base64.getDecoder().decode(hello.publicKey)
        } catch (e: IllegalArgumentException) {
            throw ProtocolException("invalid public key encoding", e)
        }

        val cfg = server.config
        val eph = Crypto.generateEphemeral()
        val trusted = cfg.allowTrustedDevices && server.trustStore.get(hello.deviceId) != null
        val challengeBytes = encodeMessage(
            Challenge(
                deviceId = cfg.deviceId,
                name = cfg.deviceName,
                publicKey = Base64.getEncoder().encodeToString(eph.publicX963),
                trusted = trusted,
                maxWidth = cfg.maxWidth,
                maxHeight = cfg.maxHeight,
                maxFps = cfg.maxFps,
            ),
        )
        writer.write(FrameType.CHALLENGE, challengeBytes)

        val shared = Crypto.ecdh(eph.keyPair, peerKey)
        val transcript = Crypto.transcriptHash(helloFrame.payload, challengeBytes)
        val keys = Crypto.deriveSessionKeys(shared, transcript)
        // From here on every frame is AES-GCM sealed. We receive client->server, send server->client.
        reader.cipher = keys.clientToServer
        writer.cipher = keys.serverToClient

        safely { listener.onPeerConnecting(info) }

        if (!authenticate(info, transcript, remote)) return false

        authenticated = true
        if (!server.claimActive(this)) {
            sendBye(ByeReason.BUSY, "Another device is already casting")
            safely { listener.onAuthFailed(info, "busy") }
            return false
        }
        return true
    }

    private fun authenticate(info: PeerInfo, transcript: ByteArray, remote: String): Boolean {
        val cfg = server.config
        repeat(MAX_AUTH_ATTEMPTS) { attempt ->
            val frame = reader.read() ?: return false
            if (frame.type != FrameType.AUTH) throw ProtocolException("expected AUTH")
            val auth = decodeMessage<Auth>(frame.payload)
            val proof = try {
                Crypto.unhex(auth.proof)
            } catch (e: IllegalArgumentException) {
                ByteArray(0)
            }
            val lastAttempt = attempt == MAX_AUTH_ATTEMPTS - 1
            when (auth.mode) {
                "token" -> {
                    val token = if (cfg.allowTrustedDevices) server.trustStore.get(info.deviceId) else null
                    if (token != null && Crypto.constantTimeEquals(proof, Crypto.clientProof(token, transcript))) {
                        writer.write(
                            FrameType.AUTH_RESULT,
                            encodeMessage(AuthResult(ok = true, proof = Crypto.hex(Crypto.serverProof(token, transcript)))),
                        )
                        safely { listener.onAuthenticated(info, viaToken = true) }
                        return true
                    }
                    writer.write(
                        FrameType.AUTH_RESULT,
                        encodeMessage(AuthResult(ok = false, reason = AuthFailure.BAD_TOKEN, retry = !lastAttempt)),
                    )
                    safely { listener.onAuthFailed(info, AuthFailure.BAD_TOKEN) }
                }

                "pin" -> {
                    if (server.pins.isLocked(remote)) {
                        writer.write(
                            FrameType.AUTH_RESULT,
                            encodeMessage(
                                AuthResult(
                                    ok = false,
                                    reason = AuthFailure.LOCKED,
                                    message = "Too many wrong PINs. Try again in ${server.pins.lockRemainingMs(remote) / 1000 + 1}s.",
                                    retry = false,
                                ),
                            ),
                        )
                        safely { listener.onAuthFailed(info, AuthFailure.LOCKED) }
                        return false
                    }
                    val pin = server.pins.pinForAttempt().toByteArray(Charsets.US_ASCII)
                    val ok = Crypto.constantTimeEquals(proof, Crypto.clientProof(pin, transcript))
                    server.pins.attemptFinished(remote, ok)
                    server.listener.let { l -> safely { l.onPinChanged(server.pins.current) } }
                    if (ok) {
                        var tokenHex: String? = null
                        if (cfg.allowTrustedDevices) {
                            val token = PinManager.newToken()
                            server.trustStore.put(info.deviceId, info.name, token)
                            tokenHex = Crypto.hex(token)
                        }
                        writer.write(
                            FrameType.AUTH_RESULT,
                            encodeMessage(AuthResult(ok = true, proof = Crypto.hex(Crypto.serverProof(pin, transcript)), token = tokenHex)),
                        )
                        safely { listener.onAuthenticated(info, viaToken = false) }
                        return true
                    }
                    writer.write(
                        FrameType.AUTH_RESULT,
                        encodeMessage(AuthResult(ok = false, reason = AuthFailure.BAD_PIN, retry = !lastAttempt)),
                    )
                    safely { listener.onAuthFailed(info, AuthFailure.BAD_PIN) }
                }

                else -> {
                    writer.write(
                        FrameType.AUTH_RESULT,
                        encodeMessage(AuthResult(ok = false, reason = AuthFailure.UNEXPECTED, retry = false)),
                    )
                    return false
                }
            }
        }
        return false
    }

    // ---- media loop -----------------------------------------------------------------------

    private fun mediaLoop(): EndReason {
        val info = peer!!
        while (true) {
            val frame: Frame = try {
                reader.read() ?: return terminated ?: EndReason.DISCONNECTED
            } catch (e: SocketTimeoutException) {
                sendBye(ByeReason.TIMEOUT)
                return EndReason.TIMEOUT
            }
            when (frame.type) {
                FrameType.STREAM_START -> {
                    val start = decodeMessage<StreamStart>(frame.payload)
                    validate(start)
                    streamStarted = true
                    safely { listener.onStreamStarted(info, start) }
                }

                FrameType.VIDEO_CONFIG -> {
                    requireStreaming()
                    safely { listener.onVideoConfig(frame.payload) }
                }

                FrameType.VIDEO_FRAME -> {
                    requireStreaming()
                    val vf = MediaPayload.decodeVideo(frame.payload)
                    safely { listener.onVideoFrame(vf) }
                }

                FrameType.AUDIO_FRAME -> {
                    requireStreaming()
                    val af = MediaPayload.decodeAudio(frame.payload)
                    safely { listener.onAudioFrame(af) }
                }

                FrameType.PING -> {
                    // The sender measures RTT itself; it may also report it back to us in the payload.
                    send(FrameType.PONG, frame.payload)
                }

                FrameType.PONG -> {
                    if (frame.payload.size >= 8) {
                        val sent = java.nio.ByteBuffer.wrap(frame.payload).long
                        lastRttMs = ((System.nanoTime() / 1000 - sent) / 1000).coerceAtLeast(0)
                    }
                }

                FrameType.CONTROL -> {
                    val control = decodeMessage<Control>(frame.payload)
                    when (control.cmd) {
                        ControlCommand.PAUSE -> safely { listener.onPaused(true) }
                        ControlCommand.RESUME -> safely { listener.onPaused(false) }
                        ControlCommand.STOP -> return EndReason.SENDER_STOPPED
                        else -> Unit // unknown commands are ignored for forward compatibility
                    }
                }

                FrameType.BYE -> return EndReason.SENDER_STOPPED
                else -> throw ProtocolException("unexpected ${frame.type} while streaming")
            }
        }
    }

    private fun requireStreaming() {
        if (!streamStarted) throw ProtocolException("media before STREAM_START")
    }

    private fun validate(start: StreamStart) {
        if (start.width !in 16..8192 || start.height !in 16..8192) throw ProtocolException("bad stream size")
        if (start.fps !in 1..240) throw ProtocolException("bad frame rate")
        if (start.codec != "h264") throw ProtocolException("unsupported codec ${start.codec}")
        start.audio?.let {
            if (it.codec != "aac" || it.channels !in 1..8 || it.sampleRate !in 8000..96000) {
                throw ProtocolException("unsupported audio format")
            }
        }
    }

    companion object {
        const val MAX_AUTH_ATTEMPTS = 3
    }
}
