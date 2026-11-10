package app.austial.cast.tv

import android.content.Context
import android.view.SurfaceView
import android.view.View

/** A SurfaceView that sizes itself to the video's aspect ratio (fit = letterbox, fill = crop). */
class AspectSurfaceView(context: Context) : SurfaceView(context) {
    private var videoWidth = 0
    private var videoHeight = 0
    var scaleMode: ScaleMode = ScaleMode.FIT
        set(value) {
            field = value
            requestLayout()
        }

    fun setVideoSize(w: Int, h: Int) {
        if (w == videoWidth && h == videoHeight) return
        videoWidth = w
        videoHeight = h
        requestLayout()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val availW = View.getDefaultSize(0, widthMeasureSpec)
        val availH = View.getDefaultSize(0, heightMeasureSpec)
        val (w, h) = fitSize(videoWidth, videoHeight, availW, availH, scaleMode == ScaleMode.FILL)
        setMeasuredDimension(w, h)
    }

    companion object {
        /** Pure sizing logic, unit-tested. Returns the view size inside an `availW x availH` box. */
        fun fitSize(videoW: Int, videoH: Int, availW: Int, availH: Int, fill: Boolean): Pair<Int, Int> {
            if (videoW <= 0 || videoH <= 0 || availW <= 0 || availH <= 0) return availW to availH
            val videoRatio = videoW.toDouble() / videoH
            val boxRatio = availW.toDouble() / availH
            val useWidth = if (fill) boxRatio < videoRatio else boxRatio > videoRatio
            return if (useWidth) {
                // Box is wider than the video (fit) or narrower (fill): match the height.
                (availH * videoRatio).toInt() to availH
            } else {
                availW to (availW / videoRatio).toInt()
            }
        }
    }
}
