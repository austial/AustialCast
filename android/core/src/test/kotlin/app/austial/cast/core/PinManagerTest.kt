package app.austial.cast.core

import app.austial.cast.core.receiver.InMemoryTrustStore
import app.austial.cast.core.receiver.PinManager
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PinManagerTest {
    private var now = 1_000_000L
    private val seen = ArrayList<String>()
    private fun manager(max: Int = 3) = PinManager(clock = { now }, maxFailures = max, onChange = { seen.add(it) })

    @Test
    fun pinsAreSixDigits() {
        val m = manager()
        repeat(200) {
            val pin = m.rotate()
            assertEquals(6, pin.length)
            assertTrue(pin.all { it.isDigit() })
        }
    }

    @Test
    fun everyAttemptRotatesThePin() {
        val m = manager()
        val before = m.current
        var rotations = 0
        repeat(20) {
            val prev = m.current
            m.attemptFinished("1.2.3.4", it % 2 == 0)
            if (m.current != prev) rotations++
        }
        assertTrue(rotations >= 19, "pin should change on (almost) every attempt, changed $rotations/20 times")
        assertEquals(20, seen.size)
        assertNotEquals(before, "")
    }

    @Test
    fun locksOutAfterRepeatedFailuresAndUnlocksLater() {
        val m = manager(max = 3)
        repeat(2) { m.attemptFinished("a", false) }
        assertFalse(m.isLocked("a"))
        m.attemptFinished("a", false)
        assertTrue(m.isLocked("a"))
        assertTrue(m.lockRemainingMs("a") in 1..60_000)
        assertFalse(m.isLocked("b"), "other addresses are unaffected")
        now += 61_000
        assertFalse(m.isLocked("a"))
    }

    @Test
    fun failuresOutsideTheWindowDoNotAccumulate() {
        val m = manager(max = 3)
        m.attemptFinished("a", false)
        m.attemptFinished("a", false)
        now += 61_000
        m.attemptFinished("a", false)
        assertFalse(m.isLocked("a"))
    }

    @Test
    fun successClearsFailureCount() {
        val m = manager(max = 3)
        m.attemptFinished("a", false)
        m.attemptFinished("a", false)
        m.attemptFinished("a", true)
        m.attemptFinished("a", false)
        m.attemptFinished("a", false)
        assertFalse(m.isLocked("a"))
    }

    @Test
    fun fixedPinStaysFixed() {
        val m = PinManager(fixedPin = "424242")
        m.attemptFinished("a", false)
        assertEquals("424242", m.current)
    }

    @Test
    fun trustStoreCrud() {
        val s = InMemoryTrustStore()
        assertNull(s.get("x"))
        s.put("b", "Beta", byteArrayOf(1))
        s.put("a", "Alpha", byteArrayOf(2))
        assertContentEquals(byteArrayOf(2), s.get("a"))
        assertEquals(listOf("Alpha", "Beta"), s.list().map { it.name })
        s.remove("a")
        assertNull(s.get("a"))
        s.clear()
        assertEquals(0, s.list().size)
    }

    @Test
    fun tokensAreRandom() {
        assertEquals(32, PinManager.newToken().size)
        assertNotEquals(PinManager.newToken().toList(), PinManager.newToken().toList())
    }
}
