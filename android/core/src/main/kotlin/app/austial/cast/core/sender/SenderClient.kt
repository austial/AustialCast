package app.austial.cast.core.sender

import app.austial.cast.core.protocol.Auth
import app.austial.cast.core.protocol.AuthResult
import app.austial.cast.core.protocol.AudioFrame
import app.austial.cast.core.protocol.Bye
import app.austial.cast.core.protocol.ByeReason
import app.austial.cast.core.protocol.Challenge
import app.austial.cast.core.protocol.Control
import app.austial.cast.core.protocol.Crypto
import app.austial.cast.core.protocol.Frame
import app.austial.cast.core.protocol.FrameReader
import app.austial.cast.core.protocol.FrameType
import app.austial.cast.core.protocol.FrameWriter
import app.austial.cast.core.protocol.Hello
import app.austial.cast.core.protocol.MediaPayload
import app.austial.cast.core.protocol.ProtocolException
import app.austial.cast.core.protocol.StreamStart
import app.austial.cast.core.protocol.VideoFrame
import app.austial.cast.core.protocol.decodeMessage
import app.austial.cast.core.protocol.encodeMessage
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.Base64

/**
 * A minimal JVM implementation of the sender side of the protocol. It is used by the test-suite
 * and by the developer CLI to exercise the receiver without a Mac.
 */
class SenderClient(
    private val host: String,
    private val port: Int,
    private val deviceId: String,
    private val name: String = "Test Sender",
    private val platform: String = "jvm",
) : Closeable {
    private lateinit var socket: Socket
    lateinit var reader: FrameReader
        private set
    lateinit var writer: FrameWriter
        private set
    private lateinit var transcript: ByteArray
    lateinit var challenge: Challenge
        private set

    /** Opens the connection and runs the key exchange. After this, all traffic is encrypted. */
    fun connect(timeoutMs: Int = 5000): Challenge {
        socket = Socket()
        socket.tcpNoDelay = true
        socket.connect(InetSocketAddress(host, port), timeoutMs)
        socket.soTimeout = timeoutMs
        reader = FrameReader(BufferedInputStream(socket.getInputStream()))
        writer = FrameWriter(BufferedOutputStream(socket.getOutputStream()))

        val eph = Crypto.generateEphemeral()
        val helloBytes = encodeMessage(
            Hello(
                deviceId = deviceId,
                name = name,
                platform = platform,
                appVersion = "test",
                publicKey = Base64.getEncoder().encodeToString(eph.publicX963),
            ),
        )
        writer.write(FrameType.HELLO, helloBytes)
        val frame = reader.read() ?: throw ProtocolException("receiver closed during handshake")
        if (frame.type == FrameType.BYE) {
            val bye = decodeMessage<Bye>(frame.payload)
            throw ProtocolException("receiver said bye: ${bye.reason}")
        }
        if (frame.type != FrameType.CHALLENGE) throw ProtocolException("expected CHALLENGE")
        challenge = decodeMessage(frame.payload)
        val shared = Crypto.ecdh(eph.keyPair, Base64.getDecoder().decode(challenge.publicKey))
        transcript = Crypto.transcriptHash(helloBytes, frame.payload)
        val keys = Crypto.deriveSessionKeys(shared, transcript)
        writer.cipher = keys.clientToServer
        reader.cipher = keys.serverToClient
        return challenge
    }

    /** Sends an AUTH and returns the result; verifies the receiver's proof on success. */
    fun authenticate(mode: String, secret: ByteArray): AuthResult {
        val proof = Crypto.hex(Crypto.clientProof(secret, transcript))
        writer.write(FrameType.AUTH, encodeMessage(Auth(mode, proof)))
        val frame = reader.read() ?: throw ProtocolException("receiver closed during auth")
        if (frame.type == FrameType.BYE) {
            val bye = decodeMessage<Bye>(frame.payload)
            return AuthResult(ok = false, reason = bye.reason, message = bye.message)
        }
        if (frame.type != FrameType.AUTH_RESULT) throw ProtocolException("expected AUTH_RESULT")
        val result = decodeMessage<AuthResult>(frame.payload)
        if (result.ok) {
            val expected = Crypto.serverProof(secret, transcript)
            val got = result.proof?.let { Crypto.unhex(it) } ?: ByteArray(0)
            if (!Crypto.constantTimeEquals(expected, got)) throw ProtocolException("receiver failed to prove knowledge of secret")
        }
        return result
    }

    fun authenticateWithPin(pin: String) = authenticate("pin", pin.toByteArray(Charsets.US_ASCII))
    fun authenticateWithToken(tokenHex: String) = authenticate("token", Crypto.unhex(tokenHex))

    fun startStream(start: StreamStart) = writer.write(FrameType.STREAM_START, encodeMessage(start))
    fun sendConfig(annexB: ByteArray) = writer.write(FrameType.VIDEO_CONFIG, annexB)
    fun sendVideo(frame: VideoFrame) = writer.write(FrameType.VIDEO_FRAME, MediaPayload.encodeVideo(frame))
    fun sendAudio(frame: AudioFrame) = writer.write(FrameType.AUDIO_FRAME, MediaPayload.encodeAudio(frame))
    fun sendControl(control: Control) = writer.write(FrameType.CONTROL, encodeMessage(control))

    fun ping(): Long {
        val sent = System.nanoTime() / 1000
        writer.write(FrameType.PING, ByteBuffer.allocate(8).putLong(sent).array())
        return sent
    }

    fun read(): Frame? = reader.read()

    fun setReadTimeout(ms: Int) {
        socket.soTimeout = ms
    }

    fun bye(reason: String = ByeReason.USER) {
        try {
            writer.write(FrameType.BYE, encodeMessage(Bye(reason)))
        } catch (_: Exception) {
        }
    }

    override fun close() {
        try {
            socket.close()
        } catch (_: Exception) {
        }
    }
}
