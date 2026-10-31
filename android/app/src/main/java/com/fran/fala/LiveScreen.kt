package com.fran.fala

import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Ecrã do Mac ao vivo (Shared/LiveScreenClient.swift + CallFrame): pedido "V", o Mac responde "V"+nonce e a ligação fica aberta
 * com frames cifrados (chave HKDF(chave do código, id+nonce, "fala-call-v1")). Vídeo H.264 descodificado pelo MediaCodec numa Surface.
 */
class LiveScreen(private val onSize: (Int, Int) -> Unit, private val onEnd: () -> Unit) {
    private var sock: Socket? = null
    private var out: OutputStream? = null
    private var key: ByteArray? = null
    private var seq = 0L
    private var lastSeq = 0L
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    @Volatile private var ended = false
    var fps = 0f; private set

    /** Liga pela rede local (o vídeo direto não passa pelo relay). false = usar as imagens soltas. */
    var relayed = false; private set

    /** 1.º a rede local; senão pelo relay (fora de casa, perfil remoto com menos bits), como o iPhone. */
    suspend fun connect(width: Int): Boolean = withContext(Dispatchers.IO) {
        val tok = Fala.link.token
        // ponytail: fala.forceRelay (testes) simula estar fora de casa.
        if (!Fala.prefs.getBoolean("fala.forceRelay", false)) Fala.link.local?.let { if (attempt(it, width, tok, relay = false, timeout = 3000)) return@withContext true }
        val ep = RelayTunnel.endpoint(tok) ?: return@withContext false
        attempt(ep, width, tok, relay = true, timeout = 10_000).also { relayed = it }
    }

    private fun attempt(addr: InetSocketAddress, width: Int, tok: String, relay: Boolean, timeout: Int): Boolean =
        runCatching<Boolean> {
            val s = Socket().apply { connect(addr, 3000); soTimeout = timeout; tcpNoDelay = true }
            val id = LinkCrypto.newID()
            val j = JSONObject().put("w", width).apply { if (relay) put("r", 1) }
            s.getOutputStream().apply { write(LinkCrypto.seal("V".toByteArray() + j.toString().toByteArray(), id, tok)); flush() }
            val ins = s.getInputStream()
            val hello = readFrame(ins) ?: return@runCatching false
            val r = LinkCrypto.openReply(hello, id, tok)
            if (r == null || r.size != 17 || r[0] != 'V'.code.toByte()) { s.close(); return@runCatching false }
            key = LinkCrypto.hkdf(LinkCrypto.key(tok), id + r.copyOfRange(1, 17), "fala-call-v1".toByteArray(), 32)
            s.soTimeout = 0; sock = s; out = s.getOutputStream(); ended = false
            Thread({ loop(ins) }, "fala-live").start()
            true
        }.onFailure { android.util.Log.w("fala-live", "ligação ${if (relay) "relay" else "local"} falhou: $it") }.getOrDefault(false)

    fun attach(sf: Surface?) { surface = sf; if (sf == null) { releaseCodec() } else send(JSONObject().put("kf", 1)) }

    private fun readFrame(ins: InputStream): ByteArray? {
        val head = ByteArray(6); if (!readFully(ins, head)) return null
        if (head[0] != 'F'.code.toByte() || head[1] != '2'.code.toByte()) return null
        val n = ByteBuffer.wrap(head, 2, 4).int
        if (n < 0 || n > 8 shl 20) return null
        val body = ByteArray(n); if (!readFully(ins, body)) return null
        return head + body
    }
    private fun readFully(ins: InputStream, b: ByteArray): Boolean { var o = 0; while (o < b.size) { val r = ins.read(b, o, b.size - o); if (r < 0) return false; o += r }; return true }

    private fun cipher(mode: Int, nonce: ByteArray) =
        runCatching { Cipher.getInstance("ChaCha20/Poly1305/NoPadding") }.getOrElse { Cipher.getInstance("ChaCha20-Poly1305") }
            .apply { init(mode, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce)) }

    /** Frame: dir + seq(u64 BE) + tipo + dados; só aceita do Mac ("D") e com seq sempre a subir (anti-replay). */
    private fun open(f: ByteArray): Pair<Int, ByteArray>? = runCatching {
        val p = cipher(Cipher.DECRYPT_MODE, f.copyOfRange(6, 18)).doFinal(f, 18, f.size - 18)
        if (p.size < 10 || p[0] != 0x44.toByte()) return null
        val s = ByteBuffer.wrap(p, 1, 8).long
        if (s <= lastSeq) return null
        lastSeq = s
        (p[9].toInt() and 0xff) to p.copyOfRange(10, p.size)
    }.getOrNull()

    fun send(j: JSONObject) = sendFrame(0x63, j.toString().toByteArray())

    @Synchronized private fun sendFrame(kind: Int, payload: ByteArray) {
        val o = out ?: return; if (ended) return
        runCatching {
            seq++
            val p = byteArrayOf(0x55) + ByteBuffer.allocate(8).putLong(seq).array() + byteArrayOf(kind.toByte()) + payload
            val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
            o.write(LinkCrypto.frame(nonce + cipher(Cipher.ENCRYPT_MODE, nonce).doFinal(p))); o.flush()
        }
    }

    private fun loop(ins: InputStream) {
        var frames = 0; var t0 = System.currentTimeMillis()
        while (!ended) {
            val f = readFrame(ins) ?: break
            val (kind, d) = open(f) ?: break
            when (kind) {
                0x76 -> { video(d); frames++ }
                0x68 -> break
            }
            val dt = System.currentTimeMillis() - t0
            if (dt >= 1000) { fps = frames * 1000f / dt; frames = 0; t0 = System.currentTimeMillis() }
        }
        end()
    }

    private fun annexB(b: ByteArray) = byteArrayOf(0, 0, 0, 1) + b

    /** [flags] (+ keyframe: [n] e n × [len u16][SPS/PPS]) + amostra AVCC (NALUs com 4 bytes de tamanho). */
    private fun video(d: ByteArray) {
        if (d.isEmpty()) return
        var i = 1
        val key = d[0].toInt() and 1 != 0
        if (key) {
            val n = d[i++].toInt() and 0xff
            val sets = (0 until n).map { val len = (d[i].toInt() and 0xff) shl 8 or (d[i + 1].toInt() and 0xff); i += 2; d.copyOfRange(i, i + len).also { i += len } }
            if (sets.size >= 2) setup(sets[0], sets[1])
        }
        val c = codec ?: run { send(JSONObject().put("kf", 1)); return } // entrou a meio: pede um keyframe
        // AVCC -> Annex B (o MediaCodec quer 00 00 00 01 antes de cada NALU).
        val nal = ByteArrayOutputStream()
        while (i + 4 <= d.size) {
            val len = ByteBuffer.wrap(d, i, 4).int; i += 4
            if (len <= 0 || i + len > d.size) break
            nal.write(byteArrayOf(0, 0, 0, 1)); nal.write(d, i, len); i += len
        }
        runCatching {
            val ix = c.dequeueInputBuffer(20_000)
            if (ix >= 0) {
                val b = nal.toByteArray()
                c.getInputBuffer(ix)!!.apply { clear(); put(b) }
                c.queueInputBuffer(ix, 0, b.size, System.nanoTime() / 1000, if (key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            }
            val info = MediaCodec.BufferInfo()
            while (true) {
                val ox = c.dequeueOutputBuffer(info, 0)
                if (ox == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) c.outputFormat.let { f ->
                    val w = if (f.containsKey("crop-right")) f.getInteger("crop-right") + 1 else f.getInteger(MediaFormat.KEY_WIDTH)
                    val h = if (f.containsKey("crop-bottom")) f.getInteger("crop-bottom") + 1 else f.getInteger(MediaFormat.KEY_HEIGHT)
                    onSize(w, h)
                } else if (ox >= 0) c.releaseOutputBuffer(ox, true) else break
            }
        }.onFailure { releaseCodec() }
    }

    private var sps: ByteArray? = null
    private fun setup(s: ByteArray, p: ByteArray) {
        if (codec != null && s.contentEquals(sps)) return
        val sf = surface ?: return
        releaseCodec()
        sps = s
        runCatching {
            val f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1920, 1080)
            f.setByteBuffer("csd-0", ByteBuffer.wrap(annexB(s))); f.setByteBuffer("csd-1", ByteBuffer.wrap(annexB(p)))
            f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).apply { configure(f, sf, null, 0); start() }
        }
    }

    private fun releaseCodec() { runCatching { codec?.stop(); codec?.release() }; codec = null; sps = null }

    fun close() {
        sendFrame(0x68, ByteArray(0)) // desligar, como o iPhone
        ended = true; runCatching { sock?.close() }; releaseCodec()
    }

    private fun end() { if (ended) return; ended = true; runCatching { sock?.close() }; releaseCodec(); onEnd() }
}

/**
 * Túnel pelo relay (Shared/RelayTunnel.swift): ouve em 127.0.0.1 e cada ligação abre wss://relay/r/<sala>/live;
 * o vídeo ao vivo vê um endereço local normal. O conteúdo já vai cifrado ponta a ponta, o relay só vê bytes.
 */
object RelayTunnel {
    private var server: java.net.ServerSocket? = null
    private var room = ""
    private val http = okhttp3.OkHttpClient.Builder().readTimeout(0, java.util.concurrent.TimeUnit.MILLISECONDS).build()

    @Synchronized fun endpoint(token: String): InetSocketAddress? {
        val r = LinkCrypto.room(token)
        server?.takeIf { room == r && !it.isClosed }?.let { return InetSocketAddress("127.0.0.1", it.localPort) }
        server?.close()
        val s = runCatching { java.net.ServerSocket(0, 4, java.net.InetAddress.getByName("127.0.0.1")) }.getOrNull() ?: return null
        server = s; room = r
        Thread({ while (!s.isClosed) runCatching { pump(s.accept(), r) } }, "fala-tunnel").start()
        return InetSocketAddress("127.0.0.1", s.localPort)
    }

    private fun pump(c: Socket, r: String) {
        val url = Fala.link.relayBase.replace("https://", "wss://").replace("http://", "ws://") + "/r/$r/live"
        val out = c.getOutputStream()
        val ws = http.newWebSocket(okhttp3.Request.Builder().url(url).build(), object : okhttp3.WebSocketListener() {
            override fun onMessage(webSocket: okhttp3.WebSocket, bytes: okio.ByteString) { runCatching { out.write(bytes.toByteArray()); out.flush() }.onFailure { webSocket.cancel() } }
            override fun onClosed(webSocket: okhttp3.WebSocket, code: Int, reason: String) { runCatching { c.close() } }
            override fun onFailure(webSocket: okhttp3.WebSocket, t: Throwable, response: okhttp3.Response?) { android.util.Log.w("fala-live", "relay: $t ${response?.code}"); runCatching { c.close() } }
        })
        Thread({
            val b = ByteArray(65536); val ins = c.getInputStream()
            while (true) { val n = runCatching { ins.read(b) }.getOrDefault(-1); if (n < 0) break; ws.send(okio.ByteString.of(*b.copyOf(n))) }
            ws.close(1000, null); runCatching { c.close() }
        }, "fala-tunnel-up").start()
    }
}
