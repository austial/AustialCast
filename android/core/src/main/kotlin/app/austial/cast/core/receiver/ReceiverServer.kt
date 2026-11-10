package app.austial.cast.core.receiver

import app.austial.cast.core.protocol.ByeReason
import app.austial.cast.core.protocol.Control
import app.austial.cast.core.protocol.ControlCommand
import app.austial.cast.core.protocol.DEFAULT_PORT
import app.austial.cast.core.protocol.FrameType
import app.austial.cast.core.protocol.StatsReport
import app.austial.cast.core.protocol.encodeMessage
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

data class ReceiverConfig(
    val deviceId: String,
    val deviceName: String,
    /** TCP port; 0 picks a free port (see [ReceiverServer.port]). */
    val port: Int = DEFAULT_PORT,
    /** If false, pairing tokens are neither issued nor accepted: every session needs the PIN. */
    val allowTrustedDevices: Boolean = true,
    /** If true a new authenticated sender replaces the active one instead of being rejected as busy. */
    val allowPreempt: Boolean = false,
    val maxWidth: Int = 3840,
    val maxHeight: Int = 2160,
    val maxFps: Int = 60,
    val handshakeTimeoutMs: Int = 10_000,
    val idleTimeoutMs: Int = 10_000,
    val maxPendingConnections: Int = 4,
    val bindAddress: InetAddress? = null,
)

/**
 * Accepts AustialCast senders over TCP, authenticates them and forwards the media to a
 * [ReceiverListener]. One authenticated sender may stream at a time.
 */
class ReceiverServer(
    @Volatile var config: ReceiverConfig,
    internal val trustStore: TrustStore,
    internal val listener: ReceiverListener,
    internal val pins: PinManager = PinManager(),
) {
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
    private val executor = Executors.newCachedThreadPool { r -> Thread(r, "austialcast-session").also { it.isDaemon = true } }
    internal val pending = AtomicInteger(0)
    private val lock = Any()
    private var active: ReceiverSession? = null

    /** The bound TCP port; valid after [start]. */
    val port: Int get() = serverSocket?.localPort ?: -1

    val currentPin: String get() = pins.current

    val isStreaming: Boolean get() = synchronized(lock) { active != null }

    fun start() {
        synchronized(lock) {
            check(serverSocket == null) { "already started" }
            val cfg = config
            val ss = ServerSocket()
            ss.reuseAddress = true
            ss.bind(InetSocketAddress(cfg.bindAddress, cfg.port))
            serverSocket = ss
            acceptThread = Thread({ acceptLoop(ss) }, "austialcast-accept").also {
                it.isDaemon = true
                it.start()
            }
        }
        listener.onListening(port)
    }

    fun stop() {
        val ss: ServerSocket?
        val session: ReceiverSession?
        synchronized(lock) {
            ss = serverSocket
            serverSocket = null
            session = active
        }
        try {
            ss?.close()
        } catch (_: IOException) {
        }
        session?.terminate(EndReason.KICKED, ByeReason.USER)
        executor.shutdownNow()
    }

    /** Disconnects the active sender, if any. */
    fun disconnectActive() {
        synchronized(lock) { active }?.terminate(EndReason.KICKED, ByeReason.USER)
    }

    /** Asks the sender to emit a keyframe (needed after decoder start or errors). */
    fun requestKeyframe() = sendControl(Control(ControlCommand.REQUEST_KEYFRAME))

    fun requestBitrate(bitrate: Int) = sendControl(Control(ControlCommand.SET_BITRATE, bitrate = bitrate))

    fun sendControl(control: Control) {
        synchronized(lock) { active }?.send(FrameType.CONTROL, encodeMessage(control))
    }

    fun sendStats(report: StatsReport) {
        synchronized(lock) { active }?.send(FrameType.STATS, encodeMessage(report))
    }

    /** Sends a PING so the receiver can measure RTT (read it back with [rttMs]). */
    fun ping() {
        val payload = java.nio.ByteBuffer.allocate(8).putLong(System.nanoTime() / 1000).array()
        synchronized(lock) { active }?.send(FrameType.PING, payload)
    }

    val rttMs: Long? get() = synchronized(lock) { active }?.lastRttMs

    private fun acceptLoop(ss: ServerSocket) {
        while (!ss.isClosed) {
            val socket = try {
                ss.accept()
            } catch (e: IOException) {
                if (!ss.isClosed) listener.onError(e)
                return
            }
            if (pending.incrementAndGet() > config.maxPendingConnections) {
                pending.decrementAndGet()
                try {
                    socket.close()
                } catch (_: IOException) {
                }
                continue
            }
            try {
                executor.execute(ReceiverSession(socket, this))
            } catch (e: Exception) {
                pending.decrementAndGet()
                try {
                    socket.close()
                } catch (_: IOException) {
                }
            }
        }
    }

    /**
     * Called by a session once it authenticated. Returns false if the receiver is busy and the
     * session must be rejected.
     */
    internal fun claimActive(session: ReceiverSession): Boolean {
        val previous: ReceiverSession?
        synchronized(lock) {
            previous = active
            if (previous != null && !config.allowPreempt) return false
        }
        previous?.terminate(EndReason.REPLACED, ByeReason.REPLACED)
        previous?.awaitFinished(2000)
        synchronized(lock) {
            if (active != null) return false
            active = session
        }
        return true
    }

    internal fun release(session: ReceiverSession) {
        synchronized(lock) {
            if (active === session) active = null
        }
    }

    companion object {
        internal fun closeQuietly(socket: Socket) {
            try {
                socket.close()
            } catch (_: IOException) {
            }
        }
    }
}
