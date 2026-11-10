package app.austial.cast.tv

import android.app.Application

class AustialCastApp : Application() {
    lateinit var settings: TvSettings
        private set
    lateinit var controller: ReceiverController
        private set

    override fun onCreate() {
        super.onCreate()
        settings = TvSettings(this)
        controller = ReceiverController(this, settings)
    }
}

val android.content.Context.tvApp: AustialCastApp get() = applicationContext as AustialCastApp
