package app.austial.cast.core.cli

import app.austial.cast.core.protocol.AnnexB
import app.austial.cast.core.protocol.AudioFrame
import app.austial.cast.core.protocol.DEFAULT_PORT
import app.austial.cast.core.protocol.StreamStart
import app.austial.cast.core.protocol.VideoFrame
import app.austial.cast.core.receiver.EndReason
import app.austial.cast.core.receiver.InMemoryTrustStore
import app.austial.cast.core.receiver.PeerInfo
import app.austial.cast.core.receiver.PinManager
import app.austial.cast.core.receiver.ReceiverConfig
import app.austial.cast.core.receiver.ReceiverListener
import app.austial.cast.core.receiver.ReceiverServer
import app.austial.cast.core.receiver.StreamStats
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicLong
import kotlin.system.exitProcess

/**
 * Headless receiver for development and end-to-end tests. It runs the exact same server code as
 * the Android TV app but writes the received media to disk instead of decoding it.
 *
 *   --port N          TCP port (default 7391)
 *   --pin 123456      fixed PIN instead of a random one (the PIN still rotates after each attempt
 *                     unless --fixed-pin is given)
 *   --fixed-pin       never rotate the PIN (tests only)
 *   --dump FILE       write the Annex-B video elementary stream to FILE
 *   --audio-dump FILE write raw AAC access units (length-prefixed) to FILE
 *   --expect-frames N exit successfully once N video frames were received and the stream ended
 *   --timeout SEC     exit with an error if nothing completes in SEC seconds
 */
fun main(args: Array<String>) {
    val opts = parseArgs(args)
    val port = opts["port"]?.toInt() ?: DEFAULT_PORT
    val dump = opts["dump"]?.let { FileOutputStream(File(it)) }
    val audioDump = opts["audio-dump"]?.let { FileOutputStream(File(it)) }
    val expectFrames = opts["expect-frames"]?.toLong()
    val timeoutSec = opts["timeout"]?.toLong() ?: 0L
    val done = CountDownLatch(1)
    val frames = AtomicLong()
    val audioFrames = AtomicLong()
    val keyframes = AtomicLong()
    val stats = StreamStats()
    var failure: String? = null

    val listener = object : ReceiverListener {
        override fun onListening(port: Int) = println("LISTENING $port")
        override fun onPinChanged(pin: String) = println("PIN $pin")
        override fun onPeerConnecting(peer: PeerInfo) = println("CONNECTING ${peer.name} (${peer.platform}) ${peer.remoteAddress}")
        override fun onAuthenticated(peer: PeerInfo, viaToken: Boolean) = println("AUTHENTICATED ${peer.name} token=$viaToken")
        override fun onAuthFailed(peer: PeerInfo?, reason: String) = println("AUTH_FAILED $reason")
        override fun onStreamStarted(peer: PeerInfo, info: StreamStart) =
            println("STREAM ${info.width}x${info.height}@${info.fps} ${info.bitrate / 1000}kbps audio=${info.audio != null}")

        override fun onVideoConfig(config: ByteArray) {
            if (dump != null && frames.get() == 0L) dump.write(config)
        }

        override fun onVideoFrame(frame: VideoFrame) {
            frames.incrementAndGet()
            if (frame.keyframe) keyframes.incrementAndGet()
            if (frame.keyframe != AnnexB.containsIdr(frame.data)) {
                println("WARN keyframe flag disagrees with bitstream at frame ${frames.get()}")
            }
            stats.onVideoFrame(frame.data.size)
            dump?.write(frame.data)
        }

        override fun onAudioFrame(frame: AudioFrame) {
            audioFrames.incrementAndGet()
            audioDump?.let {
                it.write(frame.data.size ushr 8)
                it.write(frame.data.size and 0xff)
                it.write(frame.data)
            }
        }

        override fun onPaused(paused: Boolean) = println(if (paused) "PAUSED" else "RESUMED")

        override fun onStreamEnded(peer: PeerInfo, reason: EndReason) {
            println("ENDED $reason frames=${frames.get()} keyframes=${keyframes.get()} audio=${audioFrames.get()}")
            if (expectFrames != null) {
                if (frames.get() < expectFrames) failure = "expected $expectFrames frames, got ${frames.get()}"
                done.countDown()
            }
        }

        override fun onConnectionClosed(peer: PeerInfo?, reason: EndReason) = println("CLOSED $reason")
        override fun onError(error: Throwable) = println("ERROR ${error.message}")
    }

    val fixedPin = opts["pin"]
    val pins = PinManager(onChange = {}, fixedPin = if (opts.containsKey("fixed-pin")) fixedPin else null)
    val server = ReceiverServer(
        ReceiverConfig(
            deviceId = UUID.randomUUID().toString(),
            deviceName = opts["name"] ?: "AustialCast CLI Receiver",
            port = port,
            allowPreempt = opts.containsKey("preempt"),
        ),
        InMemoryTrustStore(),
        listener,
        pins,
    )
    server.start()
    println("PIN ${server.currentPin}")
    System.out.flush()

    if (timeoutSec > 0) {
        Thread {
            Thread.sleep(timeoutSec * 1000)
            println("TIMEOUT")
            exitProcess(2)
        }.also { it.isDaemon = true }.start()
    }
    Runtime.getRuntime().addShutdownHook(Thread { dump?.close(); audioDump?.close() })
    done.await()
    server.stop()
    dump?.close()
    audioDump?.close()
    if (failure != null) {
        println("FAIL $failure")
        exitProcess(1)
    }
    println("OK")
}

private fun parseArgs(args: Array<String>): Map<String, String> {
    val map = HashMap<String, String>()
    var i = 0
    while (i < args.size) {
        val a = args[i]
        if (a.startsWith("--")) {
            val key = a.removePrefix("--")
            if (i + 1 < args.size && !args[i + 1].startsWith("--")) {
                map[key] = args[i + 1]
                i += 2
                continue
            }
            map[key] = ""
        }
        i++
    }
    return map
}
