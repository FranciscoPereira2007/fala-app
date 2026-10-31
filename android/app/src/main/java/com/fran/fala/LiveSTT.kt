package com.fran.fala

import android.content.Context
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.StorageService

/**
 * Texto ao vivo no próprio telemóvel, palavra a palavra (o iPhone usa o reconhecimento da Apple para isto).
 * Vosk pt pequeno, grátis e sem internet. Só para mostrar enquanto falas: o texto final é o do Whisper do Mac.
 */
object LiveSTT {
    @Volatile private var model: Model? = null
    @Volatile private var rec: Recognizer? = null
    private var done = ""
    val ready get() = model != null

    fun init(c: Context) {
        // Os assets vêm no APK; na 1.ª vez copia-os para o disco (o Vosk lê ficheiros). Sem modelo: fica a pré-visualização pelo Mac.
        runCatching { StorageService.unpack(c, "model-pt", "model-pt", { model = it }, { android.util.Log.w("fala-live", "vosk: $it") }) }
    }

    /** Começa a ouvir o micro do Recorder; `onText` recebe o texto todo até agora (na thread principal). */
    fun begin(onText: (String) -> Unit): Boolean {
        val m = model ?: return false
        val r = runCatching { Recognizer(m, 16000f) }.getOrNull() ?: return false
        rec = r; done = ""
        // O micro nunca espera pelo Vosk: os blocos vão para uma fila e o reconhecimento corre noutra thread.
        val q = java.util.concurrent.LinkedBlockingQueue<ByteArray>()
        Recorder.onChunk = { b, n -> q.offer(b.copyOf(n)) }
        Thread({
            var last = 0L; var fed = 0
            while (rec === r) {
                val b = q.poll(200, java.util.concurrent.TimeUnit.MILLISECONDS) ?: continue
                // Junta o que estiver em fila (se o telemóvel atrasar, apanha logo o atraso em vez de acumular).
                val all = java.io.ByteArrayOutputStream().apply { write(b); while (true) write(q.poll() ?: break) }.toByteArray()
                val g = ByteArray(all.size)
                for (i in 0 until all.size / 2) {
                    val v = ((all[2 * i].toInt() and 0xff) or (all[2 * i + 1].toInt() shl 8)) * 3 // micro do Poco baixo
                    val c = v.coerceIn(-32768, 32767); g[2 * i] = c.toByte(); g[2 * i + 1] = (c shr 8).toByte()
                }
                val t0 = System.currentTimeMillis()
                val text = synchronized(this) {
                    val rr = rec ?: return@synchronized null
                    if (rr.acceptWaveForm(g, g.size)) { done = join(done, JSONObject(rr.result).optString("text")); done }
                    else join(done, JSONObject(rr.partialResult).optString("partial"))
                } ?: break
                fed += g.size
                if (System.currentTimeMillis() - last > 1000) { last = System.currentTimeMillis(); android.util.Log.d("fala-live", "${fed / 32000.0}s áudio, bloco ${g.size / 32} ms em ${System.currentTimeMillis() - t0} ms, fila ${q.size}: $text") }
                Fala.main.post { if (rec === r) onText(text) }
            }
        }, "fala-vosk").start()
        return true
    }

    fun end() { Recorder.onChunk = null; synchronized(this) { rec?.close(); rec = null } }

    private fun join(a: String, b: String) = listOf(a, b).filter { it.isNotBlank() }.joinToString(" ").replaceFirstChar { it.uppercase() }
}
