package app.austial.cast.tv

import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.KeyEvent
import android.view.SurfaceHolder
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import app.austial.cast.core.receiver.Phase
import app.austial.cast.core.receiver.UiState
import app.austial.cast.core.receiver.formatPin

/**
 * The only screen shown while casting. Layers (back to front): video surface, idle/pairing screen,
 * stats overlay, "paused" badge. The idle layer is opaque and hides the surface until a cast starts.
 */
class MainActivity : android.app.Activity(), ReceiverController.Observer, SurfaceHolder.Callback {
    private lateinit var controller: ReceiverController
    private lateinit var surfaceView: AspectSurfaceView
    private lateinit var idleLayer: LinearLayout
    private lateinit var titleView: TextView
    private lateinit var nameView: TextView
    private lateinit var pinView: TextView
    private lateinit var hintView: TextView
    private lateinit var addressView: TextView
    private lateinit var noticeView: TextView
    private lateinit var statsView: TextView
    private lateinit var pausedBadge: TextView
    private lateinit var settingsButton: TextView
    private val handler = Handler(Looper.getMainLooper())
    private var lastBackMs = 0L
    private var lastState: UiState? = null
    private var statsToggled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        controller = tvApp.controller
        window.setFormat(PixelFormat.TRANSLUCENT)
        buildUi()
    }

    private fun buildUi() {
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }

        surfaceView = AspectSurfaceView(this).apply {
            layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT, Gravity.CENTER)
            holder.addCallback(this@MainActivity)
        }
        root.addView(surfaceView)

        idleLayer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Ui.BACKGROUND)
            setPadding(Ui.dp(context, 48), Ui.dp(context, 32), Ui.dp(context, 48), Ui.dp(context, 32))
            layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        }
        titleView = Ui.text(this, "AustialCast", 44f, Ui.TEXT, bold = true)
        nameView = Ui.text(this, "", 22f, Ui.ACCENT)
        hintView = Ui.text(this, "On your Mac, open AustialCast, choose this TV and enter this PIN:", 20f, Ui.TEXT_DIM).apply { gravity = Gravity.CENTER }
        pinView = Ui.text(this, "", 96f, Ui.TEXT, bold = true).apply {
            letterSpacing = 0.12f
            typeface = android.graphics.Typeface.MONOSPACE
        }
        addressView = Ui.text(this, "", 18f, Ui.TEXT_DIM).apply { gravity = Gravity.CENTER }
        noticeView = Ui.text(this, "", 20f, Ui.WARNING).apply { gravity = Gravity.CENTER; visibility = View.GONE }
        settingsButton = Ui.button(this, "Settings") { startActivity(Intent(this, SettingsActivity::class.java)) }

        for ((view, bottom) in listOf(titleView to 4, nameView to 28, hintView to 8, pinView to 12, addressView to 20, noticeView to 20)) {
            idleLayer.addView(view, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = Ui.dp(this@MainActivity, bottom)
            })
        }
        idleLayer.addView(settingsButton, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            gravity = Gravity.CENTER_HORIZONTAL
        })
        root.addView(idleLayer)

        statsView = Ui.text(this, "", 16f, Ui.TEXT).apply {
            setBackgroundColor(Color.argb(170, 0, 0, 0))
            setPadding(Ui.dp(context, 14), Ui.dp(context, 8), Ui.dp(context, 14), Ui.dp(context, 8))
            visibility = View.GONE
            layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START).apply {
                setMargins(Ui.dp(context, 24), Ui.dp(context, 20), 0, 0)
            }
        }
        root.addView(statsView)

        pausedBadge = Ui.text(this, "⏸  Paused by Mac", 28f, Ui.TEXT, bold = true).apply {
            setBackgroundColor(Color.argb(200, 0, 0, 0))
            setPadding(Ui.dp(context, 28), Ui.dp(context, 16), Ui.dp(context, 28), Ui.dp(context, 16))
            visibility = View.GONE
            layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER)
        }
        root.addView(pausedBadge)

        setContentView(root)
    }

    override fun onStart() {
        super.onStart()
        controller.start()
        controller.addObserver(this)
        surfaceView.scaleMode = tvApp.settings.scaleMode
        controller.applySettings()
    }

    override fun onStop() {
        controller.removeObserver(this)
        controller.disconnect()
        controller.setSurface(null)
        controller.stop()
        super.onStop()
    }

    // ---- ReceiverController.Observer ----------------------------------------------------

    override fun onUiState(state: UiState) {
        lastState = state
        val streaming = state.phase == Phase.STREAMING || state.phase == Phase.PAUSED
        idleLayer.visibility = if (streaming) View.GONE else View.VISIBLE
        pausedBadge.visibility = if (state.phase == Phase.PAUSED) View.VISIBLE else View.GONE
        if (streaming) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            surfaceView.setVideoSize(state.width, state.height)
            surfaceView.scaleMode = tvApp.settings.scaleMode
            val show = statsToggled || tvApp.settings.alwaysShowStats
            statsView.visibility = if (show) View.VISIBLE else View.GONE
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            statsView.visibility = View.GONE
        }
        nameView.text = "Cast to “${state.deviceName}”"
        when (state.phase) {
            Phase.CONNECTING -> {
                hintView.text = "Pairing with ${state.peerName ?: "your device"}…"
                pinView.text = formatPin(state.pin)
            }
            else -> {
                hintView.text = "On your Mac, open AustialCast, choose this TV and enter this PIN:"
                pinView.text = formatPin(state.pin)
            }
        }
        val notice = state.notice
        noticeView.visibility = if (notice.isNullOrEmpty()) View.GONE else View.VISIBLE
        noticeView.text = notice.orEmpty()
        if (!streaming) settingsButton.requestFocus()
    }

    override fun onStatsText(text: String) {
        statsView.text = text
    }

    override fun onAddress(address: String) {
        addressView.text = "Or connect manually to  $address"
    }

    // ---- surface -------------------------------------------------------------------------

    override fun surfaceCreated(holder: SurfaceHolder) {
        controller.setSurface(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        controller.setSurface(null)
    }

    // ---- remote control ------------------------------------------------------------------

    private val streaming: Boolean get() = lastState?.phase == Phase.STREAMING || lastState?.phase == Phase.PAUSED

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0 && streaming) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_BACK -> {
                    val now = System.currentTimeMillis()
                    if (now - lastBackMs < 2000) {
                        controller.disconnect()
                    } else {
                        lastBackMs = now
                        Toast.makeText(this, "Press Back again to stop casting", Toast.LENGTH_SHORT).show()
                    }
                    return true
                }
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_MENU, KeyEvent.KEYCODE_INFO -> {
                    statsToggled = !statsToggled
                    statsView.visibility = if (statsToggled || tvApp.settings.alwaysShowStats) View.VISIBLE else View.GONE
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onResume() {
        super.onResume()
        surfaceView.scaleMode = tvApp.settings.scaleMode
        controller.applySettings()
    }
}
