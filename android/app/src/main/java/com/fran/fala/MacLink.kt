package com.fran.fala

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL

/**
 * Lado telemóvel do protocolo v2 (igual a Shared/MacSender.swift): rede local (Bonjour), endereço guardado
 * (Tailscale) e relay. Mesmo id em todas as tentativas: repetir é seguro, o Mac nunca cola duas vezes.
 */
class MacLink {
    var token = ""
    var host = ""
    var relayBase = "https://fala-relay.fancy-bird-92d5.workers.dev"
    /** Mac encontrado por Bonjour (NsdManager no Android). */
    var local: InetSocketAddress? = null
    var onlyRelay = false

    var macName by mutableStateOf<String?>(null)
    var lastError by mutableStateOf<String?>(null)
    var route by mutableStateOf<String?>(null)
    var latencyMs by mutableStateOf<Int?>(null)
    var lastSeen by mutableStateOf(0L)
    var pending by mutableIntStateOf(0)
    var jarvisReady by mutableStateOf(false)

    val paired get() = token.isNotEmpty()
    val hasMac get() = paired && (local != null || host.isNotEmpty() || relayBase.isNotEmpty())
    val label: String
        get() {
            val r = route
            if (r != null && System.currentTimeMillis() - lastSeen < 120_000) return "Ligado via $r" + (latencyMs?.let { " · $it ms" } ?: "")
            return macName ?: if (host.isEmpty()) "À procura do Mac…" else "Remoto: $host"
        }

    private class Cand(val addr: InetSocketAddress?, val route: String) // addr null = relay

    private val candidates: List<Cand>
        get() {
            if (onlyRelay) return if (relayBase.isNotEmpty()) listOf(Cand(null, "internet")) else emptyList()
            val c = mutableListOf<Cand>()
            local?.let { c += Cand(it, "rede local") }
            if (host.isNotEmpty()) {
                val parts = host.split(":")
                val name = parts[0]
                val port = parts.getOrNull(1)?.toIntOrNull() ?: PORT
                val ts = name.endsWith(".ts.net") || name.startsWith("100.") || !name.contains(".")
                c += Cand(InetSocketAddress.createUnresolved(name, port), if (ts) "Tailscale" else "endereço remoto")
            }
            if (relayBase.isNotEmpty()) c += Cand(null, "internet")
            return c
        }

    private sealed interface Outcome { class Reply(val d: ByteArray) : Outcome; data object NoConnect : Outcome; data object NoReply : Outcome }

    /** Envia cifrado e devolve a resposta decifrada. Repete com espera crescente até ao prazo. */
    suspend fun exchange(body: ByteArray, id: ByteArray = LinkCrypto.newID(), timeoutS: Double): ByteArray? = withContext(Dispatchers.IO) {
        if (!paired) { lastError = "Falta o código do Mac"; return@withContext null }
        val tok = token
        val deadline = System.currentTimeMillis() + (timeoutS * 1000).toLong()
        fun left() = deadline - System.currentTimeMillis()
        var backoff = 400L
        var sawMac = false
        while (left() > 300) {
            val list = candidates
            if (list.isEmpty()) { lastError = "Mac não encontrado"; return@withContext null }
            for ((i, c) in list.withIndex()) {
                if (left() <= 300) break
                val connectLimit = if (i < list.size - 1) minOf(3000, left()) else minOf(8000, left())
                val payload = LinkCrypto.seal(body, id, tok) // hora nova, mesmo id
                val t0 = System.currentTimeMillis()
                val res = if (c.addr != null) attempt(c.addr, payload, connectLimit.toInt(), left().toInt()) else relayAttempt(payload, tok, left().toInt())
                when (res) {
                    is Outcome.Reply -> {
                        sawMac = true
                        val plain = LinkCrypto.openReply(res.d, id, tok)
                        if (plain != null) {
                            if (plain.contentEquals("B".toByteArray())) continue // o Mac ainda está a tratar este pedido
                            latencyMs = (System.currentTimeMillis() - t0).toInt(); route = c.route; lastSeen = System.currentTimeMillis(); lastError = null
                            return@withContext plain
                        }
                        if (res.d.contentEquals("N".toByteArray())) { lastError = "Código errado: copia o código do Mac"; return@withContext null }
                        lastError = "Resposta inválida do Mac"
                    }
                    Outcome.NoConnect -> continue
                    Outcome.NoReply -> sawMac = true // ligou mas caiu: repetir é seguro (mesmo id)
                }
            }
            val wait = minOf(backoff, maxOf(0, left() - 300))
            if (wait > 0) delay(wait)
            backoff = minOf(backoff * 2, 4000)
        }
        lastError = if (sawMac) "O Mac não respondeu a tempo" else "Mac não encontrado"
        null
    }

    private fun attempt(a: InetSocketAddress, payload: ByteArray, connectMs: Int, totalMs: Int): Outcome {
        val s = Socket()
        try {
            val addr = if (a.isUnresolved) InetSocketAddress(InetAddress.getByName(a.hostString), a.port) else a
            s.connect(addr, maxOf(500, connectMs))
        } catch (_: Exception) { runCatching { s.close() }; return Outcome.NoConnect }
        return try {
            s.soTimeout = maxOf(1000, totalMs); s.tcpNoDelay = true
            s.getOutputStream().apply { write(payload); flush() } // v2 leva o tamanho: sem half-close
            val buf = ByteArrayOutputStream()
            val tmp = ByteArray(65536)
            val ins = s.getInputStream()
            while (true) {
                val n = ins.read(tmp)
                if (n < 0) break
                buf.write(tmp, 0, n)
                val b = buf.toByteArray()
                val len = LinkCrypto.frameLength(b)
                if (len != null && b.size >= len) return Outcome.Reply(b.copyOf(len))
            }
            val b = buf.toByteArray()
            if (b.isEmpty()) Outcome.NoReply else Outcome.Reply(b)
        } catch (_: Exception) { Outcome.NoReply } finally { runCatching { s.close() } }
    }

    /** Relay: POST do pedido já cifrado; 503 = Mac desligado, 504 = não respondeu. */
    private fun relayAttempt(payload: ByteArray, tok: String, totalMs: Int): Outcome = try {
        val c = URL("$relayBase/r/${LinkCrypto.room(tok)}/send").openConnection() as HttpURLConnection
        c.requestMethod = "POST"; c.doOutput = true
        c.connectTimeout = maxOf(2000, minOf(totalMs, 8000)); c.readTimeout = maxOf(2000, minOf(totalMs, 58_000))
        c.outputStream.use { it.write(payload) }
        when (c.responseCode) {
            200 -> Outcome.Reply(c.inputStream.use { it.readBytes() })
            503 -> Outcome.NoConnect
            else -> Outcome.NoReply
        }
    } catch (_: Exception) { Outcome.NoConnect }

    // MARK: API

    suspend fun ping(timeoutS: Double = 6.0): String? {
        val r = exchange("P".toByteArray(), timeoutS = timeoutS) ?: return null
        if (r.firstOrNull() != 'P'.code.toByte()) return null
        val name = String(r, 1, r.size - 1)
        if (macName == null && name.isNotEmpty()) macName = name
        return name
    }

    suspend fun pingInternet(): String? { onlyRelay = true; try { return ping(12.0) } finally { onlyRelay = false } }

    /** PCM 16 kHz mono Int16 LE. O Mac transcreve (Whisper), cola se `paste`, e devolve o texto final. */
    suspend fun sendAudio(pcm: ByteArray, enter: Boolean, paste: Boolean = true, timeoutS: Double = 12.0, id: ByteArray = LinkCrypto.newID()): String? {
        if (pcm.isEmpty()) return null
        val body = byteArrayOf((if (paste) 'A' else 'a').code.toByte(), (if (enter) '1' else '0').code.toByte(), 'R'.code.toByte()) + pcm
        val d = exchange(body, id, timeoutS) ?: return null
        return if (d.firstOrNull() == 'T'.code.toByte()) String(d, 1, d.size - 1) else null
    }

    /** Fila atrasada: "H" só põe no histórico do Mac (não cola). */
    suspend fun sendQueued(pcm: ByteArray, enter: Boolean, recent: Boolean, id: ByteArray): Boolean {
        val body = byteArrayOf((if (recent) 'A' else 'H').code.toByte(), (if (enter) '1' else '0').code.toByte(), 'R'.code.toByte()) + pcm
        val d = exchange(body, id, 20.0) ?: return false
        return d.firstOrNull() == 'T'.code.toByte() || d.firstOrNull() == 'E'.code.toByte()
    }

    suspend fun send(text: String, enter: Boolean): Boolean =
        exchange(((if (enter) "1" else "0") + text).toByteArray(), timeoutS = 6.0)?.contentEquals("ok".toByteArray()) == true

    // MARK: Jarvis (sessões Claude Code / Codex no Mac)

    suspend fun probeJarvis(): Boolean {
        val r = exchange("PJ".toByteArray(), timeoutS = 6.0)
        if (r == null || r.firstOrNull() != 'P'.code.toByte()) { jarvisReady = false; return false }
        val lines = String(r, 1, r.size - 1).split("\n")
        if (macName == null && lines[0].isNotEmpty()) macName = lines[0]
        jarvisReady = "jarvis=1" in lines
        return jarvisReady
    }

    suspend fun jarvis(req: JSONObject, timeoutS: Double = 8.0): JSONObject? {
        if (!jarvisReady && !probeJarvis()) { lastError = lastError ?: "O Mac precisa da Fala nova para o Jarvis"; return null }
        val r = exchange("J".toByteArray() + req.toString().toByteArray(), timeoutS = timeoutS) ?: return null
        if (r.firstOrNull() != 'J'.code.toByte()) return null
        return runCatching { JSONObject(String(r, 1, r.size - 1)) }.getOrNull()
    }

    // MARK: Controlo

    suspend fun key(text: String? = null, key: String? = null, mods: List<String> = emptyList(), times: Int = 1): Boolean {
        val j = JSONObject()
        text?.let { j.put("t", it) }
        key?.let { j.put("k", it); j.put("m", JSONArray(mods)); j.put("n", times) }
        return exchange("K".toByteArray() + j.toString().toByteArray(), timeoutS = 6.0)?.contentEquals("ok".toByteArray()) == true
    }

    suspend fun pointer(j: JSONObject): Boolean =
        exchange("K".toByteArray() + j.toString().toByteArray(), timeoutS = 3.0)?.contentEquals("ok".toByteArray()) == true

    suspend fun monitors(): List<Pair<Long, String>> {
        val r = exchange("S{\"list\":1}".toByteArray(), timeoutS = 8.0) ?: return emptyList()
        if (r.firstOrNull() != 'D'.code.toByte()) return emptyList()
        val a = runCatching { JSONArray(String(r, 1, r.size - 1)) }.getOrNull() ?: return emptyList()
        return (0 until a.length()).map { a.getJSONObject(it).let { o -> o.getLong("id") to o.optString("name", "Ecrã") } }
    }

    /** Ecrã do Mac (JPEG). `have` = resumo da imagem atual: se não mudou devolve vazio. */
    suspend fun screen(width: Int = 1280, x: Double? = null, y: Double? = null, right: Boolean = false, double: Boolean = false,
                       scroll: Int? = null, have: String? = null, monitor: Long? = null): ByteArray? {
        val j = JSONObject().put("w", width).put("q", if (route == "internet") 0.35 else 0.42)
        monitor?.let { j.put("m", it) }
        have?.let { j.put("h", it) }
        if (x != null && y != null) j.put("x", x).put("y", y).put("r", right).put("d", double)
        scroll?.let { j.put("s", it) }
        val r = exchange("S".toByteArray() + j.toString().toByteArray(), timeoutS = 15.0) ?: return null
        if (r.firstOrNull() == 'S'.code.toByte()) return r.copyOfRange(1, r.size)
        lastError = String(r, 1, r.size - 1); return null
    }

    companion object {
        const val TYPE = "_fala._tcp."
        const val PORT = 47800

        /** Resumo curto de uma imagem (igual a Link.digest no Swift). */
        fun digest(d: ByteArray) = java.security.MessageDigest.getInstance("SHA-256").digest(d).copyOf(8).hex()
    }
}
