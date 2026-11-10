package app.austial.cast.core.receiver

import app.austial.cast.core.protocol.VideoFrame
import java.util.ArrayDeque

/**
 * Bounded queue between the network thread and the video decoder thread.
 *
 * Latency matters more than completeness for screen mirroring: when the decoder cannot keep up,
 * the whole backlog is discarded and everything is skipped until the next keyframe (which is
 * requested from the sender), instead of letting delay accumulate.
 */
class VideoFrameQueue(private val maxFrames: Int = 6) {
    enum class Offer { ACCEPTED, DROPPED, OVERFLOW }

    private val frames = ArrayDeque<VideoFrame>()
    @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN")
    private val lock = Object()
    private var waitingForKeyframe = true
    @Volatile var droppedTotal = 0L
        private set
    @Volatile private var closed = false

    /** True while non-key frames are being discarded; the caller should ask the sender for a keyframe. */
    val isWaitingForKeyframe: Boolean get() = synchronized(lock) { waitingForKeyframe }
    val size: Int get() = synchronized(lock) { frames.size }

    fun offer(frame: VideoFrame): Offer = synchronized(lock) {
        if (waitingForKeyframe) {
            if (!frame.keyframe) {
                droppedTotal++
                return Offer.DROPPED
            }
            waitingForKeyframe = false
        }
        if (frames.size >= maxFrames && !frame.keyframe) {
            droppedTotal += frames.size + 1
            frames.clear()
            waitingForKeyframe = true
            return Offer.OVERFLOW
        }
        if (frames.size >= maxFrames) {
            // A keyframe resets the picture anyway, so older frames are useless.
            droppedTotal += frames.size
            frames.clear()
        }
        frames.addLast(frame)
        lock.notifyAll()
        Offer.ACCEPTED
    }

    /** Blocks up to [timeoutMs] for the next frame; null on timeout or after [close]. */
    fun poll(timeoutMs: Long): VideoFrame? = synchronized(lock) {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        while (frames.isEmpty() && !closed) {
            val remaining = (deadline - System.nanoTime()) / 1_000_000
            if (remaining <= 0) return null
            lock.wait(remaining)
        }
        frames.pollFirst()
    }

    /** Called when the decoder was (re)started: wait for a fresh keyframe. */
    fun reset() = synchronized(lock) {
        frames.clear()
        waitingForKeyframe = true
    }

    fun markNeedsKeyframe() = synchronized(lock) {
        frames.clear()
        waitingForKeyframe = true
    }

    fun close() = synchronized(lock) {
        closed = true
        lock.notifyAll()
    }
}

/**
 * Maps sender timestamps to local render times with a small jitter buffer.
 *
 * It tracks the smallest observed (arrival - pts) offset, i.e. the "fastest path", and schedules every
 * frame at pts + offset + [bufferNs]. Frames that arrive later than that simply render immediately.
 * With a buffer of 0 the clock is disabled and frames render as soon as they are decoded.
 */
class PlayoutClock(var bufferNs: Long, private val windowNs: Long = 10_000_000_000L) {
    private var minOffset = Long.MAX_VALUE
    private var minOffsetAt = 0L

    /** Returns the System.nanoTime() at which to render, or 0 to render immediately. */
    fun renderTimeNs(ptsUs: Long, arrivalNs: Long): Long {
        if (bufferNs <= 0) return 0
        val offset = arrivalNs - ptsUs * 1000
        if (offset < minOffset || arrivalNs - minOffsetAt > windowNs) {
            // Re-learn periodically so the clock can follow slow drift between the two machines.
            minOffset = offset
            minOffsetAt = arrivalNs
        }
        val target = ptsUs * 1000 + minOffset + bufferNs
        // Never schedule far in the future (e.g. after a pts discontinuity): cap at the buffer size + slack.
        val maxAhead = arrivalNs + bufferNs * 3
        return if (target > maxAhead) maxAhead else target
    }

    fun reset() {
        minOffset = Long.MAX_VALUE
        minOffsetAt = 0
    }
}

/** Calculates the receiver-side decode/display rate for STATS reports. */
class DecodeCounter(private val clock: () -> Long = System::currentTimeMillis) {
    private val rate = RollingRate(2000, clock)
    @Volatile var decoded = 0L
        private set

    fun onDecoded() {
        decoded++
        rate.add(0)
    }

    fun fps(): Double = rate.perSecond()
    fun reset() {
        decoded = 0
        rate.reset()
    }
}
