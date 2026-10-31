package com.fran.fala

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * PC Windows (pc-node/server.py), igual a Shared/PCNode.swift: rede de casa com token HKDF(código, "fala-pc-v1"),
 * fora de casa pelo relay com a resposta cifrada (ChaCha20-Poly1305, chave HKDF(código, "fala-pc-relay-v1")).
 */
object PCNode {
    val code get() = Fala.prefs.getString("fala.pcCode", "").orEmpty()
    private val lan get() = Fala.prefs.getString("fala.pcNode", "").orEmpty().let { if (it.isEmpty()) null else "http://$it" }
    val name get() = Fala.prefs.getString("fala.pcName", "PC").orEmpty()
    val configured get() = code.isNotEmpty()
    private var lanDownUntil = 0L

    fun set(code: String, lan: String, name: String) =
        Fala.prefs.edit().putString("fala.pcCode", code.uppercase()).putString("fala.pcNode", lan).putString("fala.pcName", name.ifEmpty { "PC" }).apply()

    private fun hkdf(salt: String, n: Int) = LinkCrypto.hkdf(code.uppercase().toByteArray(), salt.toByteArray(), ByteArray(0), n)
    private val token get() = Base64.encodeToString(hkdf("fala-pc-v1", 24), Base64.NO_WRAP).replace("/", "_").replace("+", "-")
    private val room get() = MessageDigest.getInstance("SHA-256").digest(("fala-room-pc-v1:" + code.uppercase()).toByteArray()).hex()

    private fun cipher(mode: Int, key: ByteArray, nonce: ByteArray) =
        runCatching { Cipher.getInstance("ChaCha20/Poly1305/NoPadding") }.getOrElse { Cipher.getInstance("ChaCha20-Poly1305") }
            .apply { init(mode, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce)) }

    /** (estado, cabeçalhos, corpo) ou null. */
    suspend fun request(method: String, path: String, headers: Map<String, String> = emptyMap(), body: ByteArray? = null, timeoutS: Int): Triple<Int, Map<String, String>, ByteArray>? = withContext(Dispatchers.IO) {
        if (!configured) return@withContext null
        val l = lan
        if (l != null && System.currentTimeMillis() > lanDownUntil) {
            runCatching {
                val c = URL(l + path).openConnection() as HttpURLConnection
                c.requestMethod = method; c.connectTimeout = 2000; c.readTimeout = timeoutS * 1000
                c.setRequestProperty("X-Fala-Token", token); headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
                if (body != null) { c.doOutput = true; c.outputStream.use { it.write(body) } }
                val s = c.responseCode
                val d = (if (s < 400) c.inputStream else c.errorStream)?.use { it.readBytes() } ?: ByteArray(0)
                return@withContext Triple(s, c.headerFields.filterKeys { it != null }.mapValues { it.value.firstOrNull().orEmpty() }, d)
            }
            lanDownUntil = System.currentTimeMillis() + 30_000 // fora de casa: não tenta a LAN durante 30 s
        }
        // Relay: {m, p, h, b, t} cifrado; a resposta {s, h, b} também.
        runCatching {
            val env = JSONObject().put("m", method).put("p", path).put("h", JSONObject(headers)).put("t", System.currentTimeMillis() / 1000.0)
            body?.let { env.put("b", Base64.encodeToString(it, Base64.NO_WRAP)) }
            val key = hkdf("fala-pc-relay-v1", 32)
            val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
            val sealed = nonce + cipher(Cipher.ENCRYPT_MODE, key, nonce).doFinal(env.toString().toByteArray())
            val c = URL("${Fala.link.relayBase}/r/$room/send").openConnection() as HttpURLConnection
            c.requestMethod = "POST"; c.doOutput = true; c.connectTimeout = 8000; c.readTimeout = (timeoutS + 5) * 1000
            c.outputStream.use { it.write(sealed) }
            if (c.responseCode != 200) return@withContext null
            val d = c.inputStream.use { it.readBytes() }
            val j = JSONObject(String(cipher(Cipher.DECRYPT_MODE, key, d.copyOf(12)).doFinal(d, 12, d.size - 12)))
            val h = j.optJSONObject("h")?.let { o -> o.keys().asSequence().associateWith { o.getString(it) } } ?: emptyMap()
            Triple(j.getInt("s"), h, j.optString("b").let { if (it.isEmpty()) ByteArray(0) else Base64.decode(it, Base64.DEFAULT) })
        }.getOrNull()
    }

    suspend fun isUp() = request("GET", "/health", timeoutS = 4)?.first == 200

    /** Whisper no PC (GPU). PCM Int16 -> float32 LE como o iPhone manda. */
    suspend fun transcribe(pcm: ByteArray, prompt: String): String? {
        val sb = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val f = ByteBuffer.allocate(sb.remaining() * 4).order(ByteOrder.LITTLE_ENDIAN)
        while (sb.hasRemaining()) f.putFloat(sb.get() / 32767f)
        val p = java.net.URLEncoder.encode(prompt, "UTF-8").replace("+", " ")
        val r = request("POST", "/stt", mapOf("X-Prompt" to p), f.array(), maxOf(8, pcm.size / 32000 / 2)) ?: return null
        if (r.first != 200) return null
        return runCatching { JSONObject(String(r.third)).getString("text") }.getOrNull()
    }

    /** O PC mete no clipboard e faz Ctrl+V na janela ativa (e Enter). */
    suspend fun paste(text: String, enter: Boolean): Boolean {
        val r = request("POST", "/paste", if (enter) mapOf("X-Enter" to "1") else emptyMap(), text.toByteArray(), 6) ?: return false
        return r.first == 200 && runCatching { JSONObject(String(r.third)).optBoolean("ok") }.getOrDefault(false)
    }

    suspend fun input(j: JSONObject) = request("POST", "/input", body = j.toString().toByteArray(), timeoutS = 4)?.first == 200
}
