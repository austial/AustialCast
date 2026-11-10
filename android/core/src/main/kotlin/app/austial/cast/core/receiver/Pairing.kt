package app.austial.cast.core.receiver

import app.austial.cast.core.protocol.Crypto
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap

/**
 * Persistent store of pairing tokens, keyed by sender deviceId. The token is the shared secret
 * used for password-less reconnects, so implementations must keep it private to the app.
 */
interface TrustStore {
    fun get(deviceId: String): ByteArray?
    fun put(deviceId: String, name: String, token: ByteArray)
    fun remove(deviceId: String)
    fun clear()
    fun list(): List<TrustedDevice>
}

data class TrustedDevice(val deviceId: String, val name: String)

class InMemoryTrustStore : TrustStore {
    private data class Entry(val name: String, val token: ByteArray)

    private val map = ConcurrentHashMap<String, Entry>()
    override fun get(deviceId: String): ByteArray? = map[deviceId]?.token
    override fun put(deviceId: String, name: String, token: ByteArray) {
        map[deviceId] = Entry(name, token)
    }

    override fun remove(deviceId: String) {
        map.remove(deviceId)
    }

    override fun clear() = map.clear()
    override fun list(): List<TrustedDevice> = map.map { TrustedDevice(it.key, it.value.name) }.sortedBy { it.name }
}

/**
 * Manages the one-time 6 digit pairing PIN shown on the TV.
 *
 * Security properties:
 *  - the PIN is rotated after *every* PIN attempt (successful or not), so each PIN is single use
 *    and an attacker that sniffs a proof can only brute-force a PIN that is already burnt;
 *  - repeated failures from one remote address lock that address out for a while.
 */
class PinManager(
    private val clock: () -> Long = System::currentTimeMillis,
    private val random: SecureRandom = SecureRandom(),
    private val maxFailures: Int = 5,
    private val failureWindowMs: Long = 60_000,
    private val lockoutMs: Long = 60_000,
    private val onChange: (String) -> Unit = {},
    /** Tests / CLI only: always hand out this PIN. */
    private val fixedPin: String? = null,
) {
    private class Failures(var count: Int, var windowStart: Long, var lockedUntil: Long)

    private val failures = HashMap<String, Failures>()

    @Volatile
    var current: String = generate()
        private set

    private fun generate(): String = fixedPin ?: "%06d".format(random.nextInt(1_000_000))

    @Synchronized
    fun rotate(): String {
        current = generate()
        onChange(current)
        return current
    }

    @Synchronized
    fun isLocked(remote: String): Boolean {
        val f = failures[remote] ?: return false
        return clock() < f.lockedUntil
    }

    @Synchronized
    fun lockRemainingMs(remote: String): Long {
        val f = failures[remote] ?: return 0
        return (f.lockedUntil - clock()).coerceAtLeast(0)
    }

    /** The PIN used for the current attempt; callers must follow up with [attemptFinished]. */
    @Synchronized
    fun pinForAttempt(): String = current

    /** Records the result of a PIN attempt and rotates the PIN. */
    @Synchronized
    fun attemptFinished(remote: String, success: Boolean) {
        val now = clock()
        if (success) {
            failures.remove(remote)
        } else {
            val f = failures.getOrPut(remote) { Failures(0, now, 0) }
            if (now - f.windowStart > failureWindowMs) {
                f.count = 0
                f.windowStart = now
            }
            f.count++
            if (f.count >= maxFailures) {
                f.lockedUntil = now + lockoutMs
                f.count = 0
                f.windowStart = now
            }
        }
        current = generate()
        onChange(current)
    }

    companion object {
        fun newToken(): ByteArray = Crypto.randomBytes(32)
    }
}
