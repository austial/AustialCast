package app.austial.cast.core.receiver

/** What the TV screen is currently showing. */
enum class Phase { IDLE, CONNECTING, STREAMING, PAUSED }

data class UiState(
    val phase: Phase = Phase.IDLE,
    val pin: String = "",
    val deviceName: String = "",
    val peerName: String? = null,
    val width: Int = 0,
    val height: Int = 0,
    val fps: Int = 0,
    /** One-off message such as "Wrong PIN" or "Cast ended"; cleared by the next state change. */
    val notice: String? = null,
    val hasAudio: Boolean = false,
    val title: String? = null,
)

/**
 * Pure state machine turning receiver events into UI state, so the logic is unit-testable without
 * Android. The Android layer renders [state] and forwards events here.
 */
class UiModel(deviceName: String = "", pin: String = "") {
    var state = UiState(deviceName = deviceName, pin = pin)
        private set

    fun onPinChanged(pin: String): UiState = update { copy(pin = pin) }

    fun onDeviceNameChanged(name: String): UiState = update { copy(deviceName = name) }

    fun onPeerConnecting(peer: PeerInfo): UiState =
        update { if (phase == Phase.IDLE || phase == Phase.CONNECTING) copy(phase = Phase.CONNECTING, peerName = peer.name, notice = null) else this }

    fun onAuthFailed(reason: String): UiState = update {
        val message = when (reason) {
            "bad_pin" -> "Wrong PIN entered on ${peerName ?: "a device"}. A new PIN is shown."
            "bad_token" -> "${peerName ?: "A device"} needs to pair again."
            "locked" -> "Too many wrong PINs. Pairing is locked for a minute."
            "busy" -> "${peerName ?: "A device"} tried to cast while another cast is active."
            else -> "Connection refused ($reason)"
        }
        if (phase == Phase.STREAMING || phase == Phase.PAUSED) copy(notice = message)
        else copy(phase = Phase.IDLE, peerName = null, notice = message)
    }

    fun onStreamStarted(peer: PeerInfo, width: Int, height: Int, fps: Int, hasAudio: Boolean, title: String?): UiState =
        update { copy(phase = Phase.STREAMING, peerName = peer.name, width = width, height = height, fps = fps, hasAudio = hasAudio, title = title, notice = null) }

    fun onPaused(paused: Boolean): UiState =
        update { if (phase == Phase.STREAMING || phase == Phase.PAUSED) copy(phase = if (paused) Phase.PAUSED else Phase.STREAMING) else this }

    fun onStreamEnded(reason: EndReason): UiState = update {
        val who = peerName ?: "The sender"
        val message = when (reason) {
            EndReason.SENDER_STOPPED -> "$who stopped casting"
            EndReason.DISCONNECTED -> "Lost connection to $who"
            EndReason.TIMEOUT -> "$who stopped responding"
            EndReason.KICKED -> null
            EndReason.REPLACED -> "$who was replaced by another cast"
            EndReason.ERROR -> "The cast ended because of an error"
        }
        copy(phase = Phase.IDLE, peerName = null, width = 0, height = 0, fps = 0, hasAudio = false, title = null, notice = message)
    }

    /** A connection ended before any stream started. */
    fun onConnectionClosed(): UiState = update { if (phase == Phase.CONNECTING) copy(phase = Phase.IDLE, peerName = null) else this }

    fun clearNotice(): UiState = update { copy(notice = null) }

    private inline fun update(f: UiState.() -> UiState): UiState {
        state = state.f()
        return state
    }
}

/** "123456" -> "123 456" for easier reading from across the room. */
fun formatPin(pin: String): String = if (pin.length == 6) pin.substring(0, 3) + " " + pin.substring(3) else pin

fun formatStats(s: StatsSnapshot, decodedFps: Double): String {
    val res = if (s.width > 0) "${s.width}×${s.height}" else "—"
    val mbps = "%.1f".format(s.bitrateKbps / 1000.0)
    val rtt = s.rttMs?.let { "$it ms" } ?: "—"
    return "$res   ${"%.0f".format(decodedFps)} fps   $mbps Mbit/s   ping $rtt   dropped ${s.framesDropped}"
}
