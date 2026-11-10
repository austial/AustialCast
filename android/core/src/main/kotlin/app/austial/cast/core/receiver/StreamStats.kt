package app.austial.cast.core.receiver

/** Sliding-window counter producing per-second rates. Thread safe. */
class RollingRate(private val windowMs: Long = 2000, private val clock: () -> Long = System::currentTimeMillis) {
    private val times = ArrayDeque<Long>()
    private val sizes = ArrayDeque<Int>()
    private var bytesInWindow = 0L

    @Synchronized
    fun add(size: Int) {
        val now = clock()
        times.addLast(now)
        sizes.addLast(size)
        bytesInWindow += size
        trim(now)
    }

    private fun trim(now: Long) {
        while (times.isNotEmpty() && now - times.first() > windowMs) {
            times.removeFirst()
            bytesInWindow -= sizes.removeFirst()
        }
    }

    @Synchronized
    fun perSecond(): Double {
        trim(clock())
        return times.size * 1000.0 / windowMs
    }

    @Synchronized
    fun bytesPerSecond(): Double {
        trim(clock())
        return bytesInWindow * 1000.0 / windowMs
    }

    @Synchronized
    fun reset() {
        times.clear()
        sizes.clear()
        bytesInWindow = 0
    }
}

/** Snapshot shown in the on-screen statistics overlay. */
data class StatsSnapshot(
    val fps: Double,
    val bitrateKbps: Double,
    val framesReceived: Long,
    val framesDropped: Long,
    val rttMs: Long?,
    val width: Int,
    val height: Int,
)

class StreamStats(private val clock: () -> Long = System::currentTimeMillis) {
    private val frames = RollingRate(2000, clock)
    @Volatile var framesReceived = 0L; private set
    @Volatile var framesDropped = 0L
    @Volatile var rttMs: Long? = null
    @Volatile var width = 0
    @Volatile var height = 0

    fun onVideoFrame(bytes: Int) {
        framesReceived++
        frames.add(bytes)
    }

    fun onDropped(count: Int = 1) {
        framesDropped += count
    }

    fun reset() {
        frames.reset()
        framesReceived = 0
        framesDropped = 0
        rttMs = null
    }

    fun snapshot() = StatsSnapshot(
        fps = frames.perSecond(),
        bitrateKbps = frames.bytesPerSecond() * 8 / 1000.0,
        framesReceived = framesReceived,
        framesDropped = framesDropped,
        rttMs = rttMs,
        width = width,
        height = height,
    )
}
