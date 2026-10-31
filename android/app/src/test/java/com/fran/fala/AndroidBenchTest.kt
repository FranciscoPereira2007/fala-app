package com.fran.fala

import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Benchmark do caminho Android -> Mac (FALA_BENCH=1 FALA_TOKEN=... ./gradlew test --tests '*AndroidBench*').
 * Mesmo corpus do research/stt-benchmark; variantes: normal, baixo (-55 dBFS, como o Poco a 1 m) (o ganho é feito no Mac).
 */
class AndroidBenchTest {
    private fun pcm(f: File): ByteArray {
        val b = f.readBytes(); var i = 12
        while (i + 8 <= b.size) {
            val id = String(b, i, 4); val n = ByteBuffer.wrap(b, i + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
            if (id == "data") return b.copyOfRange(i + 8, minOf(b.size, i + 8 + n))
            i += 8 + n
        }
        return ByteArray(0)
    }
    private fun scale(p: ByteArray, k: Double): ByteArray {
        val s = ByteBuffer.wrap(p).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer(); val o = ByteBuffer.allocate(p.size).order(ByteOrder.LITTLE_ENDIAN)
        while (s.hasRemaining()) o.putShort((s.get() * k).toInt().toShort())
        return o.array()
    }

    @Test fun bench() = runBlocking {
        assumeTrue(System.getenv("FALA_BENCH") == "1")
        val root = File(System.getProperty("user.dir")).let { if (it.name == "app") it.parentFile else it }.resolve("../research/stt-benchmark")
        val l = MacLink().apply { token = System.getenv("FALA_TOKEN"); local = InetSocketAddress("127.0.0.1", MacLink.PORT); relayBase = "" }
        val dir = System.getenv("FALA_BENCH_DIR") ?: "audio" // audio-en: inglês e misto
        val files = root.resolve(dir).listFiles { f -> f.name.endsWith(".wav") }!!.sorted()
        val all = listOf<Pair<String, (ByteArray) -> ByteArray>>("android-normal" to { it }, "android-baixo" to { scale(it, 0.03) })
        // FALA_BENCH_ONLY=android-baixo FALA_BENCH_TAG=mac-ganho: repete só uma variante e grava com outro nome (antes/depois de mudar o Mac).
        val only = System.getenv("FALA_BENCH_ONLY"); val tag = System.getenv("FALA_BENCH_TAG")
        for ((name, f) in all.filter { only == null || it.first == only }) {
            val engine = if (tag != null) "$name-$tag" else name
            val out = root.resolve("results/$engine.jsonl").printWriter()
            for (w in files) {
                val p = f(pcm(w)); val t0 = System.currentTimeMillis()
                val t = l.sendAudio(p, enter = false, paste = false, timeoutS = 30.0).orEmpty()
                out.println(JSONObject().put("file", w.name).put("engine", engine).put("raw", t).put("clean", t).put("secs", (System.currentTimeMillis() - t0) / 1000.0).put("audio", p.size / 32000.0))
                out.flush()
            }
            out.close()
        }
    }
}
