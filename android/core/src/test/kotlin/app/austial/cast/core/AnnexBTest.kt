package app.austial.cast.core

import app.austial.cast.core.protocol.AnnexB
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Builds SPS NAL units so the parser can be verified without an encoder. */
internal class BitWriter {
    private val bits = ArrayList<Int>()
    fun u(n: Int, v: Int) { for (i in n - 1 downTo 0) bits.add((v shr i) and 1) }
    fun ue(v: Int) {
        val x = v + 1
        val len = 32 - Integer.numberOfLeadingZeros(x)
        repeat(len - 1) { bits.add(0) }
        u(len, x)
    }
    fun bytes(): ByteArray {
        bits.add(1) // rbsp stop bit
        while (bits.size % 8 != 0) bits.add(0)
        return ByteArray(bits.size / 8) { i -> (0 until 8).fold(0) { acc, j -> (acc shl 1) or bits[i * 8 + j] }.toByte() }
    }
}

internal fun buildSps(widthMbs: Int, heightMbs: Int, cropBottom: Int = 0, profile: Int = 66): ByteArray {
    val w = BitWriter()
    w.u(8, profile); w.u(8, 0); w.u(8, 40)
    w.ue(0) // sps id
    if (profile == 100) { w.ue(1); w.ue(0); w.ue(0); w.u(1, 0); w.u(1, 0) }
    w.ue(0) // log2_max_frame_num_minus4
    w.ue(0); w.ue(0) // poc type 0, log2_max_poc_lsb_minus4
    w.ue(1) // max_num_ref_frames
    w.u(1, 0)
    w.ue(widthMbs - 1); w.ue(heightMbs - 1)
    w.u(1, 1) // frame_mbs_only
    w.u(1, 1) // direct_8x8
    if (cropBottom > 0) { w.u(1, 1); w.ue(0); w.ue(0); w.ue(0); w.ue(cropBottom) } else w.u(1, 0)
    w.u(1, 0) // vui
    return byteArrayOf(0x67) + w.bytes()
}

class AnnexBTest {
    private val sc4 = byteArrayOf(0, 0, 0, 1)
    private val sc3 = byteArrayOf(0, 0, 1)

    @Test
    fun splitsMixedStartCodes() {
        val a = byteArrayOf(0x67, 1, 2)
        val b = byteArrayOf(0x68, 3)
        val c = byteArrayOf(0x65, 4, 5, 6)
        val nals = AnnexB.splitNalUnits(sc4 + a + sc3 + b + sc4 + c)
        assertEquals(3, nals.size)
        assertContentEquals(a, nals[0])
        assertContentEquals(b, nals[1])
        assertContentEquals(c, nals[2])
    }

    @Test
    fun splitHandlesEmptyAndGarbage() {
        assertEquals(0, AnnexB.splitNalUnits(ByteArray(0)).size)
        assertEquals(0, AnnexB.splitNalUnits(byteArrayOf(1, 2, 3)).size)
        assertEquals(0, AnnexB.splitNalUnits(sc4).size)
    }

    @Test
    fun trailingZerosAreNotPartOfNal() {
        val nals = AnnexB.splitNalUnits(sc4 + byteArrayOf(0x41, 9, 0, 0) + sc4 + byteArrayOf(0x41, 8))
        assertContentEquals(byteArrayOf(0x41, 9), nals[0])
        assertContentEquals(byteArrayOf(0x41, 8), nals[1])
    }

    @Test
    fun detectsIdr() {
        assertTrue(AnnexB.containsIdr(sc4 + byteArrayOf(0x65, 1)))
        assertTrue(AnnexB.containsIdr(sc4 + byteArrayOf(0x09, 0x10) + sc4 + byteArrayOf(0x65, 1)))
        assertFalse(AnnexB.containsIdr(sc4 + byteArrayOf(0x41, 1)))
        assertFalse(AnnexB.containsIdr(ByteArray(0)))
    }

    @Test
    fun parsesParameterSets() {
        val sps = buildSps(120, 68)
        val pps = byteArrayOf(0x68, 0xCE.toByte(), 0x38, 0x80.toByte())
        val ps = AnnexB.parseParameterSets(AnnexB.buildConfig(sps, pps))
        assertNotNull(ps)
        assertContentEquals(sps, ps.sps)
        assertContentEquals(pps, ps.pps)
        assertNull(AnnexB.parseParameterSets(AnnexB.withStartCode(sps)))
        assertNull(AnnexB.parseParameterSets(ByteArray(0)))
    }

    @Test
    fun spsDimensionsBaseline() {
        assertEquals(1280 to 720, AnnexB.spsDimensions(buildSps(80, 45)))
        assertEquals(640 to 480, AnnexB.spsDimensions(buildSps(40, 30)))
    }

    @Test
    fun spsDimensionsAppliesCropping() {
        // 1080p is coded as 1088 lines with 8 lines cropped (4 crop units of 2 lines).
        assertEquals(1920 to 1080, AnnexB.spsDimensions(buildSps(120, 68, cropBottom = 4)))
    }

    @Test
    fun spsDimensionsHighProfile() {
        assertEquals(3840 to 2160, AnnexB.spsDimensions(buildSps(240, 135, profile = 100)))
    }

    @Test
    fun spsDimensionsToleratesTruncatedInput() {
        assertNull(AnnexB.spsDimensions(byteArrayOf(0x67, 0x42)))
    }
}
