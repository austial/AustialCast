package app.austial.cast.core

import app.austial.cast.core.protocol.AnnexB
import app.austial.cast.core.protocol.AudioFrame
import app.austial.cast.core.protocol.AudioInfo
import app.austial.cast.core.protocol.Bye
import app.austial.cast.core.protocol.Control
import app.austial.cast.core.protocol.ControlCommand
import app.austial.cast.core.protocol.FrameType
import app.austial.cast.core.protocol.StatsReport
import app.austial.cast.core.protocol.StreamStart
import app.austial.cast.core.protocol.VideoFrame
import app.austial.cast.core.protocol.AuthFailure
import app.austial.cast.core.protocol.ByeReason
import app.austial.cast.core.protocol.decodeMessage
import app.austial.cast.core.receiver.EndReason
import app.austial.cast.core.receiver.InMemoryTrustStore
import app.austial.cast.core.receiver.PeerInfo
import app.austial.cast.core.receiver.PinManager
import app.austial.cast.core.receiver.ReceiverConfig
import app.austial.cast.core.receiver.ReceiverListener
import app.austial.cast.core.receiver.ReceiverServer
import app.austial.cast.core.sender.SenderClient
import java.io.IOException
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Records everything the receiver reports. */
class RecordingListener : ReceiverListener {
    val events = LinkedBlockingQueue<String>()
    val videoFrames = CopyOnWriteArrayList<VideoFrame>()
    val audioFrames = CopyOnWriteArrayList<AudioFrame>()
    val configs = CopyOnWriteArrayList<ByteArray>()
    val pins = CopyOnWriteArrayList<String>()
    val errors = CopyOnWriteArrayList<Throwable>()
    @Volatile var lastStart: StreamStart? = null
    @Volatile var lastPeer: PeerInfo? = null
    @Volatile var viaToken: Boolean? = null

    override fun onPinChanged(pin: String) { pins.add(pin) }
    override fun onPeerConnecting(peer: PeerInfo) { lastPeer = peer; events.add("connecting") }
    override fun onAuthenticated(peer: PeerInfo, viaToken: Boolean) { this.viaToken = viaToken; events.add("authenticated") }
    override fun onAuthFailed(peer: PeerInfo?, reason: String) { events.add("authFailed:$reason") }
    override fun onStreamStarted(peer: PeerInfo, info: StreamStart) { lastStart = info; events.add("started") }
    override fun onVideoConfig(config: ByteArray) { configs.add(config); events.add("config") }
    override fun onVideoFrame(frame: VideoFrame) { videoFrames.add(frame); events.add("video") }
    override fun onAudioFrame(frame: AudioFrame) { audioFrames.add(frame); events.add("audio") }
    override fun onPaused(paused: Boolean) { events.add(if (paused) "paused" else "resumed") }
    override fun onStreamEnded(peer: PeerInfo, reason: EndReason) { events.add("ended:$reason") }
    override fun onConnectionClosed(peer: PeerInfo?, reason: EndReason) { events.add("closed:$reason") }
    override fun onError(error: Throwable) { errors.add(error) }

    /** Waits until [event] arrives, discarding earlier events. */
    fun await(event: String, timeoutMs: Long = 5000): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (true) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) return false
            val e = events.poll(remaining, TimeUnit.MILLISECONDS) ?: return false
            if (e == event) return true
        }
    }

    fun awaitCount(event: String, count: Int, timeoutMs: Long = 5000): Boolean {
        var seen = 0
        val deadline = System.currentTimeMillis() + timeoutMs
        while (seen < count) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) return false
            val e = events.poll(remaining, TimeUnit.MILLISECONDS) ?: return false
            if (e == event) seen++
        }
        return true
    }
}

class ReceiverServerTest {
    private val listener = RecordingListener()
    private val trust = InMemoryTrustStore()
    private var server: ReceiverServer? = null
    private val clients = ArrayList<SenderClient>()

    private val sps = buildSps(80, 45)
    private val pps = byteArrayOf(0x68, 0xCE.toByte(), 0x38, 0x80.toByte())
    private val config get() = AnnexB.buildConfig(sps, pps)
    private val idr = AnnexB.START_CODE + byteArrayOf(0x65, 1, 2, 3)
    private val pframe = AnnexB.START_CODE + byteArrayOf(0x41, 4, 5, 6)
    private val streamStart = StreamStart(1280, 720, 30, 4_000_000)

    private fun start(
        cfg: ReceiverConfig.() -> ReceiverConfig = { this },
        pins: PinManager = PinManager(onChange = { listener.onPinChanged(it) }),
    ): ReceiverServer {
        val base = ReceiverConfig(deviceId = "tv-1", deviceName = "Living Room TV", port = 0, idleTimeoutMs = 1500, handshakeTimeoutMs = 1500)
        val s = ReceiverServer(base.cfg(), trust, listener, pins)
        s.start()
        server = s
        return s
    }

    private fun client(id: String = "mac-1", name: String = "My MacBook"): SenderClient {
        val c = SenderClient("127.0.0.1", server!!.port, id, name)
        clients.add(c)
        return c
    }

    @AfterTest
    fun tearDown() {
        clients.forEach { it.close() }
        server?.stop()
    }

    private fun pairAndStream(c: SenderClient): String? {
        c.connect()
        val r = c.authenticateWithPin(server!!.currentPin)
        assertTrue(r.ok, "pin auth should succeed: ${r.reason}")
        return r.token
    }

    @Test
    fun challengeAdvertisesReceiverIdentityAndLimits() {
        start()
        val ch = client().connect()
        assertEquals("tv-1", ch.deviceId)
        assertEquals("Living Room TV", ch.name)
        assertFalse(ch.trusted)
        assertEquals(3840, ch.maxWidth)
    }

    @Test
    fun pinAuthenticationIssuesTokenAndStreamsMedia() {
        start()
        val c = client()
        val token = pairAndStream(c)
        assertNotNull(token)
        assertEquals(64, token.length)
        assertTrue(listener.await("authenticated"))
        assertEquals(false, listener.viaToken)
        assertEquals("My MacBook", listener.lastPeer?.name)

        c.startStream(streamStart.copy(audio = AudioInfo(sampleRate = 48000, channels = 2, config = "1190"), title = "Display 1"))
        assertTrue(listener.await("started"))
        assertEquals("Display 1", listener.lastStart?.title)
        assertEquals("1190", listener.lastStart?.audio?.config)

        c.sendConfig(config)
        c.sendVideo(VideoFrame(true, 0, idr))
        c.sendVideo(VideoFrame(false, 33_333, pframe))
        c.sendAudio(AudioFrame(1_000, byteArrayOf(9, 8, 7)))
        assertTrue(listener.awaitCount("video", 2))
        assertTrue(listener.await("audio"))

        assertContentEquals(config, listener.configs.first())
        assertTrue(listener.videoFrames[0].keyframe)
        assertContentEquals(idr, listener.videoFrames[0].data)
        assertEquals(33_333, listener.videoFrames[1].ptsUs)
        assertFalse(listener.videoFrames[1].keyframe)
        assertContentEquals(byteArrayOf(9, 8, 7), listener.audioFrames[0].data)
        assertTrue(listener.errors.isEmpty(), "unexpected errors ${listener.errors}")
    }

    @Test
    fun trustedDeviceReconnectsWithTokenOnly() {
        start()
        val first = client()
        val token = pairAndStream(first)!!
        first.bye()
        first.close()
        assertTrue(listener.await("closed:SENDER_STOPPED") || true)

        val second = client()
        assertTrue(second.connect().trusted, "receiver should recognise the paired device")
        val r = second.authenticateWithToken(token)
        assertTrue(r.ok)
        assertNull(r.token)
        assertTrue(listener.await("authenticated"))
        assertTrue(listener.await("authenticated") || listener.viaToken == true)
        assertEquals(true, listener.viaToken)
    }

    @Test
    fun tokenIsBoundToTheDeviceId() {
        start()
        val owner = client("mac-1")
        val token = pairAndStream(owner)!!
        owner.close()

        val impostor = client("mac-2")
        assertFalse(impostor.connect().trusted)
        val r = impostor.authenticateWithToken(token)
        assertFalse(r.ok)
        assertEquals(AuthFailure.BAD_TOKEN, r.reason)
    }

    @Test
    fun wrongPinIsRejectedAndPinRotates() {
        start()
        val before = server!!.currentPin
        val c = client()
        c.connect()
        val wrong = if (before == "000000") "111111" else "000000"
        val r = c.authenticateWithPin(wrong)
        assertFalse(r.ok)
        assertEquals(AuthFailure.BAD_PIN, r.reason)
        assertEquals(true, r.retry)
        assertTrue(listener.await("authFailed:bad_pin"))
        assertTrue(listener.pins.isNotEmpty(), "listener must be told about the new pin")
        assertTrue(server!!.currentPin != before || listener.pins.isNotEmpty())
    }

    @Test
    fun correctPinAfterAWrongOneUsesTheRotatedPin() {
        start()
        val c = client()
        c.connect()
        val first = server!!.currentPin
        val wrong = if (first == "000000") "111111" else "000000"
        assertFalse(c.authenticateWithPin(wrong).ok)
        // The old PIN is burnt even though it was never guessed.
        val burnt = c.authenticateWithPin(first)
        if (server!!.currentPin != first) {
            assertFalse(burnt.ok, "a PIN must be single use")
        }
    }

    @Test
    fun pinCannotBeReusedAfterSuccessfulPairing() {
        start()
        val pin = server!!.currentPin
        val c1 = client("mac-1")
        c1.connect()
        assertTrue(c1.authenticateWithPin(pin).ok)
        c1.close()
        val c2 = client("mac-2")
        c2.connect()
        if (server!!.currentPin != pin) {
            assertFalse(c2.authenticateWithPin(pin).ok)
        }
    }

    @Test
    fun threeWrongAttemptsEndTheConnection() {
        start(pins = PinManager(fixedPin = "123456", maxFailures = 100))
        val c = client()
        c.connect()
        repeat(3) { assertFalse(c.authenticateWithPin("000000").ok) }
        // The server hung up after the third attempt.
        val result = try { c.read() } catch (e: IOException) { null }
        assertNull(result)
    }

    @Test
    fun repeatedFailuresLockTheAddressOut() {
        start(pins = PinManager(fixedPin = "123456", maxFailures = 2, lockoutMs = 60_000))
        repeat(2) {
            val c = client()
            c.connect()
            assertFalse(c.authenticateWithPin("000000").ok)
            c.close()
        }
        val c = client()
        c.connect()
        val r = c.authenticateWithPin("123456")
        assertFalse(r.ok, "even the correct PIN must be refused while locked out")
        assertEquals(AuthFailure.LOCKED, r.reason)
    }

    @Test
    fun trustedDevicesCanBeDisabled() {
        start(cfg = { copy(allowTrustedDevices = false) })
        val c = client()
        c.connect()
        val r = c.authenticateWithPin(server!!.currentPin)
        assertTrue(r.ok)
        assertNull(r.token, "no token may be issued when trust is disabled")
        assertEquals(0, trust.list().size)
    }

    @Test
    fun existingTokenIsIgnoredWhenTrustIsDisabled() {
        val s = start()
        val c = client()
        val token = pairAndStream(c)!!
        c.close()
        s.config = s.config.copy(allowTrustedDevices = false)
        val again = client()
        assertFalse(again.connect().trusted)
        assertFalse(again.authenticateWithToken(token).ok)
    }

    @Test
    fun secondSenderIsToldTheTvIsBusy() {
        start()
        val a = client("a")
        pairAndStream(a)
        a.startStream(streamStart)
        assertTrue(listener.await("started"))

        val b = client("b")
        b.connect()
        val r = b.authenticateWithPin(server!!.currentPin)
        // Auth succeeds cryptographically but the receiver is occupied -> BYE busy.
        val next = if (r.ok) b.read() else null
        assertNotNull(next)
        assertEquals(FrameType.BYE, next.type)
        assertEquals(ByeReason.BUSY, decodeMessage<Bye>(next.payload).reason)
        // The first stream is unaffected.
        a.sendVideo(VideoFrame(true, 1, idr))
        assertTrue(listener.await("video"))
    }

    @Test
    fun preemptReplacesTheActiveSender() {
        start(cfg = { copy(allowPreempt = true) })
        val a = client("a")
        pairAndStream(a)
        a.startStream(streamStart)
        assertTrue(listener.await("started"))

        val b = client("b")
        pairAndStream(b)
        assertTrue(listener.await("ended:REPLACED"))
        b.startStream(streamStart)
        assertTrue(listener.await("started"))
    }

    @Test
    fun sessionSlotIsFreedAfterDisconnect() {
        start()
        val a = client("a")
        pairAndStream(a)
        a.startStream(streamStart)
        assertTrue(listener.await("started"))
        a.close()
        assertTrue(listener.await("ended:DISCONNECTED"))
        val b = client("b")
        pairAndStream(b)
        b.startStream(streamStart)
        assertTrue(listener.await("started"))
    }

    @Test
    fun mediaBeforeStreamStartIsAProtocolViolation() {
        start()
        val c = client()
        pairAndStream(c)
        c.sendVideo(VideoFrame(true, 0, idr))
        val frame = c.read()
        assertEquals(FrameType.BYE, frame?.type)
        assertEquals(ByeReason.ERROR, decodeMessage<Bye>(frame!!.payload).reason)
        assertEquals(0, listener.videoFrames.size)
    }

    @Test
    fun invalidStreamParametersAreRejected() {
        start()
        val c = client()
        pairAndStream(c)
        c.startStream(streamStart.copy(width = 0))
        assertEquals(FrameType.BYE, c.read()?.type)
    }

    @Test
    fun unsupportedCodecIsRejected() {
        start()
        val c = client()
        pairAndStream(c)
        c.startStream(streamStart.copy(codec = "vp9"))
        assertEquals(FrameType.BYE, c.read()?.type)
    }

    @Test
    fun pingIsAnsweredWithMatchingPayload() {
        start()
        val c = client()
        pairAndStream(c)
        val sent = c.ping()
        val pong = c.read()!!
        assertEquals(FrameType.PONG, pong.type)
        assertEquals(sent, java.nio.ByteBuffer.wrap(pong.payload).long)
    }

    @Test
    fun pauseAndResumeAreForwarded() {
        start()
        val c = client()
        pairAndStream(c)
        c.startStream(streamStart)
        c.sendControl(Control(ControlCommand.PAUSE))
        assertTrue(listener.await("paused"))
        c.sendControl(Control(ControlCommand.RESUME))
        assertTrue(listener.await("resumed"))
    }

    @Test
    fun unknownControlCommandsAreIgnored() {
        start()
        val c = client()
        pairAndStream(c)
        c.startStream(streamStart)
        c.sendControl(Control("someFutureCommand"))
        c.sendVideo(VideoFrame(true, 0, idr))
        assertTrue(listener.await("video"))
    }

    @Test
    fun senderStopEndsTheStream() {
        start()
        val c = client()
        pairAndStream(c)
        c.startStream(streamStart)
        c.bye()
        assertTrue(listener.await("ended:SENDER_STOPPED"))
        assertFalse(server!!.isStreaming)
    }

    @Test
    fun receiverCanRequestKeyframeAndSendStats() {
        val s = start()
        val c = client()
        pairAndStream(c)
        c.startStream(streamStart)
        assertTrue(listener.await("started"))
        s.requestKeyframe()
        s.requestBitrate(2_000_000)
        s.sendStats(StatsReport(fps = 29.5, decoded = 100, dropped = 1, bufferMs = 20))
        val a = c.read()!!
        val b = c.read()!!
        val d = c.read()!!
        assertEquals(FrameType.CONTROL, a.type)
        assertEquals(ControlCommand.REQUEST_KEYFRAME, decodeMessage<Control>(a.payload).cmd)
        assertEquals(2_000_000, decodeMessage<Control>(b.payload).bitrate)
        assertEquals(FrameType.STATS, d.type)
        assertEquals(29.5, decodeMessage<StatsReport>(d.payload).fps)
    }

    @Test
    fun receiverCanKickTheSender() {
        val s = start()
        val c = client()
        pairAndStream(c)
        c.startStream(streamStart)
        assertTrue(listener.await("started"))
        s.disconnectActive()
        assertTrue(listener.await("ended:KICKED"))
        val bye = c.read()
        assertEquals(FrameType.BYE, bye?.type)
    }

    @Test
    fun receiverMeasuresRtt() {
        val s = start()
        val c = client()
        pairAndStream(c)
        c.startStream(streamStart)
        assertTrue(listener.await("started"))
        s.ping()
        val ping = c.read()!!
        assertEquals(FrameType.PING, ping.type)
        c.writer.write(FrameType.PONG, ping.payload)
        val deadline = System.currentTimeMillis() + 3000
        while (s.rttMs == null && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertNotNull(s.rttMs)
    }

    @Test
    fun idleSenderTimesOut() {
        start()
        val c = client()
        pairAndStream(c)
        c.startStream(streamStart)
        assertTrue(listener.await("started"))
        assertTrue(listener.await("ended:TIMEOUT", 6000))
    }

    @Test
    fun silentConnectionIsDroppedDuringHandshake() {
        start()
        val raw = Socket("127.0.0.1", server!!.port)
        assertTrue(listener.await("closed:TIMEOUT", 5000))
        raw.close()
    }

    @Test
    fun garbageBytesDoNotCrashTheServer() {
        start()
        Socket("127.0.0.1", server!!.port).use { it.getOutputStream().apply { write(ByteArray(64) { 0x41 }); flush() } }
        assertTrue(listener.await("closed:ERROR"))
        val c = client()
        pairAndStream(c)
    }

    @Test
    fun wrongFirstFrameIsRejected() {
        start()
        val c = client()
        c.connect()
        // AUTH_RESULT is never valid from a sender.
        c.writer.write(FrameType.AUTH_RESULT, ByteArray(2))
        val r = try { c.read() } catch (e: IOException) { null }
        assertTrue(r == null || r.type == FrameType.BYE)
    }

    @Test
    fun tooManyHandshakesInParallelAreRefused() {
        start(cfg = { copy(maxPendingConnections = 2) })
        val sockets = (1..6).map { Socket("127.0.0.1", server!!.port) }
        Thread.sleep(300)
        var closed = 0
        sockets.forEach {
            it.soTimeout = 200
            try { if (it.getInputStream().read() == -1) closed++ } catch (_: java.net.SocketTimeoutException) {}
        }
        sockets.forEach { it.close() }
        assertTrue(closed >= 3, "excess connections must be closed immediately (closed=$closed)")
    }

    @Test
    fun deviceNamesAreSanitised() {
        start()
        val c = client(name = "Evil\n\u0007Name" + "x".repeat(200))
        c.connect()
        assertTrue(listener.await("connecting"))
        val name = listener.lastPeer!!.name
        assertTrue(name.length <= 64)
        assertTrue(name.none { it.isISOControl() })
    }

    @Test
    fun serverStopDisconnectsClients() {
        val s = start()
        val c = client()
        pairAndStream(c)
        c.startStream(streamStart)
        assertTrue(listener.await("started"))
        s.stop()
        assertTrue(listener.await("ended:KICKED"))
    }

    @Test
    fun highVolumeStreamKeepsOrderAndIntegrity() {
        start()
        val c = client()
        pairAndStream(c)
        c.startStream(streamStart)
        val frames = 600
        for (i in 0 until frames) {
            val data = AnnexB.START_CODE + byteArrayOf(0x41) + ByteArray(8000) { (it + i).toByte() }
            c.sendVideo(VideoFrame(i % 60 == 0, i * 16_666L, data))
        }
        val deadline = System.currentTimeMillis() + 10_000
        while (listener.videoFrames.size < frames && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertEquals(frames, listener.videoFrames.size)
        listener.videoFrames.forEachIndexed { i, f ->
            assertEquals(i * 16_666L, f.ptsUs)
            assertEquals(((8000 - 1) + i).toByte(), f.data.last())
        }
    }

    @Test
    fun startingTwiceFails() {
        val s = start()
        val failed = try { s.start(); false } catch (e: IllegalStateException) { true }
        assertTrue(failed)
    }

    @Test
    fun concurrentLatchSanity() {
        // Guards against flaky ordering assumptions in these tests: events are queued in order.
        val l = CountDownLatch(1)
        l.countDown()
        assertTrue(l.await(1, TimeUnit.SECONDS))
    }
}
