package app.austial.cast.core.protocol

import java.nio.ByteBuffer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** JSON control messages. Field names are part of the wire format (see docs/PROTOCOL.md). */
@Serializable
data class Hello(
    val protocol: Int = PROTOCOL_VERSION,
    val deviceId: String,
    val name: String,
    val platform: String,
    val appVersion: String,
    /** Base64 ANSI X9.63 P-256 ephemeral public key. */
    val publicKey: String,
)

@Serializable
data class Challenge(
    val protocol: Int = PROTOCOL_VERSION,
    val deviceId: String,
    val name: String,
    val publicKey: String,
    /** True if the receiver already holds a pairing token for the sender's deviceId. */
    val trusted: Boolean,
    val maxWidth: Int,
    val maxHeight: Int,
    val maxFps: Int,
)

@Serializable
data class Auth(
    /** "pin" or "token". */
    val mode: String,
    /** Hex HMAC-SHA256 proof. */
    val proof: String,
)

@Serializable
data class AuthResult(
    val ok: Boolean,
    /** Hex server proof so the sender can verify the receiver knows the secret. */
    val proof: String? = null,
    /** Hex pairing token, issued after a successful PIN authentication. */
    val token: String? = null,
    val reason: String? = null,
    val message: String? = null,
    /** True if the sender may try another AUTH on this connection. */
    val retry: Boolean? = null,
)

@Serializable
data class AudioInfo(
    val codec: String = "aac",
    val sampleRate: Int,
    val channels: Int,
    /** Hex AudioSpecificConfig. */
    val config: String,
)

@Serializable
data class StreamStart(
    val width: Int,
    val height: Int,
    val fps: Int,
    val bitrate: Int,
    val codec: String = "h264",
    val audio: AudioInfo? = null,
    val title: String? = null,
)

@Serializable
data class Control(
    val cmd: String,
    val bitrate: Int? = null,
    val message: String? = null,
)

@Serializable
data class StatsReport(
    val fps: Double,
    val decoded: Long,
    val dropped: Long,
    val bufferMs: Int? = null,
)

@Serializable
data class Bye(
    val reason: String,
    val message: String? = null,
)

object ControlCommand {
    const val PAUSE = "pause"
    const val RESUME = "resume"
    const val REQUEST_KEYFRAME = "requestKeyframe"
    const val SET_BITRATE = "setBitrate"
    const val STOP = "stop"
}

object ByeReason {
    const val USER = "user"
    const val BUSY = "busy"
    const val TIMEOUT = "timeout"
    const val ERROR = "error"
    const val REJECTED = "rejected"
    const val REPLACED = "replaced"
}

object AuthFailure {
    const val BAD_PIN = "bad_pin"
    const val BAD_TOKEN = "bad_token"
    const val LOCKED = "locked"
    const val UNEXPECTED = "unexpected"
}

val ProtocolJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
}

inline fun <reified T> encodeMessage(value: T): ByteArray =
    ProtocolJson.encodeToString(kotlinx.serialization.serializer<T>(), value).toByteArray(Charsets.UTF_8)

inline fun <reified T> decodeMessage(bytes: ByteArray): T = try {
    ProtocolJson.decodeFromString(kotlinx.serialization.serializer<T>(), String(bytes, Charsets.UTF_8))
} catch (e: kotlinx.serialization.SerializationException) {
    throw ProtocolException("malformed ${T::class.simpleName} message", e)
} catch (e: IllegalArgumentException) {
    throw ProtocolException("malformed ${T::class.simpleName} message", e)
}

/** A decoded VIDEO_FRAME payload: flags(1) | pts_us(8, BE) | Annex-B access unit. */
class VideoFrame(val keyframe: Boolean, val ptsUs: Long, val data: ByteArray)

/** A decoded AUDIO_FRAME payload: pts_us(8, BE) | raw AAC-LC access unit. */
class AudioFrame(val ptsUs: Long, val data: ByteArray)

object MediaPayload {
    private const val FLAG_KEYFRAME = 0x01

    fun encodeVideo(frame: VideoFrame): ByteArray {
        val buf = ByteBuffer.allocate(9 + frame.data.size)
        buf.put(if (frame.keyframe) FLAG_KEYFRAME.toByte() else 0)
        buf.putLong(frame.ptsUs)
        buf.put(frame.data)
        return buf.array()
    }

    fun decodeVideo(payload: ByteArray): VideoFrame {
        if (payload.size < 9) throw ProtocolException("video frame too short")
        val buf = ByteBuffer.wrap(payload)
        val flags = buf.get().toInt()
        val pts = buf.getLong()
        return VideoFrame((flags and FLAG_KEYFRAME) != 0, pts, payload.copyOfRange(9, payload.size))
    }

    fun encodeAudio(frame: AudioFrame): ByteArray {
        val buf = ByteBuffer.allocate(8 + frame.data.size)
        buf.putLong(frame.ptsUs)
        buf.put(frame.data)
        return buf.array()
    }

    fun decodeAudio(payload: ByteArray): AudioFrame {
        if (payload.size < 8) throw ProtocolException("audio frame too short")
        val buf = ByteBuffer.wrap(payload)
        return AudioFrame(buf.getLong(), payload.copyOfRange(8, payload.size))
    }
}
