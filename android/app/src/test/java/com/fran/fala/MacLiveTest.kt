package com.fran.fala

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.net.InetSocketAddress

/** Contra a Fala do Mac verdadeira (FALA_TOKEN=... ./gradlew test). Modo "a" = teste: transcreve e não cola. */
class MacLiveTest {
    private val token = System.getenv("FALA_TOKEN").orEmpty()
    private fun link() = MacLink().apply { this.token = this@MacLiveTest.token; local = InetSocketAddress("127.0.0.1", MacLink.PORT); relayBase = "" }

    @Test fun pingAndAudio() = runBlocking {
        assumeTrue(token.isNotEmpty())
        val l = link()
        val name = l.ping()
        println("ping: $name ${l.latencyMs} ms via ${l.route}")
        assertNotNull(l.lastError, name)
        val wav = File.createTempFile("fala", ".wav")
        ProcessBuilder("say", "-v", "Joana", "Olá, isto é um teste da Fala no Android.", "-o", wav.path, "--data-format=LEI16@16000").start().waitFor()
        val pcm = wav.readBytes().let { it.copyOfRange(it.size - (it.size - 4096).coerceAtLeast(0) / 2 * 2, it.size) } // salta o cabeçalho (com folga)
        val t0 = System.currentTimeMillis()
        val text = l.sendAudio(pcm, enter = false, paste = false, timeoutS = 30.0)
        println("whisper (${System.currentTimeMillis() - t0} ms): $text")
        assertTrue(text.orEmpty().contains("Android", ignoreCase = true))
        assertTrue(l.probeJarvis())
        val r = l.jarvis(org.json.JSONObject().put("op", "list"))!!
        val list = r.optJSONArray("sessions")!!
        println("sessões: " + list.length())
        val id = list.getJSONObject(0).getString("id")
        val tail = l.jarvis(org.json.JSONObject().put("op", "tail").put("id", id).put("limit", 5))!!
        println("tail: " + tail.optJSONArray("messages")?.length() + " mensagens")
        // Envio para uma sessão que não existe: prova que o pedido chega ao SessionHub sem escrever em nenhuma sessão real.
        val bad = l.jarvis(org.json.JSONObject().put("op", "send").put("id", "nao-existe-android-teste").put("text", "teste"))!!
        println("send inválido: ok=${bad.optBoolean("ok")} erro=${bad.optString("error")}")
        assertTrue(!bad.optBoolean("ok") && bad.optString("error").isNotEmpty())
    }

    @Test fun wrongToken() = runBlocking {
        assumeTrue(token.isNotEmpty())
        val l = link().apply { token = "ERRADOERRADOERRADOERRADOAB" }
        assertTrue(l.ping(3.0) == null && l.lastError!!.contains("Código errado"))
    }
}
