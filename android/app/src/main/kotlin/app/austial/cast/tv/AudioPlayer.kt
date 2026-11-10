package app.austial.cast.tv

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import app.austial.cast.core.protocol.AudioFrame
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Decodes raw AAC-LC access units and plays them through an AudioTrack. */
class AudioPlayer(
    private val sampleRate: Int,
    private val channels: Int,
    private val audioSpecificConfig: ByteArray,
    private val onError: (Throwable) -> Unit,
) {
    private val queue = LinkedBlockingQueue<AudioFrame>()
    private var codec: MediaCodec? = null
    private var track: AudioTrack? = null
    private var thread: Thread? = null
    @Volatile private var running = false

    fun start() {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(audioSpecificConfig))
            setInteger(MediaFormat.KEY_AAC_PROFILE, 2) // AAC-LC
            setInteger(MediaFormat.KEY_IS_ADTS, 0)
        }
        val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        c.configure(format, null, null, 0)
        c.start()
        codec = c

        val mask = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val minBuffer = AudioTrack.getMinBufferSize(sampleRate, mask, AudioFormat.ENCODING_PCM_16BIT)
        val builder = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(sampleRate).setChannelMask(mask).build())
            .setBufferSizeInBytes(maxOf(minBuffer * 2, sampleRate / 5 * channels * 2))
            .setTransferMode(AudioTrack.MODE_STREAM)
        if (Build.VERSION.SDK_INT >= 26) builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        val t = builder.build()
        t.play()
        track = t

        running = true
        thread = Thread({ loop(c, t) }, "austialcast-audio").also { it.start() }
    }

    fun submit(frame: AudioFrame) {
        // Keep audio latency bounded: if the decoder is far behind, drop the oldest packets.
        while (queue.size > MAX_QUEUED) queue.poll()
        queue.offer(frame)
    }

    private fun loop(c: MediaCodec, t: AudioTrack) {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val frame = queue.poll(10, TimeUnit.MILLISECONDS)
                if (frame != null) {
                    val index = c.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val buf = c.getInputBuffer(index)!!
                        buf.clear()
                        buf.put(frame.data)
                        c.queueInputBuffer(index, 0, frame.data.size, frame.ptsUs, 0)
                    }
                }
                while (true) {
                    val out = c.dequeueOutputBuffer(info, 0)
                    if (out >= 0) {
                        val buf = c.getOutputBuffer(out)
                        if (buf != null && info.size > 0) {
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            t.write(buf, info.size, AudioTrack.WRITE_BLOCKING)
                        }
                        c.releaseOutputBuffer(out, false)
                    } else if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED || out == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) {
                        continue
                    } else break
                }
            }
        } catch (e: Throwable) {
            if (running) {
                Log.e(TAG, "audio failed", e)
                onError(e)
            }
        }
    }

    fun stop() {
        running = false
        thread?.join(500)
        thread = null
        try {
            track?.pause(); track?.flush(); track?.release()
        } catch (_: Exception) {
        }
        try {
            codec?.stop(); codec?.release()
        } catch (_: Exception) {
        }
        track = null
        codec = null
        queue.clear()
    }

    companion object {
        private const val TAG = "AustialCastAudio"
        private const val MAX_QUEUED = 40 // ~0.85 s of AAC
    }
}
