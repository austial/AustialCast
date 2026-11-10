package app.austial.cast.core

import app.austial.cast.core.protocol.Crypto
import app.austial.cast.core.protocol.ProtocolException
import java.math.BigInteger
import java.security.interfaces.ECPublicKey
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class CryptoTest {
    @Test
    fun hexRoundTrip() {
        val bytes = byteArrayOf(0, 1, 0x7f, 0x80.toByte(), 0xff.toByte())
        assertEquals("00017f80ff", Crypto.hex(bytes))
        assertContentEquals(bytes, Crypto.unhex("00017F80FF"))
        assertFailsWith<IllegalArgumentException> { Crypto.unhex("abc") }
        assertFailsWith<IllegalArgumentException> { Crypto.unhex("zz") }
    }

    @Test
    fun hmacMatchesRfc4231Case1() {
        val key = ByteArray(20) { 0x0b }
        val mac = Crypto.hmacSha256(key, "Hi There".toByteArray())
        assertEquals("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", Crypto.hex(mac))
    }

    @Test
    fun hkdfMatchesRfc5869Case1() {
        val ikm = ByteArray(22) { 0x0b }
        val salt = Crypto.unhex("000102030405060708090a0b0c")
        val info = Crypto.unhex("f0f1f2f3f4f5f6f7f8f9")
        val okm = Crypto.hkdfSha256(ikm, salt, info, 42)
        assertEquals(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            Crypto.hex(okm),
        )
    }

    @Test
    fun hkdfMatchesRfc5869Case3EmptySaltAndInfo() {
        val ikm = ByteArray(22) { 0x0b }
        val okm = Crypto.hkdfSha256(ikm, ByteArray(0), ByteArray(0), 42)
        assertEquals(
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8",
            Crypto.hex(okm),
        )
    }

    @Test
    fun ecdhAgreesOnBothSides() {
        val a = Crypto.generateEphemeral()
        val b = Crypto.generateEphemeral()
        assertEquals(65, a.publicX963.size)
        assertEquals(0x04, a.publicX963[0].toInt())
        val s1 = Crypto.ecdh(a.keyPair, b.publicX963)
        val s2 = Crypto.ecdh(b.keyPair, a.publicX963)
        assertEquals(32, s1.size)
        assertContentEquals(s1, s2)
    }

    @Test
    fun ephemeralKeysAreFresh() {
        assertNotEquals(Crypto.hex(Crypto.generateEphemeral().publicX963), Crypto.hex(Crypto.generateEphemeral().publicX963))
    }

    @Test
    fun rejectsPointNotOnCurve() {
        val a = Crypto.generateEphemeral()
        val bad = a.publicX963.copyOf().also { it[64] = (it[64].toInt() xor 1).toByte() }
        assertFailsWith<ProtocolException> { Crypto.ecdh(a.keyPair, bad) }
    }

    @Test
    fun rejectsMalformedKeys() {
        val a = Crypto.generateEphemeral()
        assertFailsWith<ProtocolException> { Crypto.ecdh(a.keyPair, ByteArray(10)) }
        assertFailsWith<ProtocolException> { Crypto.ecdh(a.keyPair, a.publicX963.copyOf().also { it[0] = 0x02 }) }
    }

    @Test
    fun onCurveCheckRejectsOutOfRangeCoordinates() {
        val a = Crypto.generateEphemeral()
        val params = (a.keyPair.public as ECPublicKey).params
        assertTrue(Crypto.isOnCurve((a.keyPair.public as ECPublicKey).w.affineX, (a.keyPair.public as ECPublicKey).w.affineY, params))
        assertFalse(Crypto.isOnCurve(BigInteger.ONE.negate(), BigInteger.ONE, params))
        assertFalse(Crypto.isOnCurve(BigInteger.ZERO, BigInteger.ZERO, params))
    }

    @Test
    fun sessionKeysAreDirectionalAndTranscriptBound() {
        val shared = ByteArray(32) { it.toByte() }
        val t1 = Crypto.sha256("one".toByteArray())
        val t2 = Crypto.sha256("two".toByteArray())
        val keysA = Crypto.deriveSessionKeys(shared, t1)
        val keysB = Crypto.deriveSessionKeys(shared, t1)
        val other = Crypto.deriveSessionKeys(shared, t2)
        val aad = ByteArray(8)
        val plain = "payload".toByteArray()
        // Same derivation -> interoperable.
        assertContentEquals(plain, keysB.clientToServer.open(aad, keysA.clientToServer.seal(aad, plain)))
        // Different direction or transcript -> cannot open.
        assertFailsWith<ProtocolException> { keysB.serverToClient.open(aad, keysA.clientToServer.seal(aad, plain)) }
        assertFailsWith<ProtocolException> { other.clientToServer.open(aad, keysA.clientToServer.seal(aad, plain)) }
    }

    @Test
    fun proofsDependOnSecretRoleAndTranscript() {
        val t = Crypto.sha256("t".toByteArray())
        val pin = "123456".toByteArray()
        val c = Crypto.clientProof(pin, t)
        assertContentEquals(c, Crypto.clientProof(pin, t))
        assertNotEquals(Crypto.hex(c), Crypto.hex(Crypto.serverProof(pin, t)))
        assertNotEquals(Crypto.hex(c), Crypto.hex(Crypto.clientProof("123457".toByteArray(), t)))
        assertNotEquals(Crypto.hex(c), Crypto.hex(Crypto.clientProof(pin, Crypto.sha256("u".toByteArray()))))
    }
}
