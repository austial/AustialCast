package app.austial.cast.core.receiver

import java.net.Inet4Address
import java.net.NetworkInterface

/** A candidate local address with the name of its network interface. */
data class LocalAddress(val interfaceName: String, val host: String, val isSiteLocal: Boolean, val isLoopback: Boolean)

object NetUtil {
    /**
     * Picks the address a sender on the LAN should use. Prefers Wi-Fi / Ethernet site-local IPv4
     * addresses over VPN, mobile, link-local or loopback ones.
     */
    fun pickBest(candidates: List<LocalAddress>): String? {
        fun score(a: LocalAddress): Int {
            if (a.isLoopback) return -1
            var s = 0
            if (a.isSiteLocal) s += 10
            val n = a.interfaceName.lowercase()
            if (n.startsWith("wlan") || n.startsWith("eth") || n.startsWith("en")) s += 5
            if (n.startsWith("tun") || n.startsWith("ppp") || n.startsWith("rmnet") || n.startsWith("dummy")) s -= 5
            if (a.host.startsWith("169.254.")) s -= 20
            return s
        }
        return candidates.filter { score(it) >= 0 }.maxByOrNull { score(it) }?.host
    }

    fun localIpv4Addresses(): List<LocalAddress> = try {
        NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp }.flatMap { ni ->
            ni.inetAddresses.toList().filterIsInstance<Inet4Address>().map {
                LocalAddress(ni.name, it.hostAddress ?: "", it.isSiteLocalAddress, it.isLoopbackAddress)
            }
        }
    } catch (e: Exception) {
        emptyList()
    }

    fun bestLocalAddress(): String? = pickBest(localIpv4Addresses())
}
