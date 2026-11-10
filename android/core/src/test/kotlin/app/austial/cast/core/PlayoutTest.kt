package app.austial.cast.core

import app.austial.cast.core.protocol.VideoFrame
import app.austial.cast.core.receiver.DecodeCounter
import app.austial.cast.core.receiver.PlayoutClock
import app.austial.cast.core.receiver.VideoFrameQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PlayoutTest {
    private fun frame(key: Boolean, pts: Long = 0) = VideoFrame(key, pts, byteArrayOf(1))

    @Test
    fun queueWaitsForFirstKeyframe() {
        val q = VideoFrameQueue(4)
        assertTrue(q.isWaitingForKeyframe)
        assertEquals(VideoFrameQueue.Offer.DROPPED, q.offer(frame(false)))
        assertEquals(0, q.size)
        assertEquals(VideoFrameQueue.Offer.ACCEPTED, q.offer(frame(true)))
        assertFalse(q.isWaitingForKeyframe)
        assertEquals(VideoFrameQueue.Offer.ACCEPTED, q.offer(frame(false)))
        assertEquals(2, q.size)
        assertEquals(1, q.droppedTotal)
    }

    @Test
    fun queueDeliversInOrder() {
        val q = VideoFrameQueue(10)
        q.offer(frame(true, 1)); q.offer(frame(false, 2)); q.offer(frame(false, 3))
        assertEquals(listOf(1L, 2L, 3L), List(3) { q.poll(10)!!.ptsUs })
        assertNull(q.poll(10), "empty queue times out")
    }

    @Test
    fun overflowFlushesBacklogAndWaitsForKeyframe() {
        val q = VideoFrameQueue(3)
        q.offer(frame(true)); q.offer(frame(false)); q.offer(frame(false))
        assertEquals(VideoFrameQueue.Offer.OVERFLOW, q.offer(frame(false)))
        assertEquals(0, q.size)
        assertTrue(q.isWaitingForKeyframe)
        assertEquals(4, q.droppedTotal)
        assertEquals(VideoFrameQueue.Offer.DROPPED, q.offer(frame(false)))
        assertEquals(VideoFrameQueue.Offer.ACCEPTED, q.offer(frame(true)))
    }

    @Test
    fun keyframeIntoFullQueueReplacesBacklog() {
        val q = VideoFrameQueue(2)
        q.offer(frame(true, 1)); q.offer(frame(false, 2))
        assertEquals(VideoFrameQueue.Offer.ACCEPTED, q.offer(frame(true, 3)))
        assertEquals(1, q.size)
        assertEquals(3L, q.poll(10)!!.ptsUs)
    }

    @Test
    fun resetRequiresNewKeyframe() {
        val q = VideoFrameQueue(5)
        q.offer(frame(true)); q.reset()
        assertEquals(0, q.size)
        assertEquals(VideoFrameQueue.Offer.DROPPED, q.offer(frame(false)))
    }

    @Test
    fun pollBlocksUntilFrameArrives() {
        val q = VideoFrameQueue(5)
        val got = CountDownLatch(1)
        var received: VideoFrame? = null
        thread { received = q.poll(3000); got.countDown() }
        Thread.sleep(100)
        q.offer(frame(true, 42))
        assertTrue(got.await(2, TimeUnit.SECONDS))
        assertEquals(42L, received?.ptsUs)
    }

    @Test
    fun closeWakesBlockedPoll() {
        val q = VideoFrameQueue(5)
        val done = CountDownLatch(1)
        thread { q.poll(10_000); done.countDown() }
        Thread.sleep(100)
        q.close()
        assertTrue(done.await(2, TimeUnit.SECONDS))
    }

    @Test
    fun playoutClockDisabledWhenNoBuffer() {
        assertEquals(0L, PlayoutClock(0).renderTimeNs(1_000_000, 5_000_000_000))
    }

    @Test
    fun playoutClockSchedulesRelativeToFastestArrival() {
        val c = PlayoutClock(bufferNs = 60_000_000)
        val t0 = 10_000_000_000L
        // pts 0 arrives at t0 -> render at t0 + 60 ms.
        assertEquals(t0 + 60_000_000, c.renderTimeNs(0, t0))
        // 33 ms of video arriving 10 ms late still lands exactly 60 ms after its ideal time.
        assertEquals(t0 + 33_000_000 + 60_000_000, c.renderTimeNs(33_000, t0 + 43_000_000))
        // A faster arrival lowers the baseline, tightening the schedule.
        assertEquals(t0 + 66_000_000 + 60_000_000 - 5_000_000, c.renderTimeNs(66_000, t0 + 61_000_000) + 5_000_000 - 5_000_000 + 0)
    }

    @Test
    fun playoutClockNeverSchedulesFarAhead() {
        val c = PlayoutClock(bufferNs = 50_000_000)
        val t = 1_000_000_000L
        c.renderTimeNs(0, t)
        val target = c.renderTimeNs(60_000_000_000L / 1000, t + 10_000_000) // pts jumps a minute ahead
        assertTrue(target <= t + 10_000_000 + 3 * 50_000_000)
    }

    @Test
    fun playoutClockResets() {
        val c = PlayoutClock(40_000_000)
        c.renderTimeNs(0, 1_000_000_000)
        c.reset()
        assertEquals(5_000_000_000 + 40_000_000, c.renderTimeNs(0, 5_000_000_000))
    }

    @Test
    fun decodeCounterReportsRate() {
        var now = 0L
        val d = DecodeCounter { now }
        repeat(60) { d.onDecoded(); now += 33 }
        assertEquals(60, d.decoded)
        assertEquals(30.0, d.fps(), 1.5)
        d.reset()
        assertEquals(0, d.decoded)
        assertNotNull(d)
    }
}
