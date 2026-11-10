package app.austial.cast.core.protocol

import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

const val PROTOCOL_VERSION = 1
const val DEFAULT_PORT = 7391
const val SERVICE_TYPE = "_austialcast._tcp"
const val HEADER_SIZE = 8
const val MAX_PAYLOAD = 16 * 1024 * 1024
const val GCM_TAG_BYTES = 16

private const val MAGIC_0 = 0x54 // 'T'
private const val MAGIC_1 = 0x43 // 'C'

/** Thrown when the peer violates the wire protocol. */
class ProtocolException(message: String, cause: Throwable? = null) : IOException(message, cause)

/**
 * All frame types of the AustialCast wire protocol. The numeric ids are part of the wire format and
 * must never be reused.
 */
enum class FrameType(val id: Int) {
    HELLO(1),
    CHALLENGE(2),
    AUTH(3),
    AUTH_RESULT(4),
    STREAM_START(5),
    VIDEO_CONFIG(6),
    VIDEO_FRAME(7),
    AUDIO_FRAME(8),
    PING(9),
    PONG(10),
    CONTROL(11),
    STATS(12),
    BYE(13);

    companion object {
        private val byId = entries.associateBy { it.id }
        fun fromId(id: Int): FrameType? = byId[id]
    }
}

class Frame(val type: FrameType, val payload: ByteArray) {
    override fun toString() = "Frame($type, ${payload.size} bytes)"
}

/** Builds the 8 byte header: magic(2) version(1) type(1) length(4, big endian). */
internal fun buildHeader(type: Int, length: Int): ByteArray {
    val h = ByteArray(HEADER_SIZE)
    h[0] = MAGIC_0.toByte()
    h[1] = MAGIC_1.toByte()
    h[2] = PROTOCOL_VERSION.toByte()
    h[3] = type.toByte()
    h[4] = (length ushr 24).toByte()
    h[5] = (length ushr 16).toByte()
    h[6] = (length ushr 8).toByte()
    h[7] = length.toByte()
    return h
}

/**
 * Writes frames to a stream. If a [PacketCipher] is installed, payloads are sealed with
 * AES-256-GCM; the (sealed-length) header is authenticated as AAD. Thread safe.
 */
class FrameWriter(private val out: OutputStream) {
    @Volatile
    var cipher: PacketCipher? = null

    @Synchronized
    fun write(type: FrameType, payload: ByteArray = ByteArray(0)) {
        val c = cipher
        val body: ByteArray
        val header: ByteArray
        if (c == null) {
            if (payload.size > MAX_PAYLOAD) throw ProtocolException("payload too large: ${payload.size}")
            header = buildHeader(type.id, payload.size)
            body = payload
        } else {
            val sealedSize = payload.size + GCM_TAG_BYTES
            if (sealedSize > MAX_PAYLOAD) throw ProtocolException("payload too large: ${payload.size}")
            header = buildHeader(type.id, sealedSize)
            body = c.seal(header, payload)
        }
        out.write(header)
        out.write(body)
        out.flush()
    }
}

/** Reads frames from a stream. Not thread safe: use from a single reader thread. */
class FrameReader(private val input: InputStream) {
    @Volatile
    var cipher: PacketCipher? = null

    /** Returns the next frame or null on a clean EOF at a frame boundary. */
    fun read(): Frame? {
        val header = ByteArray(HEADER_SIZE)
        val first = input.read()
        if (first < 0) return null
        header[0] = first.toByte()
        readFully(header, 1, HEADER_SIZE - 1)
        if ((header[0].toInt() and 0xff) != MAGIC_0 || (header[1].toInt() and 0xff) != MAGIC_1) {
            throw ProtocolException("bad magic")
        }
        val version = header[2].toInt() and 0xff
        if (version != PROTOCOL_VERSION) throw ProtocolException("unsupported protocol version $version")
        val typeId = header[3].toInt() and 0xff
        val length = ((header[4].toInt() and 0xff) shl 24) or
            ((header[5].toInt() and 0xff) shl 16) or
            ((header[6].toInt() and 0xff) shl 8) or
            (header[7].toInt() and 0xff)
        if (length < 0 || length > MAX_PAYLOAD) throw ProtocolException("invalid payload length $length")
        val type = FrameType.fromId(typeId) ?: throw ProtocolException("unknown frame type $typeId")
        val body = ByteArray(length)
        readFully(body, 0, length)
        val c = cipher
        val payload = if (c == null) {
            body
        } else {
            if (length < GCM_TAG_BYTES) throw ProtocolException("sealed payload too short")
            c.open(header, body)
        }
        return Frame(type, payload)
    }

    private fun readFully(buf: ByteArray, off: Int, len: Int) {
        var read = 0
        while (read < len) {
            val n = input.read(buf, off + read, len - read)
            if (n < 0) throw EOFException("stream ended mid-frame")
            read += n
        }
    }
}
