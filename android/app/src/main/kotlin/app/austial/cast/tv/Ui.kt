package app.austial.cast.tv

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView

/** Tiny view helpers so the TV UI stays readable from across the room and fully D-pad navigable. */
object Ui {
    val BACKGROUND = Color.parseColor("#0B0F1A")
    val SURFACE = Color.parseColor("#161C2D")
    val SURFACE_FOCUSED = Color.parseColor("#26304D")
    val ACCENT = Color.parseColor("#6C8CFF")
    val TEXT = Color.parseColor("#F2F5FF")
    val TEXT_DIM = Color.parseColor("#9AA6C7")
    val WARNING = Color.parseColor("#FFB86B")

    fun dp(context: Context, v: Int): Int = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), context.resources.displayMetrics).toInt()

    fun text(context: Context, value: String, sp: Float, color: Int = TEXT, bold: Boolean = false): TextView = TextView(context).apply {
        text = value
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        setTextColor(color)
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    private fun roundedRect(context: Context, color: Int, stroke: Int? = null): GradientDrawable = GradientDrawable().apply {
        cornerRadius = dp(context, 14).toFloat()
        setColor(color)
        if (stroke != null) setStroke(dp(context, 3), stroke)
    }

    /** A focusable "button" whose focus state is clearly visible on a TV. */
    fun button(context: Context, label: String, onClick: () -> Unit): TextView = TextView(context).apply {
        text = label
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
        setTextColor(TEXT)
        gravity = Gravity.CENTER
        isFocusable = true
        isClickable = true
        setPadding(dp(context, 28), dp(context, 14), dp(context, 28), dp(context, 14))
        background = StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_focused), roundedRect(context, SURFACE_FOCUSED, ACCENT))
            addState(intArrayOf(), roundedRect(context, SURFACE))
        }
        setOnClickListener { onClick() }
    }

    /** A settings row: title on the left, current value on the right. */
    fun row(context: Context, title: String, value: () -> String, onClick: (refresh: () -> Unit) -> Unit): LinearLayout {
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isFocusable = true
            isClickable = true
            setPadding(dp(context, 24), dp(context, 16), dp(context, 24), dp(context, 16))
            background = StateListDrawable().apply {
                addState(intArrayOf(android.R.attr.state_focused), roundedRect(context, SURFACE_FOCUSED, ACCENT))
                addState(intArrayOf(), roundedRect(context, SURFACE))
            }
        }
        val titleView = text(context, title, 20f).apply { layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) }
        val valueView = text(context, value(), 18f, TEXT_DIM).apply { gravity = Gravity.END }
        row.addView(titleView)
        row.addView(valueView)
        val refresh = { valueView.text = value() }
        row.setOnClickListener { onClick(refresh) }
        return row
    }

    fun spacer(context: Context, heightDp: Int): View = View(context).apply {
        layoutParams = LinearLayout.LayoutParams(1, dp(context, heightDp))
    }
}
