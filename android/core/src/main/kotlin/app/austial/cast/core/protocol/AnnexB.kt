package app.austial.cast.core.protocol

/** Helpers for H.264 Annex-B byte streams (start-code delimited NAL units). */
object AnnexB {
    const val NAL_SLICE_IDR = 5
    const val NAL_SPS = 7
    const val NAL_PPS = 8

    val START_CODE = byteArrayOf(0, 0, 0, 1)

    /** Splits [data] into NAL units without their start codes. Handles 3 and 4 byte start codes. */
    fun splitNalUnits(data: ByteArray): List<ByteArray> {
        val starts = ArrayList<Pair<Int, Int>>() // (index of start code, start code length)
        var i = 0
        while (i + 3 <= data.size) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                if (data[i + 2] == 1.toByte()) {
                    starts.add(i to 3)
                    i += 3
                    continue
                }
                if (i + 4 <= data.size && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
                    starts.add(i to 4)
                    i += 4
                    continue
                }
            }
            i++
        }
        val units = ArrayList<ByteArray>(starts.size)
        for (k in starts.indices) {
            val begin = starts[k].first + starts[k].second
            var end = if (k + 1 < starts.size) starts[k + 1].first else data.size
            // Trailing zero bytes belong to the next (4 byte) start code or are padding.
            while (end > begin && data[end - 1] == 0.toByte()) end--
            if (end > begin) units.add(data.copyOfRange(begin, end))
        }
        return units
    }

    fun nalType(nal: ByteArray): Int = if (nal.isEmpty()) -1 else nal[0].toInt() and 0x1f

    fun containsIdr(accessUnit: ByteArray): Boolean = splitNalUnits(accessUnit).any { nalType(it) == NAL_SLICE_IDR }

    class ParameterSets(val sps: ByteArray, val pps: ByteArray)

    /** Extracts the first SPS and PPS found in a VIDEO_CONFIG payload (or any Annex-B buffer). */
    fun parseParameterSets(config: ByteArray): ParameterSets? {
        val nals = splitNalUnits(config)
        val sps = nals.firstOrNull { nalType(it) == NAL_SPS } ?: return null
        val pps = nals.firstOrNull { nalType(it) == NAL_PPS } ?: return null
        return ParameterSets(sps, pps)
    }

    fun withStartCode(nal: ByteArray): ByteArray = START_CODE + nal

    /** Builds a VIDEO_CONFIG payload out of raw SPS and PPS NAL units. */
    fun buildConfig(sps: ByteArray, pps: ByteArray): ByteArray =
        withStartCode(sps) + withStartCode(pps)

    /** Parses the coded picture dimensions out of an SPS NAL unit (baseline/main/high profiles). */
    fun spsDimensions(sps: ByteArray): Pair<Int, Int>? {
        return try {
            val rbsp = unescape(sps.copyOfRange(1, sps.size))
            val r = BitReader(rbsp)
            val profile = r.bits(8)
            r.bits(8) // constraint flags + reserved
            r.bits(8) // level
            r.ue() // sps id
            var chromaFormat = 1
            if (profile in intArrayOf(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)) {
                chromaFormat = r.ue()
                if (chromaFormat == 3) r.bits(1)
                r.ue(); r.ue(); r.bits(1)
                if (r.bits(1) == 1) {
                    val count = if (chromaFormat != 3) 8 else 12
                    for (i in 0 until count) {
                        if (r.bits(1) == 1) skipScalingList(r, if (i < 6) 16 else 64)
                    }
                }
            }
            r.ue() // log2_max_frame_num_minus4
            val pocType = r.ue()
            if (pocType == 0) {
                r.ue()
            } else if (pocType == 1) {
                r.bits(1); r.se(); r.se()
                val n = r.ue()
                for (i in 0 until n) r.se()
            }
            r.ue() // max_num_ref_frames
            r.bits(1) // gaps
            val widthMbs = r.ue() + 1
            val heightMapUnits = r.ue() + 1
            val frameMbsOnly = r.bits(1)
            if (frameMbsOnly == 0) r.bits(1)
            r.bits(1) // direct_8x8
            var cropLeft = 0; var cropRight = 0; var cropTop = 0; var cropBottom = 0
            if (r.bits(1) == 1) {
                cropLeft = r.ue(); cropRight = r.ue(); cropTop = r.ue(); cropBottom = r.ue()
            }
            val cropUnitX = if (chromaFormat == 0) 1 else if (chromaFormat == 3) 1 else 2
            val cropUnitY = (if (chromaFormat == 1) 2 else 1) * (2 - frameMbsOnly)
            val width = widthMbs * 16 - (cropLeft + cropRight) * cropUnitX
            val height = (2 - frameMbsOnly) * heightMapUnits * 16 - (cropTop + cropBottom) * cropUnitY
            width to height
        } catch (e: IndexOutOfBoundsException) {
            null
        }
    }

    private fun skipScalingList(r: BitReader, size: Int) {
        var last = 8
        var next = 8
        for (j in 0 until size) {
            if (next != 0) {
                next = (last + r.se() + 256) % 256
            }
            last = if (next == 0) last else next
        }
    }

    private fun unescape(data: ByteArray): ByteArray {
        val out = java.io.ByteArrayOutputStream(data.size)
        var zeros = 0
        for (b in data) {
            if (zeros >= 2 && b == 3.toByte()) {
                zeros = 0
                continue
            }
            out.write(b.toInt())
            zeros = if (b == 0.toByte()) zeros + 1 else 0
        }
        return out.toByteArray()
    }

    private class BitReader(private val data: ByteArray) {
        private var pos = 0
        fun bits(n: Int): Int {
            var v = 0
            repeat(n) {
                val byte = data[pos ushr 3].toInt()
                v = (v shl 1) or ((byte shr (7 - (pos and 7))) and 1)
                pos++
            }
            return v
        }

        fun ue(): Int {
            var zeros = 0
            while (bits(1) == 0) {
                zeros++
                if (zeros > 31) throw IndexOutOfBoundsException()
            }
            return if (zeros == 0) 0 else ((1 shl zeros) - 1) + bits(zeros)
        }

        fun se(): Int {
            val k = ue()
            return if (k and 1 == 1) (k + 1) / 2 else -(k / 2)
        }
    }
}
