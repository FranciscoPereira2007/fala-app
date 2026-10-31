package com.fran.fala

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Protocolo v2, igual a Shared/LinkCrypto.swift.
 * Chave = HKDF-SHA256(código, sal "fala-link-v2", info "iphone-mac"). Cada pedido num ChaCha20-Poly1305:
 *   fio:   "F2" + tamanho(UInt32 BE) + nonce(12) + cifra + tag(16)
 *   claro: id(16) + hora(Int64 ms BE) + corpo. Resposta: id + corpo.
 */
object LinkCrypto {
    private val MAGIC = "F2".toByteArray()
    private val rng = SecureRandom()

    fun key(token: String): ByteArray =
        hkdf(token.uppercase().toByteArray(), "fala-link-v2".toByteArray(), "iphone-mac".toByteArray(), 32)

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, len: Int): ByteArray {
        val prk = hmac(salt, ikm)
        val out = java.io.ByteArrayOutputStream()
        var t = ByteArray(0)
        var i = 1
        while (out.size() < len) { t = hmac(prk, t + info + byteArrayOf(i++.toByte())); out.write(t) }
        return out.toByteArray().copyOf(len)
    }

    private fun hmac(k: ByteArray, d: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(k, "HmacSHA256")); doFinal(d) }

    fun newID(): ByteArray = ByteArray(16).also { rng.nextBytes(it) }

    // Android (Conscrypt) e a JVM dos testes chamam-lhe nomes diferentes.
    private fun cipher(): Cipher =
        runCatching { Cipher.getInstance("ChaCha20/Poly1305/NoPadding") }.getOrElse { Cipher.getInstance("ChaCha20-Poly1305") }

    /** CryptoKit "combined": nonce(12) + cifra + tag(16). */
    private fun chachaSeal(key: ByteArray, plain: ByteArray): ByteArray {
        val nonce = ByteArray(12).also { rng.nextBytes(it) }
        val c = cipher().apply { init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce)) }
        return nonce + c.doFinal(plain)
    }

    private fun chachaOpen(key: ByteArray, box: ByteArray): ByteArray? = runCatching {
        if (box.size < 28) return null
        val c = cipher().apply { init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(box.copyOf(12))) }
        c.doFinal(box, 12, box.size - 12)
    }.getOrNull()

    fun seal(body: ByteArray, id: ByteArray, token: String, nowMs: Long = System.currentTimeMillis()): ByteArray =
        frame(chachaSeal(key(token), id + ByteBuffer.allocate(8).putLong(nowMs).array() + body))

    fun frame(box: ByteArray): ByteArray = MAGIC + ByteBuffer.allocate(4).putInt(box.size).array() + box

    fun isV2(d: ByteArray) = d.size >= 2 && d[0] == MAGIC[0] && d[1] == MAGIC[1]

    /** Bytes que a mensagem completa ocupa (null se ainda não chegou o cabeçalho). */
    fun frameLength(d: ByteArray, n: Int = d.size): Int? {
        if (n < 6 || !isV2(d)) return null
        return 6 + (ByteBuffer.wrap(d, 2, 4).int.toLong() and 0xffffffffL).toInt()
    }

    private fun box(d: ByteArray): ByteArray? {
        val n = frameLength(d) ?: return null
        return if (d.size == n) d.copyOfRange(6, n) else null
    }

    class Request(val id: ByteArray, val sentMs: Long, val body: ByteArray)

    fun open(d: ByteArray, token: String): Request? {
        val p = box(d)?.let { chachaOpen(key(token), it) } ?: return null
        if (p.size < 24) return null
        return Request(p.copyOf(16), ByteBuffer.wrap(p, 16, 8).long, p.copyOfRange(24, p.size))
    }

    fun sealReply(body: ByteArray, id: ByteArray, token: String): ByteArray = frame(chachaSeal(key(token), id + body))

    fun openReply(d: ByteArray, id: ByteArray, token: String): ByteArray? {
        val p = box(d)?.let { chachaOpen(key(token), it) } ?: return null
        if (p.size < 16 || !p.copyOf(16).contentEquals(id)) return null
        return p.copyOfRange(16, p.size)
    }

    /** Sala no relay: hash do código (o relay nunca vê o código). */
    fun room(token: String): String =
        MessageDigest.getInstance("SHA-256").digest(("fala-room-v1:" + token.uppercase()).toByteArray()).hex()
}

fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
fun String.unhex(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
