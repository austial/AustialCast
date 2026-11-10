package app.austial.cast.tv

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Toast

/** Remote-friendly settings: every row is focusable and opens a simple dialog or toggles. */
class SettingsActivity : Activity() {
    private val settings by lazy { tvApp.settings }
    private val controller by lazy { tvApp.controller }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(Ui.dp(context, 64), Ui.dp(context, 32), Ui.dp(context, 64), Ui.dp(context, 32))
        }
        list.addView(Ui.text(this, "Settings", 36f, Ui.TEXT, bold = true))
        list.addView(Ui.spacer(this, 16))

        fun add(row: LinearLayout) {
            list.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = Ui.dp(this@SettingsActivity, 10)
            })
        }
        fun onOff(b: Boolean) = if (b) "On" else "Off"

        add(Ui.row(this, "TV name", { settings.deviceName }) { refresh -> askName(refresh) })
        add(Ui.row(this, "Remember paired devices (no PIN next time)", { onOff(settings.rememberDevices) }) { refresh ->
            settings.rememberDevices = !settings.rememberDevices
            controller.applySettings(); refresh()
        })
        add(Ui.row(this, "Let a new cast replace the current one", { onOff(settings.allowTakeover) }) { refresh ->
            settings.allowTakeover = !settings.allowTakeover
            controller.applySettings(); refresh()
        })
        add(Ui.row(this, "Picture scaling", { settings.scaleMode.label }) { refresh ->
            choose("Picture scaling", ScaleMode.entries.map { it.label }, settings.scaleMode.ordinal) {
                settings.scaleMode = ScaleMode.entries[it]; refresh()
            }
        })
        add(Ui.row(this, "Smoothness", { settings.smoothness.label }) { refresh ->
            choose("Smoothness", Smoothness.entries.map { it.label }, settings.smoothness.ordinal) {
                settings.smoothness = Smoothness.entries[it]; controller.applySettings(); refresh()
            }
        })
        add(Ui.row(this, "Always show statistics while casting", { onOff(settings.alwaysShowStats) }) { refresh ->
            settings.alwaysShowStats = !settings.alwaysShowStats; refresh()
        })
        add(Ui.row(this, "Paired devices", { "${controller.trusted.list().size} paired" }) { refresh -> managePaired(refresh) })
        add(Ui.row(this, "About", { "AustialCast ${versionName()}" }) { _ ->
            AlertDialog.Builder(this)
                .setTitle("AustialCast ${versionName()}")
                .setMessage("Cast your MacBook to this TV.\n\nAddress: ${controller.addressLine()}\nDevice id: ${settings.deviceId}\n\nVideo is H.264, audio AAC; the connection is end-to-end encrypted with a key exchanged at pairing.")
                .setPositiveButton("OK", null).show()
        })

        setContentView(ScrollView(this).apply {
            setBackgroundColor(Ui.BACKGROUND)
            isFillViewport = true
            addView(list)
        })
    }

    private fun versionName(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName ?: "1.0"
    } catch (e: Exception) {
        "1.0"
    }

    private fun askName(refresh: () -> Unit) {
        val input = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT
            setText(settings.deviceName)
            setSelection(text.length)
            gravity = Gravity.START
        }
        AlertDialog.Builder(this)
            .setTitle("TV name shown on your Mac")
            .setView(input)
            .setPositiveButton("Save") { _, _ ->
                val name = input.text.toString().trim()
                if (name.isNotEmpty()) {
                    settings.deviceName = name
                    controller.applySettings()
                    refresh()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun choose(title: String, labels: List<String>, current: Int, onPick: (Int) -> Unit) {
        AlertDialog.Builder(this)
            .setTitle(title)
            .setSingleChoiceItems(labels.toTypedArray(), current) { dialog, which ->
                onPick(which)
                dialog.dismiss()
            }
            .show()
    }

    private fun managePaired(refresh: () -> Unit) {
        val devices = controller.trusted.list()
        if (devices.isEmpty()) {
            Toast.makeText(this, "No paired devices yet", Toast.LENGTH_SHORT).show()
            return
        }
        val labels = devices.map { it.name } + "Forget all devices"
        AlertDialog.Builder(this)
            .setTitle("Tap a device to forget it")
            .setItems(labels.toTypedArray()) { _, which ->
                if (which == devices.size) controller.trusted.clear() else controller.trusted.remove(devices[which].deviceId)
                refresh()
            }
            .setNegativeButton("Close", null)
            .show()
    }
}
