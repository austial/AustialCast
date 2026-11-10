package app.austial.cast.core.receiver

import app.austial.cast.core.protocol.Crypto

/** Minimal key/value persistence so the trust store can be tested without Android. */
interface KeyValueStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String?)
}

class MapKeyValueStore : KeyValueStore {
    private val map = HashMap<String, String>()
    @Synchronized override fun getString(key: String) = map[key]
    @Synchronized override fun putString(key: String, value: String?) {
        if (value == null) map.remove(key) else map[key] = value
    }
}

/**
 * Persists pairing tokens in a [KeyValueStore] as lines of `deviceId<TAB>hexToken<TAB>name`.
 * Device ids come from the network, so they are hex-encoded to keep the format injection-proof.
 */
class KvTrustStore(private val kv: KeyValueStore, private val key: String = "trusted_devices") : TrustStore {
    private data class Entry(val id: String, val name: String, val token: ByteArray)

    @Synchronized
    private fun load(): MutableList<Entry> {
        val raw = kv.getString(key) ?: return mutableListOf()
        return raw.lineSequence().mapNotNull { line ->
            val parts = line.split('\t')
            if (parts.size != 3) return@mapNotNull null
            try {
                Entry(String(Crypto.unhex(parts[0]), Charsets.UTF_8), String(Crypto.unhex(parts[2]), Charsets.UTF_8), Crypto.unhex(parts[1]))
            } catch (e: IllegalArgumentException) {
                null
            }
        }.toMutableList()
    }

    @Synchronized
    private fun save(entries: List<Entry>) {
        kv.putString(
            key,
            entries.joinToString("\n") {
                Crypto.hex(it.id.toByteArray(Charsets.UTF_8)) + "\t" + Crypto.hex(it.token) + "\t" + Crypto.hex(it.name.toByteArray(Charsets.UTF_8))
            },
        )
    }

    @Synchronized override fun get(deviceId: String): ByteArray? = load().firstOrNull { it.id == deviceId }?.token

    @Synchronized
    override fun put(deviceId: String, name: String, token: ByteArray) {
        val list = load().filter { it.id != deviceId }.toMutableList()
        list.add(Entry(deviceId, name, token))
        save(list)
    }

    @Synchronized override fun remove(deviceId: String) = save(load().filter { it.id != deviceId })
    @Synchronized override fun clear() = kv.putString(key, null)
    @Synchronized override fun list(): List<TrustedDevice> = load().map { TrustedDevice(it.id, it.name) }.sortedBy { it.name.lowercase() }
}
