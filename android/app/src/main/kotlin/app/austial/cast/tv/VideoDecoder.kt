package app.austial.cast.tv

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Surface
import app.austial.cast.core.protocol.AnnexB
import app.austial.cast.core.protocol.VideoFrame
import app.austial.cast.core.receiver.DecodeCounter
import app.austial.cast.core.receiver.PlayoutClock
import app.austial.cast.core.receiver.VideoFrameQueue
import java.util.concurrent.ConcurrentHashMap

/**
 * Hardware H.264 decoder rendering straight to a Surface.
 *
 * Frames are queued by the network thread ([submit]) and fed to MediaCodec from a dedicated thread.
 * If the decoder cannot keep up the backlog is dropped and a keyframe is requested ([onNeedKeyframe]).
 */
class VideoDecoder(
    private val surface: Surface,
    private val width: Int,
    private val height: Int,
    private val parameterSets: AnnexB.ParameterSets,
    private val clock: PlayoutClock,
    private val counter: DecodeCounter,
    private val onNeedKeyframe: () -> Unit,
    private val onError: (Throwable) -> Unit,
) {
    private val queue = VideoFrameQueue(maxFrames = 8)
    private val renderTimes = ConcurrentHashMap<Long, Long>()
    private var codec: MediaCodec? = null
    private var thread: Thread? = null
    @Volatile private var running = false
    @Volatile private var lastKeyframeRequestMs = 0L

    val dropped: Long get() = queue.droppedTotal + inputDrops
    @Volatile private var inputDrops = 0L

    fun start() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(AnnexB.withStartCode(parameterSets.sps)))
            setByteBuffer("csd-1", java.nio.ByteBuffer.wrap(AnnexB.withStartCode(parameterSets.pps)))
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 * 1024 * 1024)
            if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            if (Build.VERSION.SDK_INT >= 23) {
                setInteger(MediaFormat.KEY_PRIORITY, 0) // real-time
                setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
            }
        }
        val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        c.configure(format, surface, null, 0)
        c.start()
        codec = c
        running = true
        thread = Thread({ loop(c) }, "austialcast-video-decoder").also { it.start() }
        requestKeyframe()
    }

    /** Called from the network thread. */
    fun submit(frame: VideoFrame) {
        when (queue.offer(frame)) {
            VideoFrameQueue.Offer.ACCEPTED -> {
                renderTimes[frame.ptsUs] = clock.renderTimeNs(frame.ptsUs, System.nanoTime())
            }
            VideoFrameQueue.Offer.DROPPED, VideoFrameQueue.Offer.OVERFLOW -> requestKeyframe()
        }
    }

    private fun requestKeyframe() {
        val now = System.currentTimeMillis()
        if (now - lastKeyframeRequestMs < 700) return
        lastKeyframeRequestMs = now
        onNeedKeyframe()
    }

    private fun loop(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val frame = queue.poll(6)
                if (frame != null) feed(c, frame)
                drain(c, info)
            }
        } catch (e: Throwable) {
            if (running) {
                Log.e(TAG, "decoder failed", e)
                onError(e)
            }
        }
    }

    private fun feed(c: MediaCodec, frame: VideoFrame) {
        val index = c.dequeueInputBuffer(15_000)
        if (index < 0) {
            inputDrops++
            queue.markNeedsKeyframe()
            requestKeyframe()
            return
        }
        val buffer = c.getInputBuffer(index) ?: return
        buffer.clear()
        if (frame.data.size > buffer.capacity()) {
            c.queueInputBuffer(index, 0, 0, 0, 0)
            inputDrops++
            return
        }
        buffer.put(frame.data)
        val flags = if (frame.keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
        c.queueInputBuffer(index, 0, frame.data.size, frame.ptsUs, flags)
    }

    private fun drain(c: MediaCodec, info: MediaCodec.BufferInfo) {
        while (true) {
            val out = c.dequeueOutputBuffer(info, 0)
            when {
                out >= 0 -> {
                    val renderNs = renderTimes.remove(info.presentationTimeUs) ?: 0L
                    if (renderNs > 0) c.releaseOutputBuffer(out, renderNs) else c.releaseOutputBuffer(out, true)
                    counter.onDecoded()
                    if (renderTimes.size > 64) renderTimes.clear()
                }
                out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED || out == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                else -> return
            }
        }
    }

    fun stop() {
        running = false
        queue.close()
        thread?.join(500)
        thread = null
        try {
            codec?.stop()
        } catch (_: Exception) {
        }
        try {
            codec?.release()
        } catch (_: Exception) {
        }
        codec = null
    }

    /** Ask the codec to flush (used on seek-like events); currently only used internally on resets. */
    fun flush() {
        queue.reset()
        try {
            codec?.flush()
        } catch (_: Exception) {
        }
        val params = Bundle()
        params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
        try {
            codec?.setParameters(params)
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val TAG = "AustialCastVideo"
    }
}
