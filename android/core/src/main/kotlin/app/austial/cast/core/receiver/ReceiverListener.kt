package app.austial.cast.core.receiver

import app.austial.cast.core.protocol.AudioFrame
import app.austial.cast.core.protocol.StreamStart
import app.austial.cast.core.protocol.VideoFrame

/** Identity of the connected sender. */
data class PeerInfo(
    val deviceId: String,
    val name: String,
    val platform: String,
    val remoteAddress: String,
)

enum class EndReason { SENDER_STOPPED, DISCONNECTED, TIMEOUT, ERROR, KICKED, REPLACED }

/**
 * Receiver events. Callbacks are invoked on connection threads (never the Android main thread), and
 * media callbacks must return quickly: queue the data for a decoder rather than decoding inline.
 */
interface ReceiverListener {
    fun onListening(port: Int) {}
    fun onPinChanged(pin: String) {}

    /** A sender opened a connection and sent its HELLO; authentication is in progress. */
    fun onPeerConnecting(peer: PeerInfo) {}
    fun onAuthenticated(peer: PeerInfo, viaToken: Boolean) {}
    fun onAuthFailed(peer: PeerInfo?, reason: String) {}

    fun onStreamStarted(peer: PeerInfo, info: StreamStart) {}
    fun onVideoConfig(config: ByteArray) {}
    fun onVideoFrame(frame: VideoFrame) {}
    fun onAudioFrame(frame: AudioFrame) {}
    fun onPaused(paused: Boolean) {}
    fun onStreamEnded(peer: PeerInfo, reason: EndReason) {}

    /** A connection ended before a stream started (auth failed, busy, closed). */
    fun onConnectionClosed(peer: PeerInfo?, reason: EndReason) {}
    fun onError(error: Throwable) {}
}
