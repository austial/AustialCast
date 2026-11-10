package app.austial.cast.tv

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import app.austial.cast.core.protocol.SERVICE_TYPE

/** Advertises the receiver on the LAN with mDNS/Bonjour so Macs can find it automatically. */
class NsdAdvertiser(context: Context) {
    private val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var listener: NsdManager.RegistrationListener? = null

    @Synchronized
    fun register(name: String, deviceId: String, port: Int) {
        unregister()
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("id", deviceId)
            setAttribute("name", name)
            setAttribute("v", "1")
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "advertising as ${info.serviceName}")
            }
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "registration failed: $errorCode")
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
        }
        listener = l
        try {
            manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: Exception) {
            Log.w(TAG, "could not register NSD service", e)
            listener = null
        }
    }

    @Synchronized
    fun unregister() {
        val l = listener ?: return
        listener = null
        try {
            manager.unregisterService(l)
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val TAG = "AustialCastNsd"
    }
}
