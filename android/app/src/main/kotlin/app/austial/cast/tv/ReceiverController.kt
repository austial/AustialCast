package app.austial.cast.tv

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import app.austial.cast.core.protocol.AnnexB
import app.austial.cast.core.protocol.AudioFrame
import app.austial.cast.core.protocol.Crypto
import app.austial.cast.core.protocol.DEFAULT_PORT
import app.austial.cast.core.protocol.StatsReport
import app.austial.cast.core.protocol.StreamStart
import app.austial.cast.core.protocol.VideoFrame
import app.austial.cast.core.receiver.DecodeCounter
import app.austial.cast.core.receiver.EndReason
import app.austial.cast.core.receiver.KvTrustStore
import app.austial.cast.core.receiver.NetUtil
import app.austial.cast.core.receiver.PeerInfo
import app.austial.cast.core.receiver.PinManager
import app.austial.cast.core.receiver.PlayoutClock
import app.austial.cast.core.receiver.ReceiverConfig
import app.austial.cast.core.receiver.ReceiverListener
import app.austial.cast.core.receiver.ReceiverServer
import app.austial.cast.core.receiver.StreamStats
import app.austial.cast.core.receiver.UiModel
import app.austial.cast.core.receiver.UiState
import app.austial.cast.core.receiver.formatStats
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Glue between the protocol server (core) and Android: owns the server, mDNS advertisement,
 * decoders and the UI state. One instance lives in the Application.
 */
class ReceiverController(private val context: Context, val settings: TvSettings) : ReceiverListener {
    interface Observer {
        fun onUiState(state: UiState)
        fun onStatsText(text: String)
        fun onAddress(address: String)
    }

    private val main = Handler(Looper.getMainLooper())
    private val observers = CopyOnWriteArrayList<Observer>()
    private val trustStore = KvTrustStore(settings.keyValueStore)
    private val ui = UiModel(settings.deviceName, "")
    private val stats = StreamStats()
    private val decodeCounter = DecodeCounter()
    private val nsd = NsdAdvertiser(context)
    private var server: ReceiverServer? = null
    private var scheduler: ScheduledExecutorService? = null

    private val lock = Any()
    private var surface: Surface? = null
    private var video: VideoDecoder? = null
    private var audio: AudioPlayer? = null
    private var streamInfo: StreamStart? = null
    private var paramSets: AnnexB.ParameterSets? = null
    private var lastConfig: ByteArray? = null
    private var clock = PlayoutClock(0)

    val trusted get() = trustStore
    val state: UiState get() = ui.state
    @Volatile var port: Int = DEFAULT_PORT
        private set
    @Volatile var address: String = ""
        private set
    @Volatile var statsVisible = false

    fun addObserver(o: Observer) {
        observers.add(o)
        o.onUiState(ui.state)
        o.onAddress(addressLine())
    }

    fun removeObserver(o: Observer) {
        observers.remove(o)
    }

    // ---- lifecycle ----------------------------------------------------------------------

    @Synchronized
    fun start() {
        if (server != null) return
        val s = ReceiverServer(buildConfig(), trustStore, this, PinManager(onChange = {}))
        try {
            s.start()
        } catch (e: Exception) {
            Log.e(TAG, "cannot listen", e)
            // Port in use: fall back to an ephemeral port so the TV still works with discovery.
            s.config = s.config.copy(port = 0)
            try { s.start() } catch (e2: Exception) {
                post { ui.clearNotice(); notify(ui.state.copy(notice = "Cannot start the receiver: ${e2.message}")) }
                return
            }
        }
        server = s
        port = s.port
        address = NetUtil.bestLocalAddress() ?: ""
        ui.onPinChanged(s.currentPin)
        ui.onDeviceNameChanged(settings.deviceName)
        nsd.register(settings.deviceName, settings.deviceId, port)
        scheduler = Executors.newSingleThreadScheduledExecutor().also {
            it.scheduleWithFixedDelay({ tick() }, 1, 1, TimeUnit.SECONDS)
        }
        post {
            notify(ui.state)
            observers.forEach { o -> o.onAddress(addressLine()) }
        }
    }

    @Synchronized
    fun stop() {
        scheduler?.shutdownNow()
        scheduler = null
        nsd.unregister()
        server?.stop()
        server = null
        stopMedia()
    }

    /** Applies changed settings (name, trust, takeover) to the running server. */
    fun applySettings() {
        val s = server ?: return
        s.config = buildConfig().copy(port = s.config.port)
        ui.onDeviceNameChanged(settings.deviceName)
        nsd.register(settings.deviceName, settings.deviceId, port)
        clock.bufferNs = settings.smoothness.bufferMs * 1_000_000L
        post { notify(ui.state) }
    }

    private fun buildConfig() = ReceiverConfig(
        deviceId = settings.deviceId,
        deviceName = settings.deviceName,
        port = DEFAULT_PORT,
        allowTrustedDevices = settings.rememberDevices,
        allowPreempt = settings.allowTakeover,
        maxWidth = 3840,
        maxHeight = 2160,
        maxFps = 60,
    )

    fun disconnect() {
        server?.disconnectActive()
    }

    fun addressLine(): String = if (address.isNotEmpty()) "$address:$port" else "Connect this TV to Wi-Fi or Ethernet"

    // ---- surface handling ----------------------------------------------------------------

    fun setSurface(s: Surface?) {
        synchronized(lock) {
            surface = s
            if (s == null) {
                video?.stop(); video = null
            } else {
                startVideoLocked()
            }
        }
    }

    private fun startVideoLocked() {
        val s = surface ?: return
        val info = streamInfo ?: return
        val ps = paramSets ?: return
        if (video != null) return
        clock = PlayoutClock(settings.smoothness.bufferMs * 1_000_000L)
        decodeCounter.reset()
        val decoder = VideoDecoder(s, info.width, info.height, ps, clock, decodeCounter,
            onNeedKeyframe = { server?.requestKeyframe() },
            onError = { e -> Log.e(TAG, "video error", e); post { notify(ui.state.copy(notice = "Video decoder error: ${e.message}")) } })
        // Publish the decoder before starting it: codec start-up can take a few hundred ms and the frames
        // arriving meanwhile (notably the first keyframe) are queued instead of being lost.
        video = decoder
        try {
            decoder.start()
        } catch (e: Exception) {
            Log.e(TAG, "cannot start video decoder", e)
            video = null
            post { notify(ui.state.copy(notice = "This TV cannot decode the video: ${e.message}")) }
        }
    }

    private fun stopMedia() {
        synchronized(lock) {
            video?.stop(); video = null
            audio?.stop(); audio = null
            streamInfo = null
            paramSets = null
            lastConfig = null
        }
    }

    // ---- ReceiverListener (called on connection threads) ---------------------------------

    override fun onPinChanged(pin: String) = post { notify(ui.onPinChanged(pin)) }

    override fun onPeerConnecting(peer: PeerInfo) = post { notify(ui.onPeerConnecting(peer)) }

    override fun onAuthFailed(peer: PeerInfo?, reason: String) = post { notify(ui.onAuthFailed(reason)) }

    override fun onStreamStarted(peer: PeerInfo, info: StreamStart) {
        stats.reset()
        stats.width = info.width
        stats.height = info.height
        synchronized(lock) {
            stopMedia()
            streamInfo = info
            info.audio?.let { a ->
                try {
                    audio = AudioPlayer(a.sampleRate, a.channels, Crypto.unhex(a.config)) { e -> Log.e(TAG, "audio error", e) }.also { it.start() }
                } catch (e: Exception) {
                    Log.w(TAG, "audio unavailable", e)
                }
            }
        }
        post { notify(ui.onStreamStarted(peer, info.width, info.height, info.fps, info.audio != null, info.title)) }
    }

    override fun onVideoConfig(config: ByteArray) {
        synchronized(lock) {
            if (lastConfig?.contentEquals(config) == true) return
            val ps = AnnexB.parseParameterSets(config) ?: return
            if (video != null) { video?.stop(); video = null }
            lastConfig = config
            paramSets = ps
            startVideoLocked()
        }
    }

    override fun onVideoFrame(frame: VideoFrame) {
        stats.onVideoFrame(frame.data.size)
        video?.submit(frame)
    }

    override fun onAudioFrame(frame: AudioFrame) {
        audio?.submit(frame)
    }

    override fun onPaused(paused: Boolean) = post { notify(ui.onPaused(paused)) }

    override fun onStreamEnded(peer: PeerInfo, reason: EndReason) {
        stopMedia()
        post { notify(ui.onStreamEnded(reason)) }
    }

    override fun onConnectionClosed(peer: PeerInfo?, reason: EndReason) = post { notify(ui.onConnectionClosed()) }

    override fun onError(error: Throwable) {
        Log.w(TAG, "receiver error", error)
    }

    // ---- periodic work -------------------------------------------------------------------

    private fun tick() {
        val s = server ?: return
        if (s.isStreaming) {
            s.ping()
            stats.rttMs = s.rttMs
            val v = video
            stats.framesDropped = v?.dropped ?: 0
            val snap = stats.snapshot()
            val fps = decodeCounter.fps()
            if (tickCount++ % 2 == 0) {
                s.sendStats(StatsReport(fps = fps, decoded = decodeCounter.decoded, dropped = snap.framesDropped))
            }
            val text = formatStats(snap, fps)
            post { observers.forEach { it.onStatsText(text) } }
        }
        // Refresh the address in case Wi-Fi changed.
        val addr = NetUtil.bestLocalAddress() ?: ""
        if (addr != address) {
            address = addr
            post { observers.forEach { it.onAddress(addressLine()) } }
        }
    }

    private var tickCount = 0

    private fun post(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    private fun notify(state: UiState) {
        observers.forEach { it.onUiState(state) }
    }

    companion object {
        private const val TAG = "AustialCastController"
    }
}
