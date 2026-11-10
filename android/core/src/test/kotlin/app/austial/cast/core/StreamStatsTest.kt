package app.austial.cast.core

import app.austial.cast.core.receiver.RollingRate
import app.austial.cast.core.receiver.StreamStats
import kotlin.test.Test
import kotlin.test.assertEquals

class StreamStatsTest {
    private var now = 0L

    @Test
    fun computesRatesOverTheWindow() {
        val r = RollingRate(2000) { now }
        repeat(60) {
            r.add(1000)
            now += 33
        }
        assertEquals(30.0, r.perSecond(), 1.0)
        assertEquals(30_000.0, r.bytesPerSecond(), 1000.0)
    }

    @Test
    fun oldSamplesExpire() {
        val r = RollingRate(2000) { now }
        repeat(10) { r.add(10) }
        now += 2500
        assertEquals(0.0, r.perSecond())
        assertEquals(0.0, r.bytesPerSecond())
    }

    @Test
    fun snapshotReflectsCounters() {
        val s = StreamStats { now }
        s.width = 1920; s.height = 1080
        repeat(30) { s.onVideoFrame(12_500); now += 33 }
        s.onDropped(2)
        s.rttMs = 7
        val snap = s.snapshot()
        assertEquals(30, snap.framesReceived)
        assertEquals(2, snap.framesDropped)
        assertEquals(7L, snap.rttMs)
        assertEquals(1920, snap.width)
        assertEquals(15.0, snap.fps, 1.0)
        s.reset()
        assertEquals(0, s.snapshot().framesReceived)
    }
}
