package app.austial.cast.tv

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import app.austial.cast.core.receiver.KeyValueStore
import java.util.UUID

enum class ScaleMode(val label: String) { FIT("Fit (show everything)"), FILL("Fill (crop edges)") }

enum class Smoothness(val label: String, val bufferMs: Int) {
    LOWEST("Lowest latency (best for mouse and games)", 0),
    BALANCED("Balanced (60 ms buffer)", 60),
    SMOOTH("Smooth video (150 ms buffer)", 150),
}

/** User-facing preferences, stored in SharedPreferences. */
class TvSettings(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("austialcast", Context.MODE_PRIVATE)

    val deviceId: String
        get() = prefs.getString("device_id", null) ?: UUID.randomUUID().toString().also { prefs.edit().putString("device_id", it).apply() }

    var deviceName: String
        get() = prefs.getString("device_name", null)?.takeIf { it.isNotBlank() } ?: defaultName()
        set(v) = prefs.edit().putString("device_name", v.trim().take(40)).apply()

    /** Remember paired Macs so later casts need no PIN. */
    var rememberDevices: Boolean
        get() = prefs.getBoolean("remember_devices", true)
        set(v) = prefs.edit().putBoolean("remember_devices", v).apply()

    /** A new cast replaces the one in progress instead of being rejected. */
    var allowTakeover: Boolean
        get() = prefs.getBoolean("allow_takeover", false)
        set(v) = prefs.edit().putBoolean("allow_takeover", v).apply()

    var scaleMode: ScaleMode
        get() = ScaleMode.entries.getOrNull(prefs.getInt("scale_mode", 0)) ?: ScaleMode.FIT
        set(v) = prefs.edit().putInt("scale_mode", v.ordinal).apply()

    var smoothness: Smoothness
        get() = Smoothness.entries.getOrNull(prefs.getInt("smoothness", 0)) ?: Smoothness.LOWEST
        set(v) = prefs.edit().putInt("smoothness", v.ordinal).apply()

    var alwaysShowStats: Boolean
        get() = prefs.getBoolean("always_stats", false)
        set(v) = prefs.edit().putBoolean("always_stats", v).apply()

    val keyValueStore: KeyValueStore = object : KeyValueStore {
        override fun getString(key: String): String? = prefs.getString("kv_$key", null)
        override fun putString(key: String, value: String?) {
            prefs.edit().apply { if (value == null) remove("kv_$key") else putString("kv_$key", value) }.apply()
        }
    }

    private fun defaultName(): String {
        val model = Build.MODEL?.takeIf { it.isNotBlank() } ?: "TV"
        return model.take(30)
    }
}
