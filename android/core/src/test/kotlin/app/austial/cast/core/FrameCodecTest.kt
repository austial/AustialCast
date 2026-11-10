package app.austial.cast.core

import app.austial.cast.core.protocol.Frame
import app.austial.cast.core.protocol.FrameReader
import app.austial.cast.core.protocol.FrameType
import app.austial.cast.core.protocol.FrameWriter
import app.austial.cast.core.protocol.MAX_PAYLOAD
import app.austial.cast.core.protocol.PacketCipher
import app.austial.cast.core.protocol.ProtocolException
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.InputStream
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

/** Hands out one byte per read() call to exercise partial-read handling. */
private class TrickleStream(private val data: ByteArray) : InputStream() {
    private var pos = 0
    override fun read(): Int = if (pos < data.size) data[pos++].toInt() and 0xff else -1
    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (pos >= data.size) return -1
        b[off] = data[pos++]
        return 1
    }
}

class FrameCodecTest {
    private fun write(vararg frames: Pair<FrameType, ByteArray>, cipher: PacketCipher? = null): ByteArray {
        val out = ByteArrayOutputStream()
        val w = FrameWriter(out)
        w.cipher = cipher
        frames.forEach { w.write(it.first, it.second) }
        return out.toByteArray()
    }

    private fun cipherPair(): Pair<PacketCipher, PacketCipher> {
        val key = ByteArray(32) { it.toByte() }
        val prefix = byteArrayOf(1, 2, 3, 4)
        return PacketCipher(key, prefix) to PacketCipher(key, prefix)
    }

    @Test
    fun headerLayoutIsStable() {
        val bytes = write(FrameType.PING to byteArrayOf(0xAA.toByte(), 0xBB.toByte()))
        assertContentEquals(
            byteArrayOf(0x54, 0x43, 0x01, 0x09, 0x00, 0x00, 0x00, 0x02, 0xAA.toByte(), 0xBB.toByte()),
            bytes,
        )
    }

    @Test
    fun roundTripsEveryFrameType() {
        val frames = FrameType.entries.map { it to ByteArray(it.id * 3) { i -> (i + it.id).toByte() } }
        val bytes = write(*frames.toTypedArray())
        val reader = FrameReader(ByteArrayInputStream(bytes))
        frames.forEach { (type, payload) ->
            val f = reader.read()!!
            assertEquals(type, f.type)
            assertContentEquals(payload, f.payload)
        }
        assertNull(reader.read())
    }

    @Test
    fun handlesByteAtATimeDelivery() {
        val payload = ByteArray(5000) { (it * 7).toByte() }
        val bytes = write(FrameType.VIDEO_FRAME to payload, FrameType.BYE to ByteArray(0))
        val reader = FrameReader(TrickleStream(bytes))
        assertContentEquals(payload, reader.read()!!.payload)
        assertEquals(FrameType.BYE, reader.read()!!.type)
        assertNull(reader.read())
    }

    @Test
    fun emptyPayloadIsAllowed() {
        val reader = FrameReader(ByteArrayInputStream(write(FrameType.BYE to ByteArray(0))))
        assertEquals(0, reader.read()!!.payload.size)
    }

    @Test
    fun rejectsBadMagic() {
        val bytes = write(FrameType.PING to ByteArray(0)).also { it[0] = 0x00 }
        assertFailsWith<ProtocolException> { FrameReader(ByteArrayInputStream(bytes)).read() }
    }

    @Test
    fun rejectsUnknownVersion() {
        val bytes = write(FrameType.PING to ByteArray(0)).also { it[2] = 9 }
        assertFailsWith<ProtocolException> { FrameReader(ByteArrayInputStream(bytes)).read() }
    }

    @Test
    fun rejectsUnknownType() {
        val bytes = write(FrameType.PING to ByteArray(0)).also { it[3] = 0x7f }
        assertFailsWith<ProtocolException> { FrameReader(ByteArrayInputStream(bytes)).read() }
    }

    @Test
    fun rejectsOversizedLengthWithoutAllocating() {
        val bytes = byteArrayOf(0x54, 0x43, 1, 7, 0x7f, 0xff.toByte(), 0xff.toByte(), 0xff.toByte())
        assertFailsWith<ProtocolException> { FrameReader(ByteArrayInputStream(bytes)).read() }
        val negative = byteArrayOf(0x54, 0x43, 1, 7, 0xff.toByte(), 0xff.toByte(), 0xff.toByte(), 0xff.toByte())
        assertFailsWith<ProtocolException> { FrameReader(ByteArrayInputStream(negative)).read() }
    }

    @Test
    fun writerRejectsOversizedPayload() {
        val w = FrameWriter(ByteArrayOutputStream())
        assertFailsWith<ProtocolException> { w.write(FrameType.VIDEO_FRAME, ByteArray(MAX_PAYLOAD + 1)) }
    }

    @Test
    fun truncatedFrameIsAnError() {
        val bytes = write(FrameType.VIDEO_FRAME to ByteArray(100))
        assertFailsWith<EOFException> { FrameReader(ByteArrayInputStream(bytes.copyOf(50))).read() }
        assertFailsWith<EOFException> { FrameReader(ByteArrayInputStream(bytes.copyOf(5))).read() }
    }

    @Test
    fun encryptedRoundTrip() {
        val (enc, dec) = cipherPair()
        val a = ByteArray(1000) { it.toByte() }
        val b = "hello".toByteArray()
        val bytes = write(FrameType.VIDEO_FRAME to a, FrameType.CONTROL to b, cipher = enc)
        val reader = FrameReader(ByteArrayInputStream(bytes))
        reader.cipher = dec
        assertContentEquals(a, reader.read()!!.payload)
        assertContentEquals(b, reader.read()!!.payload)
    }

    @Test
    fun encryptedPayloadDoesNotContainPlaintext() {
        val (enc, _) = cipherPair()
        val marker = "SECRET-SCREEN-CONTENT".toByteArray()
        val bytes = write(FrameType.VIDEO_FRAME to marker, cipher = enc)
        assertEquals(-1, indexOf(bytes, marker))
    }

    @Test
    fun tamperedCiphertextIsRejected() {
        val (enc, dec) = cipherPair()
        val bytes = write(FrameType.VIDEO_FRAME to ByteArray(64), cipher = enc)
        bytes[12] = (bytes[12].toInt() xor 1).toByte()
        val reader = FrameReader(ByteArrayInputStream(bytes))
        reader.cipher = dec
        assertFailsWith<ProtocolException> { reader.read() }
    }

    @Test
    fun tamperedHeaderTypeIsRejected() {
        val (enc, dec) = cipherPair()
        val bytes = write(FrameType.VIDEO_FRAME to ByteArray(64), cipher = enc)
        bytes[3] = FrameType.AUDIO_FRAME.id.toByte() // header is authenticated as AAD
        val reader = FrameReader(ByteArrayInputStream(bytes))
        reader.cipher = dec
        assertFailsWith<ProtocolException> { reader.read() }
    }

    @Test
    fun reorderedOrReplayedFramesAreRejected() {
        val (enc, dec) = cipherPair()
        val f1 = write(FrameType.CONTROL to "one".toByteArray(), cipher = enc)
        val f2 = write(FrameType.CONTROL to "two".toByteArray(), cipher = enc)
        val reader = FrameReader(ByteArrayInputStream(f2 + f1)) // swapped
        reader.cipher = dec
        assertFailsWith<ProtocolException> { reader.read() }
    }

    @Test
    fun sameFrameSealedTwiceProducesDifferentCiphertext() {
        val (enc, _) = cipherPair()
        val a = write(FrameType.CONTROL to "same".toByteArray(), cipher = enc)
        val b = write(FrameType.CONTROL to "same".toByteArray(), cipher = enc)
        assertEquals(a.size, b.size)
        assert(!a.contentEquals(b))
    }

    @Test
    fun frameToStringDoesNotLeakPayload() {
        assertEquals("Frame(PING, 3 bytes)", Frame(FrameType.PING, ByteArray(3)).toString())
    }

    private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
        outer@ for (i in 0..haystack.size - needle.size) {
            for (j in needle.indices) if (haystack[i + j] != needle[j]) continue@outer
            return i
        }
        return -1
    }
}
