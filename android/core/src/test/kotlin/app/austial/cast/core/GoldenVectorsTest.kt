package app.austial.cast.core

import app.austial.cast.core.protocol.AudioFrame
import app.austial.cast.core.protocol.AudioInfo
import app.austial.cast.core.protocol.Auth
import app.austial.cast.core.protocol.Crypto
import app.austial.cast.core.protocol.FrameType
import app.austial.cast.core.protocol.FrameWriter
import app.austial.cast.core.protocol.MediaPayload
import app.austial.cast.core.protocol.StreamStart
import app.austial.cast.core.protocol.VideoFrame
import app.austial.cast.core.protocol.encodeMessage
import java.io.ByteArrayOutputStream
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import java.security.interfaces.ECPublicKey
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Generates and verifies protocol-vectors/vectors.json. The Swift test-suite checks its own
 * implementation against the same file, which keeps the two implementations wire compatible.
 *
 * Regenerate (only when the protocol intentionally changes) with: GENERATE_VECTORS=1 ./gradlew :core:test
 */
class GoldenVectorsTest {
    private val file = File("../../protocol-vectors/vectors.json")

    private fun params(): ECParameterSpec {
        val gen = KeyPairGenerator.getInstance("EC")
        gen.initialize(ECGenParameterSpec("secp256r1"))
        return (gen.generateKeyPair().public as ECPublicKey).params
    }

    private fun keyPairFromScalar(scalar: ByteArray): Pair<KeyPair, ByteArray> {
        val p = params()
        val d = BigInteger(1, scalar)
        val kf = KeyFactory.getInstance("EC")
        val priv = kf.generatePrivate(ECPrivateKeySpec(d, p))
        // Public point = d*G, computed via a throwaway agreement-free multiplication (double-and-add).
        val w = multiply(p, d)
        val pub = kf.generatePublic(ECPublicKeySpec(w, p))
        return KeyPair(pub, priv) to Crypto.encodePublic(pub as ECPublicKey)
    }

    private fun multiply(p: ECParameterSpec, k: BigInteger): java.security.spec.ECPoint {
        val prime = (p.curve.field as java.security.spec.ECFieldFp).p
        var result = java.security.spec.ECPoint.POINT_INFINITY
        var addend = p.generator
        var n = k
        fun add(a: java.security.spec.ECPoint, b: java.security.spec.ECPoint): java.security.spec.ECPoint {
            if (a == java.security.spec.ECPoint.POINT_INFINITY) return b
            if (b == java.security.spec.ECPoint.POINT_INFINITY) return a
            val lambda: BigInteger
            if (a.affineX == b.affineX) {
                if (a.affineY != b.affineY || a.affineY.signum() == 0) return java.security.spec.ECPoint.POINT_INFINITY
                lambda = a.affineX.pow(2).multiply(BigInteger.valueOf(3)).add(p.curve.a)
                    .multiply(a.affineY.shiftLeft(1).modInverse(prime)).mod(prime)
            } else {
                lambda = b.affineY.subtract(a.affineY).multiply(b.affineX.subtract(a.affineX).modInverse(prime)).mod(prime)
            }
            val x = lambda.pow(2).subtract(a.affineX).subtract(b.affineX).mod(prime)
            val y = lambda.multiply(a.affineX.subtract(x)).subtract(a.affineY).mod(prime)
            return java.security.spec.ECPoint(x, y)
        }
        while (n.signum() > 0) {
            if (n.testBit(0)) result = add(result, addend)
            addend = add(addend, addend)
            n = n.shiftRight(1)
        }
        return result
    }

    private fun sealed(
        keys: Crypto.SessionKeys,
        client: Boolean,
        type: FrameType,
        payload: ByteArray,
    ): String {
        val out = ByteArrayOutputStream()
        val w = FrameWriter(out)
        w.cipher = if (client) keys.clientToServer else keys.serverToClient
        w.write(type, payload)
        return Crypto.hex(out.toByteArray())
    }

    private fun build(): JsonObject {
        val scalarA = ByteArray(32) { (it + 1).toByte() }
        val scalarB = ByteArray(32) { (0x80 + it).toByte() }
        val (kpA, pubA) = keyPairFromScalar(scalarA)
        val (kpB, pubB) = keyPairFromScalar(scalarB)
        val shared = Crypto.ecdh(kpA, pubB)
        check(Crypto.ecdh(kpB, pubA).contentEquals(shared))
        val transcript = Crypto.sha256("hello-bytes".toByteArray(), "challenge-bytes".toByteArray())
        val keys = Crypto.deriveSessionKeys(shared, transcript)
        val plain = "hello austialcast".toByteArray()
        val video = MediaPayload.encodeVideo(VideoFrame(true, 0x0102030405060708L, byteArrayOf(0, 0, 0, 1, 0x65, 9)))
        val audio = MediaPayload.encodeAudio(AudioFrame(0x1122334455667788L, byteArrayOf(1, 2, 3)))
        val pin = "123456".toByteArray()
        val token = ByteArray(32) { (0xA0 + it).toByte() }

        // Frames are sealed with fresh ciphers for each independent vector so counters start at 0.
        fun fresh() = Crypto.deriveSessionKeys(shared, transcript)

        return buildJsonObject {
            put("description", "AustialCast protocol golden vectors. See docs/PROTOCOL.md")
            put("plainFrameHex", Crypto.hex(ByteArrayOutputStream().also { FrameWriter(it).write(FrameType.PING, byteArrayOf(0xAA.toByte(), 0xBB.toByte())) }.toByteArray()))
            put("scalarA", Crypto.hex(scalarA))
            put("scalarB", Crypto.hex(scalarB))
            put("publicA", Crypto.hex(pubA))
            put("publicB", Crypto.hex(pubB))
            put("sharedSecret", Crypto.hex(shared))
            put("transcript", Crypto.hex(transcript))
            put("clientToServerKeyProbe", sealed(fresh(), true, FrameType.CONTROL, plain))
            put("serverToClientKeyProbe", sealed(fresh(), false, FrameType.CONTROL, plain))
            put("probePlaintext", Crypto.hex(plain))
            val two = fresh()
            put("secondFrameClientToServer", sealed(two, true, FrameType.CONTROL, plain).let { sealed(two, true, FrameType.VIDEO_FRAME, video) })
            put("videoPayload", Crypto.hex(video))
            put("audioPayload", Crypto.hex(audio))
            put("pin", "123456")
            put("clientProofPin", Crypto.hex(Crypto.clientProof(pin, transcript)))
            put("serverProofPin", Crypto.hex(Crypto.serverProof(pin, transcript)))
            put("token", Crypto.hex(token))
            put("clientProofToken", Crypto.hex(Crypto.clientProof(token, transcript)))
            put("serverProofToken", Crypto.hex(Crypto.serverProof(token, transcript)))
            put("authJson", String(encodeMessage(Auth("pin", "abcd"))))
            put(
                "streamStartJson",
                String(encodeMessage(StreamStart(1920, 1080, 60, 8_000_000, audio = AudioInfo(sampleRate = 48000, channels = 2, config = "1190"), title = "Display 1"))),
            )
            put("streamStartNoAudioJson", String(encodeMessage(StreamStart(1280, 720, 30, 4_000_000))))
        }
    }

    @Test
    fun vectorsMatchCommittedFile() {
        val actual = Json { prettyPrint = true }.encodeToString(JsonObject.serializer(), build()) + "\n"
        if (System.getenv("GENERATE_VECTORS") == "1" || !file.exists()) {
            file.parentFile.mkdirs()
            file.writeText(actual)
        }
        assertEquals(file.readText(), actual, "golden vectors drifted; the wire format changed")
    }
}
