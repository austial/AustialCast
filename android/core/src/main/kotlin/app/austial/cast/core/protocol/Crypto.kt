package app.austial.cast.core.protocol

import java.math.BigInteger
import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Cryptographic helpers shared by the receiver and the (JVM) sender used in tests. */
object Crypto {
    private val random = SecureRandom()

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

    fun sha256(vararg parts: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        parts.forEach { md.update(it) }
        return md.digest()
    }

    fun hmacSha256(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        // Mac rejects empty keys; HMAC with an empty key is equal to a zero key of block size.
        val k = if (key.isEmpty()) ByteArray(32) else key
        mac.init(SecretKeySpec(k, "HmacSHA256"))
        parts.forEach { mac.update(it) }
        return mac.doFinal()
    }

    /** RFC 5869 HKDF with SHA-256. */
    fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..(255 * 32))
        val prk = hmacSha256(if (salt.isEmpty()) ByteArray(32) else salt, ikm)
        val out = ByteArray(length)
        var previous = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            previous = hmacSha256(prk, previous, info, byteArrayOf(counter.toByte()))
            val n = minOf(previous.size, length - pos)
            System.arraycopy(previous, 0, out, pos, n)
            pos += n
            counter++
        }
        return out
    }

    fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

    fun hex(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            sb.append(HEX[(b.toInt() shr 4) and 0xf]).append(HEX[b.toInt() and 0xf])
        }
        return sb.toString()
    }

    fun unhex(s: String): ByteArray {
        require(s.length % 2 == 0) { "odd hex length" }
        return ByteArray(s.length / 2) { i ->
            val hi = Character.digit(s[i * 2], 16)
            val lo = Character.digit(s[i * 2 + 1], 16)
            require(hi >= 0 && lo >= 0) { "invalid hex" }
            ((hi shl 4) or lo).toByte()
        }
    }

    private const val HEX = "0123456789abcdef"

    // ---- ECDH over P-256 ------------------------------------------------------------------

    class EphemeralKeys(val keyPair: KeyPair) {
        /** ANSI X9.63 uncompressed point: 0x04 || X || Y (65 bytes). */
        val publicX963: ByteArray = encodePublic(keyPair.public as ECPublicKey)
    }

    fun generateEphemeral(): EphemeralKeys {
        val gen = KeyPairGenerator.getInstance("EC")
        gen.initialize(ECGenParameterSpec("secp256r1"), random)
        return EphemeralKeys(gen.generateKeyPair())
    }

    /** Returns the 32 byte ECDH shared secret (X coordinate) for [peerX963]. */
    fun ecdh(own: KeyPair, peerX963: ByteArray): ByteArray {
        val peer = decodePublic(peerX963, (own.public as ECPublicKey).params)
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(own.private)
        ka.doPhase(peer, true)
        return ka.generateSecret()
    }

    private fun toFixed32(v: BigInteger): ByteArray {
        val raw = v.toByteArray()
        return when {
            raw.size == 32 -> raw
            raw.size > 32 -> raw.copyOfRange(raw.size - 32, raw.size) // strip sign byte
            else -> ByteArray(32).also { System.arraycopy(raw, 0, it, 32 - raw.size, raw.size) }
        }
    }

    fun encodePublic(key: ECPublicKey): ByteArray {
        val out = ByteArray(65)
        out[0] = 0x04
        System.arraycopy(toFixed32(key.w.affineX), 0, out, 1, 32)
        System.arraycopy(toFixed32(key.w.affineY), 0, out, 33, 32)
        return out
    }

    fun decodePublic(x963: ByteArray, params: ECParameterSpec): ECPublicKey {
        if (x963.size != 65 || x963[0] != 0x04.toByte()) throw ProtocolException("malformed public key")
        val x = BigInteger(1, x963.copyOfRange(1, 33))
        val y = BigInteger(1, x963.copyOfRange(33, 65))
        if (!isOnCurve(x, y, params)) throw ProtocolException("public key not on curve")
        try {
            return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), params)) as ECPublicKey
        } catch (e: GeneralSecurityException) {
            throw ProtocolException("invalid public key", e)
        }
    }

    /** Checks y^2 = x^3 + ax + b (mod p) and that coordinates are reduced. */
    fun isOnCurve(x: BigInteger, y: BigInteger, params: ECParameterSpec): Boolean {
        val curve = params.curve
        val p = (curve.field as java.security.spec.ECFieldFp).p
        if (x.signum() < 0 || y.signum() < 0 || x >= p || y >= p) return false
        val lhs = y.modPow(BigInteger.TWO, p)
        val rhs = x.modPow(BigInteger.valueOf(3), p).add(curve.a.multiply(x)).add(curve.b).mod(p)
        return lhs == rhs
    }

    // ---- Session key schedule -------------------------------------------------------------

    /**
     * Directional AES-256-GCM keys derived from the ECDH secret and the handshake transcript.
     * [clientToServer] seals sender->receiver frames, [serverToClient] receiver->sender frames.
     */
    class SessionKeys(val clientToServer: PacketCipher, val serverToClient: PacketCipher)

    fun transcriptHash(helloBytes: ByteArray, challengeBytes: ByteArray): ByteArray =
        sha256(helloBytes, challengeBytes)

    private fun directionMaterial(shared: ByteArray, transcript: ByteArray, label: String): ByteArray =
        hkdfSha256(shared, transcript, "austialcast v1 $label".toByteArray(Charsets.US_ASCII), 36)

    /** Material layout: 32 byte AES key followed by a 4 byte nonce prefix. */
    fun deriveSessionKeys(shared: ByteArray, transcript: ByteArray): SessionKeys {
        fun cipher(label: String): PacketCipher {
            val m = directionMaterial(shared, transcript, label)
            return PacketCipher(m.copyOfRange(0, 32), m.copyOfRange(32, 36))
        }
        return SessionKeys(cipher("client->server"), cipher("server->client"))
    }

    /** Receiver and sender need independent cipher instances (counters are stateful). */
    fun deriveSessionKeysPair(shared: ByteArray, transcript: ByteArray): Pair<SessionKeys, SessionKeys> =
        deriveSessionKeys(shared, transcript) to deriveSessionKeys(shared, transcript)

    // ---- Authentication proofs ------------------------------------------------------------

    private val CLIENT_LABEL = "austialcast v1 client".toByteArray(Charsets.US_ASCII)
    private val SERVER_LABEL = "austialcast v1 server".toByteArray(Charsets.US_ASCII)

    fun clientProof(secret: ByteArray, transcript: ByteArray): ByteArray =
        hmacSha256(secret, CLIENT_LABEL, transcript)

    fun serverProof(secret: ByteArray, transcript: ByteArray): ByteArray =
        hmacSha256(secret, SERVER_LABEL, transcript)
}

/**
 * AES-256-GCM sealing of one direction of a connection. The nonce is a 4 byte per-direction
 * prefix followed by a 64 bit big-endian counter, so a (key, nonce) pair is never reused.
 */
class PacketCipher(private val key: ByteArray, private val noncePrefix: ByteArray) {
    init {
        require(key.size == 32) { "key must be 32 bytes" }
        require(noncePrefix.size == 4) { "nonce prefix must be 4 bytes" }
    }

    private var counter = 0L
    private val keySpec = SecretKeySpec(key, "AES")

    private fun nextNonce(): ByteArray {
        val n = ByteArray(12)
        System.arraycopy(noncePrefix, 0, n, 0, 4)
        var c = counter++
        for (i in 11 downTo 4) {
            n[i] = (c and 0xff).toByte()
            c = c ushr 8
        }
        return n
    }

    @Synchronized
    fun seal(aad: ByteArray, plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(128, nextNonce()))
        cipher.updateAAD(aad)
        return cipher.doFinal(plain)
    }

    @Synchronized
    fun open(aad: ByteArray, sealed: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(128, nextNonce()))
        cipher.updateAAD(aad)
        try {
            return cipher.doFinal(sealed)
        } catch (e: GeneralSecurityException) {
            throw ProtocolException("authentication of frame failed", e)
        }
    }
}
