package app.austial.cast.core

import app.austial.cast.core.receiver.EndReason
import app.austial.cast.core.receiver.InMemoryTrustStore
import app.austial.cast.core.receiver.KvTrustStore
import app.austial.cast.core.receiver.LocalAddress
import app.austial.cast.core.receiver.MapKeyValueStore
import app.austial.cast.core.receiver.NetUtil
import app.austial.cast.core.receiver.PeerInfo
import app.austial.cast.core.receiver.Phase
import app.austial.cast.core.receiver.StatsSnapshot
import app.austial.cast.core.receiver.UiModel
import app.austial.cast.core.receiver.formatPin
import app.austial.cast.core.receiver.formatStats
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class UiModelTest {
    private val peer = PeerInfo("mac-1", "My MacBook", "macos", "192.168.1.5")

    @Test
    fun startsIdleWithPin() {
        val m = UiModel("Living Room", "123456")
        assertEquals(Phase.IDLE, m.state.phase)
        assertEquals("123456", m.state.pin)
        assertEquals("Living Room", m.state.deviceName)
    }

    @Test
    fun fullCastLifecycle() {
        val m = UiModel("TV", "111111")
        assertEquals(Phase.CONNECTING, m.onPeerConnecting(peer).phase)
        assertEquals("My MacBook", m.state.peerName)
        val s = m.onStreamStarted(peer, 1920, 1080, 30, true, "Display 1")
        assertEquals(Phase.STREAMING, s.phase)
        assertEquals(1920, s.width)
        assertEquals("Display 1", s.title)
        assertEquals(Phase.PAUSED, m.onPaused(true).phase)
        assertEquals(Phase.STREAMING, m.onPaused(false).phase)
        val end = m.onStreamEnded(EndReason.SENDER_STOPPED)
        assertEquals(Phase.IDLE, end.phase)
        assertEquals("My MacBook stopped casting", end.notice)
        assertNull(end.peerName)
        assertEquals(0, end.width)
    }

    @Test
    fun wrongPinReturnsToIdleWithNotice() {
        val m = UiModel("TV", "111111")
        m.onPeerConnecting(peer)
        val s = m.onAuthFailed("bad_pin")
        assertEquals(Phase.IDLE, s.phase)
        assertTrue(s.notice!!.contains("Wrong PIN"))
        assertNull(s.peerName)
    }

    @Test
    fun failedAuthOfAnotherDeviceDoesNotInterruptActiveCast() {
        val m = UiModel("TV", "1")
        m.onPeerConnecting(peer)
        m.onStreamStarted(peer, 1280, 720, 30, false, null)
        val s = m.onAuthFailed("busy")
        assertEquals(Phase.STREAMING, s.phase)
        assertNotNull(s.notice)
    }

    @Test
    fun secondPeerCannotHijackStreamingUi() {
        val m = UiModel("TV", "1")
        m.onPeerConnecting(peer)
        m.onStreamStarted(peer, 1280, 720, 30, false, null)
        m.onPeerConnecting(PeerInfo("x", "Intruder", "macos", "1.1.1.1"))
        assertEquals("My MacBook", m.state.peerName)
    }

    @Test
    fun kickedByUserShowsNoNotice() {
        val m = UiModel("TV", "1")
        m.onStreamStarted(peer, 1280, 720, 30, false, null)
        assertNull(m.onStreamEnded(EndReason.KICKED).notice)
    }

    @Test
    fun endReasonsHaveReadableMessages() {
        for (r in EndReason.entries) {
            val m = UiModel("TV", "1")
            m.onStreamStarted(peer, 1280, 720, 30, false, null)
            val s = m.onStreamEnded(r)
            if (r != EndReason.KICKED) assertNotNull(s.notice, "$r")
        }
    }

    @Test
    fun closedConnectionWhileConnectingReturnsToIdle() {
        val m = UiModel("TV", "1")
        m.onPeerConnecting(peer)
        assertEquals(Phase.IDLE, m.onConnectionClosed().phase)
    }

    @Test
    fun pinAndNameUpdates() {
        val m = UiModel("TV", "1")
        assertEquals("222222", m.onPinChanged("222222").pin)
        assertEquals("Bedroom", m.onDeviceNameChanged("Bedroom").deviceName)
        m.onAuthFailed("bad_pin")
        assertNull(m.clearNotice().notice)
    }

    @Test
    fun formatting() {
        assertEquals("123 456", formatPin("123456"))
        assertEquals("12", formatPin("12"))
        val s = StatsSnapshot(29.7, 6200.0, 100, 3, 8, 1920, 1080)
        assertEquals("1920×1080   30 fps   6.2 Mbit/s   ping 8 ms   dropped 3", formatStats(s, 29.7))
        assertTrue(formatStats(StatsSnapshot(0.0, 0.0, 0, 0, null, 0, 0), 0.0).contains("—"))
    }
}

class KvTrustStoreTest {
    @Test
    fun persistsAcrossInstances() {
        val kv = MapKeyValueStore()
        KvTrustStore(kv).put("mac-1", "My MacBook", byteArrayOf(1, 2, 3))
        val again = KvTrustStore(kv)
        assertContentEquals(byteArrayOf(1, 2, 3), again.get("mac-1"))
        assertEquals(listOf("My MacBook"), again.list().map { it.name })
    }

    @Test
    fun replaceRemoveAndClear() {
        val s = KvTrustStore(MapKeyValueStore())
        s.put("a", "A", byteArrayOf(1)); s.put("b", "B", byteArrayOf(2)); s.put("a", "A2", byteArrayOf(3))
        assertContentEquals(byteArrayOf(3), s.get("a"))
        assertEquals(listOf("A2", "B"), s.list().map { it.name })
        s.remove("a")
        assertNull(s.get("a"))
        s.clear()
        assertEquals(0, s.list().size)
    }

    @Test
    fun hostileIdsAndNamesCannotBreakTheFormat() {
        val s = KvTrustStore(MapKeyValueStore())
        s.put("evil\tid\nwith newline", "name\twith\ttabs\n", byteArrayOf(9))
        s.put("normal", "Normal", byteArrayOf(8))
        assertContentEquals(byteArrayOf(9), s.get("evil\tid\nwith newline"))
        assertEquals(2, s.list().size)
        assertEquals("name\twith\ttabs\n", s.list().first { it.deviceId.startsWith("evil") }.name)
    }

    @Test
    fun corruptDataIsIgnored() {
        val kv = MapKeyValueStore()
        kv.putString("trusted_devices", "garbage\nzz\tzz\tzz\n\n")
        assertEquals(0, KvTrustStore(kv).list().size)
    }

    @Test
    fun behavesLikeInMemoryStore() {
        val a = InMemoryTrustStore(); val b = KvTrustStore(MapKeyValueStore())
        for (s in listOf(a, b)) { s.put("x", "X", byteArrayOf(1)); s.put("y", "Y", byteArrayOf(2)); s.remove("x") }
        assertEquals(a.list(), b.list())
    }
}

class NetUtilTest {
    private fun addr(name: String, host: String, site: Boolean = true, loop: Boolean = false) = LocalAddress(name, host, site, loop)

    @Test
    fun prefersWifiSiteLocal() {
        val best = NetUtil.pickBest(listOf(addr("lo", "127.0.0.1", false, true), addr("rmnet0", "10.5.5.5"), addr("wlan0", "192.168.1.50")))
        assertEquals("192.168.1.50", best)
    }

    @Test
    fun prefersEthernetOverVpn() {
        assertEquals("192.168.0.9", NetUtil.pickBest(listOf(addr("tun0", "10.8.0.2"), addr("eth0", "192.168.0.9"))))
    }

    @Test
    fun avoidsLinkLocalAndLoopback() {
        assertNull(NetUtil.pickBest(listOf(addr("lo", "127.0.0.1", false, true))))
        assertEquals("192.168.1.2", NetUtil.pickBest(listOf(addr("wlan0", "169.254.3.3", false), addr("eth0", "192.168.1.2"))))
        assertNull(NetUtil.pickBest(emptyList()))
    }
}
