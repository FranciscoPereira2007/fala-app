package com.fran.fala

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.util.Base64
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.math.sqrt

/**
 * Chamada a uma sessão, igual ao iPhone (Shared/CallClient.swift + CallModel): aperto de mão "C" + {"session"},
 * depois o microfone sobe sem parar (PCM 16 kHz) e o Mac decide as vezes (VAD), transcreve, manda à sessão e
 * responde com a voz do Jarvis (Piper), que pára logo se falares por cima. Frames cifrados como o ecrã ao vivo.
 */
class CallClient(private val onEvent: (JSONObject) -> Unit, private val onAudio: (ByteArray, Int) -> Unit,
                 private val onStop: () -> Unit, private val onEnd: (String?) -> Unit) {
    private var sock: Socket? = null
    private var out: OutputStream? = null
    private var key: ByteArray? = null
    private var seq = 0L
    private var lastSeq = 0L
    private var ttsRate = 22050
    @Volatile private var ended = false

    /** null = ligado; senão a razão. 1.º casa, depois o relay (qualquer rede), como o iPhone. */
    fun connect(session: String): String? {
        val tok = Fala.link.token
        Fala.link.local?.let { attempt(it, tok, session, 3000)?.let { e -> if (e == "Código errado") return e } ?: return null }
        val ep = RelayTunnel.endpoint(tok) ?: return "Mac não encontrado"
        return attempt(ep, tok, session, 10_000)
    }

    private fun attempt(addr: InetSocketAddress, tok: String, session: String, timeout: Int): String? = runCatching {
        val s = Socket().apply { connect(addr, 3000); soTimeout = timeout; tcpNoDelay = true }
        val id = LinkCrypto.newID()
        s.getOutputStream().apply { write(LinkCrypto.seal("C".toByteArray() + JSONObject().put("session", session).toString().toByteArray(), id, tok)); flush() }
        val ins = s.getInputStream()
        val hello = readFrame(ins) ?: run { s.close(); return "Sem resposta" }
        val r = LinkCrypto.openReply(hello, id, tok) ?: run { s.close(); return "Código errado" }
        if (r.size != 17 || r[0] != 'C'.code.toByte()) { s.close(); return "O Mac recusou a chamada" }
        key = LinkCrypto.hkdf(LinkCrypto.key(tok), id + r.copyOfRange(1, 17), "fala-call-v1".toByteArray(), 32)
        s.soTimeout = 0; sock = s; out = s.getOutputStream()
        Thread({ loop(ins) }, "fala-call").start()
        null
    }.getOrElse { "Sem ligação" }

    private fun readFrame(ins: InputStream): ByteArray? {
        val head = ByteArray(6); if (!full(ins, head)) return null
        if (head[0] != 'F'.code.toByte() || head[1] != '2'.code.toByte()) return null
        val n = ByteBuffer.wrap(head, 2, 4).int
        if (n < 0 || n > 16 shl 20) return null
        val body = ByteArray(n); if (!full(ins, body)) return null
        return head + body
    }
    private fun full(ins: InputStream, b: ByteArray): Boolean { var o = 0; while (o < b.size) { val r = ins.read(b, o, b.size - o); if (r < 0) return false; o += r }; return true }

    private fun cipher(mode: Int, nonce: ByteArray) =
        runCatching { Cipher.getInstance("ChaCha20/Poly1305/NoPadding") }.getOrElse { Cipher.getInstance("ChaCha20-Poly1305") }
            .apply { init(mode, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce)) }

    private fun loop(ins: InputStream) {
        var reason: String? = null
        while (!ended) {
            val f = readFrame(ins) ?: break
            val p = runCatching { cipher(Cipher.DECRYPT_MODE, f.copyOfRange(6, 18)).doFinal(f, 18, f.size - 18) }.getOrNull()
            if (p == null || p.size < 10 || p[0] != 0x44.toByte()) { reason = "Frame inválido"; break }
            val s = ByteBuffer.wrap(p, 1, 8).long
            if (s <= lastSeq) { reason = "Frame inválido"; break }
            lastSeq = s
            val d = p.copyOfRange(10, p.size)
            when (p[9].toInt() and 0xff) {
                0x74 -> runCatching { JSONObject(String(d)) }.getOrNull()?.let { if (it.has("ttsRate")) ttsRate = it.getInt("ttsRate"); onEvent(it) }
                0x6F -> onAudio(d, ttsRate)
                0x78 -> onStop()
                0x68 -> break
            }
        }
        end(reason)
    }

    fun sendMic(pcm: ByteArray) = send(0x61, pcm)
    fun sendEvent(j: JSONObject) = send(0x74, j.toString().toByteArray())

    @Synchronized private fun send(kind: Int, payload: ByteArray) {
        val o = out ?: return; if (ended) return
        runCatching {
            seq++
            val p = byteArrayOf(0x55) + ByteBuffer.allocate(8).putLong(seq).array() + byteArrayOf(kind.toByte()) + payload
            val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
            o.write(LinkCrypto.frame(nonce + cipher(Cipher.ENCRYPT_MODE, nonce).doFinal(p))); o.flush()
        }.onFailure { end(null) }
    }

    fun hangup() { Thread { send(0x68, ByteArray(0)); Thread.sleep(300); end(null) }.start() }

    private fun end(reason: String?) {
        if (ended) return; ended = true
        runCatching { sock?.close() }
        onEnd(reason)
    }
}

/** Microfone com cancelamento de eco (o Jarvis fala pelo altifalante) e a voz que chega do Mac. */
class CallAudio(private val onMic: (ByteArray) -> Unit, private val onLevel: (Float) -> Unit) {
    private var rec: AudioRecord? = null
    private var track: AudioTrack? = null
    private var rate = 0
    @Volatile var muted = false
    @Volatile private var running = false
    private var gain = 3f
    var blocks = 0; private set
    private val am get() = Fala.app.getSystemService(AudioManager::class.java)

    @Suppress("MissingPermission")
    fun start(): Boolean {
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        am.isSpeakerphoneOn = true
        val min = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val r = AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, 16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, 3200) * 2)
        if (r.state != AudioRecord.STATE_INITIALIZED) { r.release(); return false }
        if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(r.audioSessionId)?.enabled = true
        if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(r.audioSessionId)?.enabled = true
        rec = r; running = true; r.startRecording()
        Thread({
            val b = ShortArray(640) // 40 ms
            while (running) {
                val n = r.read(b, 0, b.size); if (n <= 0) continue
                blocks++
                if (muted) { onLevel(0f); continue }
                // Ganho automático como o iPhone: o VAD e o Whisper do Mac querem a voz a ~0,1-0,3.
                var sum = 0.0; for (i in 0 until n) { val v = b[i] / 32768.0; sum += v * v }
                val rms = sqrt(sum / n).toFloat()
                if (rms > 0.002f) gain = gain * 0.9f + (0.12f / rms).coerceIn(1f, 8f) * 0.1f
                val o = ByteBuffer.allocate(n * 2).order(ByteOrder.LITTLE_ENDIAN)
                for (i in 0 until n) o.putShort((b[i] * gain).toInt().coerceIn(-32768, 32767).toShort())
                onLevel(minOf(1f, rms * gain))
                onMic(o.array())
            }
        }, "fala-call-mic").start()
        return true
    }

    fun play(pcm: ByteArray, r: Int) {
        if (track == null || rate != r) {
            track?.release(); rate = r
            track = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(AudioFormat.Builder().setSampleRate(r).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setBufferSizeInBytes(r * 2 * 4).setTransferMode(AudioTrack.MODE_STREAM).build().also { it.play() }
        }
        track?.write(pcm, 0, pcm.size)
    }

    /** Barge-in: o Mac mandou parar, deita fora o que ainda estava para tocar. */
    fun flush() { track?.let { it.pause(); it.flush(); it.play() } }

    fun setSpeaker(on: Boolean) { am.isSpeakerphoneOn = on }
    val onSpeaker get() = am.isSpeakerphoneOn

    fun stop() {
        running = false
        runCatching { rec?.stop(); rec?.release() }; rec = null
        runCatching { track?.release() }; track = null
        am.isSpeakerphoneOn = false; am.mode = AudioManager.MODE_NORMAL
    }
}

/** Estado da chamada (CallModel do iPhone). Vive no CallCenter: minimizar não desliga. */
class CallModel {
    var state by mutableStateOf("a ligar")
    var caption by mutableStateOf("")
    var heard by mutableStateOf("")
    var level by mutableFloatStateOf(0f)
    var muted by mutableStateOf(false)
    var speaker by mutableStateOf(true)
    var failed by mutableStateOf<String?>(null)
    val participants = mutableStateListOf<Session>()
    val images = mutableStateListOf<Bitmap>()
    var imageAt by mutableLongStateOf(0L)
    private val audio = CallAudio(onMic = { client.sendMic(it) }, onLevel = { level = it })
    private val client: CallClient = CallClient(
        onEvent = { e -> Fala.main.post { apply(e) } },
        onAudio = { d, r -> audio.play(d, r) },
        onStop = { audio.flush() },
        onEnd = { reason -> Fala.main.post { state = "terminada"; reason?.let { failed = it }; audio.stop() } })

    suspend fun start(s: Session) {
        participants += s
        val err = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { client.connect(s.id) }
        if (err != null) { failed = err; state = "falhou"; return }
        if (!audio.start()) { failed = "Microfone indisponível"; client.hangup(); return }
        speaker = audio.onSpeaker
        delay(3000)
        if (audio.blocks == 0) failed = "Microfone sem som"
    }

    private fun apply(e: JSONObject) {
        val t = e.optString("text")
        when (e.optString("state")) {
            "ready" -> { state = "a ouvir"; caption = t }
            "listening" -> state = "a ouvir"
            "heard" -> { heard = t; state = "a enviar" }
            "thinking" -> state = "o agente está a trabalhar"
            "speaking" -> { state = "a falar"; caption = t }
            "error" -> failed = t
            "image" -> e.optString("image").takeIf { it.isNotEmpty() }?.let { b ->
                runCatching { Base64.decode(b, Base64.DEFAULT) }.getOrNull()?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                    ?.let { images += it; imageAt = System.currentTimeMillis() }
            }
        }
    }

    fun toggleSpeaker() { speaker = !speaker; audio.setSpeaker(speaker) }
    fun toggleMute() { muted = !muted; audio.muted = muted }
    fun switchTo(s: Session) { participants.clear(); participants += s; client.sendEvent(JSONObject().put("switch", s.id)) }
    fun add(s: Session) { if (participants.none { it.id == s.id }) { participants += s; client.sendEvent(JSONObject().put("add", s.id)) } }
    fun hangup() { client.hangup(); audio.stop() }
}

object CallCenter {
    var model by mutableStateOf<CallModel?>(null); private set
    var shown by mutableStateOf(false)
    var started = 0L; private set

    /** Atalho "Ligar ao Jarvis": a última sessão a que ligaste (espera a lista de sessões chegar). */
    suspend fun callLast() {
        val id = Fala.prefs.getString("jarvis.lastCall", null) ?: return
        repeat(40) { Fala.jarvis.sessions.firstOrNull { it.id == id }?.let { call(it); return }; delay(250) }
    }

    fun call(s: Session) {
        Fala.prefs.edit().putString("jarvis.lastCall", s.id).apply()
        if (model == null) { val m = CallModel(); model = m; started = System.currentTimeMillis(); Fala.scope.launch { m.start(s) } }
        shown = true
    }
    fun hangup() { model?.hangup(); model = null; shown = false }
}

private fun Color.mix(o: Color, k: Float) = lerp(this, o, k)

/** CallView do iPhone: pet e cores da sessão, trocar/juntar sessões, altifalante, imagens com os botões a descer. */
@Composable
fun SessionCallScreen(m: CallModel) {
    val seed = petSlot(m.participants.firstOrNull()?.id ?: "")
    val (top, bottom) = PALETTE[seed % 12]
    val live = { s: Session -> Fala.jarvis.sessions.firstOrNull { it.id == s.id } ?: s }
    val busy = m.state == "o agente está a trabalhar" || m.participants.any { live(it).busy }
    val talking = m.state == "a falar"
    var picker by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }
    var opened by remember { mutableStateOf<Bitmap?>(null) }
    var controlsDown by remember { mutableStateOf(false) }
    val secs by produceState(0) { while (true) { value = ((System.currentTimeMillis() - CallCenter.started) / 1000).toInt(); delay(1000) } }
    val view = LocalView.current
    DisposableEffect(Unit) { view.keepScreenOn = true; onDispose { view.keepScreenOn = false } }
    LaunchedEffect(m.state) { if (m.state != "a ligar") Haptics.tick() }
    LaunchedEffect(m.imageAt) { if (m.imageAt > 0) { Haptics.tick(); controlsDown = true; delay(5000); controlsDown = false } }
    LaunchedEffect(m.state) { if (m.state == "terminada" && m.failed == null) CallCenter.hangup() }
    BackHandler { CallCenter.shown = false }
    val ctrlY by animateDpAsState(if (controlsDown) 220.dp else 0.dp, spring(dampingRatio = 0.8f, stiffness = 300f))
    val pulse by animateFloatAsState(1f + minOf(m.level * 6, .35f), spring(stiffness = 600f))

    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(bottom.mix(Color.Black, .6f), bottom.mix(Color.Black, .15f))))
        .pointerInput(controlsDown) { detectTapGestures { if (controlsDown) controlsDown = false } }) {
        Column(Modifier.fillMaxSize().statusBarsPadding().safeBottom(), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
                Box(Modifier.size(44.dp).press(0.9f) { CallCenter.shown = false }, Alignment.Center) {
                    Ic(Ph.caretRight, 22.dp, Color.White, Modifier.graphicsLayer { rotationZ = 90f })
                }
            }
            SessionPet(m.participants.firstOrNull()?.id ?: "", busy, true, false, Modifier.scale(1.4f))
            Spacer(Modifier.height(10.dp))
            Row(Modifier.padding(horizontal = 30.dp).press(0.96f) { picker = true }, verticalAlignment = Alignment.CenterVertically) {
                Text(m.participants.joinToString(" + ") { Fala.jarvis.title(it) }, style = T.sans(20, T.Semi, Color.White), maxLines = 1)
                Spacer(Modifier.width(6.dp))
                Ic(Ph.caretRight, 13.dp, Color.White.copy(.7f), Modifier.graphicsLayer { rotationZ = 90f })
            }
            Text(t("%d:%02d").format(secs / 60, secs % 60), style = T.sans(15, color = Color.White.copy(.7f)), modifier = Modifier.padding(top = 10.dp))
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(230.dp), Alignment.Center) {
                Box(Modifier.size(230.dp).scale(pulse).clip(CircleShape).background(top.copy(.22f)))
                SessionPet(m.participants.firstOrNull()?.id ?: "", busy, true, false, Modifier.scale(4f * if (talking) 1.04f else 1f))
            }
            Text(m.failed ?: m.state, style = T.sans(16, T.Medium, Color.White.copy(.85f)), modifier = Modifier.padding(top = 10.dp))
            Text(m.caption.ifEmpty { if (m.heard.isEmpty()) "" else "Tu: " + m.heard }, style = T.sans(15, color = Color.White.copy(.65f)), textAlign = TextAlign.Center,
                maxLines = if (m.images.isEmpty()) 4 else 2, modifier = Modifier.padding(horizontal = 30.dp).heightIn(min = if (m.images.isEmpty()) 80.dp else 44.dp))
            if (m.images.isNotEmpty()) LazyRow(Modifier.height(176.dp), contentPadding = PaddingValues(horizontal = 24.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                itemsIndexed(m.images.reversed()) { i, img ->
                    val last = i == 0
                    Image(img.asImageBitmap(), "Abrir imagem", contentScale = ContentScale.Crop,
                        modifier = Modifier.size(if (last) 260.dp else 90.dp, if (last) 170.dp else 90.dp).clip(RoundedCornerShape(16.dp))
                            .border(1.dp, Color.White.copy(.25f), RoundedCornerShape(16.dp)).press(0.97f) { opened = img })
                }
            }
            Spacer(Modifier.weight(1f))
            Row(Modifier.padding(bottom = 40.dp).offset(y = ctrlY).graphicsLayer { alpha = if (controlsDown) 0f else 1f },
                horizontalArrangement = Arrangement.spacedBy(34.dp), verticalAlignment = Alignment.Top) {
                Round(if (m.speaker) Ph.speakerHigh else Ph.ear, m.speaker, if (m.speaker) "Altifalante" else "Ao ouvido") { m.toggleSpeaker() }
                Box(Modifier.size(72.dp).press(0.9f, haptic = Haptics::heavy) { CallCenter.hangup() }.clip(CircleShape).background(Color(0xFFFF3B30)), Alignment.Center) {
                    Ic(Ph.phone, 28.dp, Color.White, Modifier.graphicsLayer { rotationZ = 135f })
                }
                Round(if (m.muted) Ph.microphoneSlash else Ph.microphone, m.muted, if (m.muted) "Silenciado" else "Silenciar") { m.toggleMute() }
            }
        }
    }
    if (picker || adding) Sheet({ picker = false; adding = false }) {
        Text(if (adding) "Juntar à chamada" else "Falar com", style = T.sans(17, T.Semi), modifier = Modifier.padding(16.dp))
        LazyColumn(Modifier.heightIn(max = 480.dp)) {
            items(Fala.jarvis.sessions.filter { s -> !adding || m.participants.none { it.id == s.id } }) { s ->
                Row(Modifier.fillMaxWidth().clickable { tick(); if (adding) m.add(s) else m.switchTo(s); picker = false; adding = false }.padding(16.dp, 12.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(Fala.jarvis.title(s) + if (s.busy) " · a trabalhar" else "", style = T.sans(16, T.Semi))
                        Text(s.folder, style = T.sans(13, color = T.muted))
                    }
                    if (!adding && m.participants.size == 1 && m.participants[0].id == s.id) Ic(Ph.check, 18.dp)
                }
            }
            if (!adding) item {
                Row(Modifier.fillMaxWidth().clickable { tick(); picker = false; adding = true }.padding(16.dp, 14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Ic(Ph.userPlus, 20.dp); Spacer(Modifier.width(10.dp)); Text(t("Juntar sessão"), style = T.sans(16, T.Medium))
                }
            }
        }
    }
    opened?.let { img ->
        Dialog({ opened = null }, DialogProperties(usePlatformDefaultWidth = false)) {
            var scale by remember { mutableFloatStateOf(1f) }
            var off by remember { mutableStateOf(androidx.compose.ui.geometry.Offset.Zero) }
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                Image(img.asImageBitmap(), null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize()
                    .pointerInput(Unit) { detectTransformGestures { _, pan, zoom, _ -> scale = (scale * zoom).coerceIn(1f, 6f); off = if (scale > 1f) off + pan else androidx.compose.ui.geometry.Offset.Zero } }
                    .pointerInput(Unit) { detectTapGestures(onDoubleTap = { scale = 1f; off = androidx.compose.ui.geometry.Offset.Zero }) }
                    .graphicsLayer { scaleX = scale; scaleY = scale; translationX = off.x; translationY = off.y })
                Box(Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(16.dp)) { CircleIcon(Ph.x, Color.White.copy(.2f), Color.White, 44.dp, 17.dp) { opened = null } }
            }
        }
    }
}

@Composable
private fun Round(icon: androidx.compose.ui.graphics.vector.ImageVector, on: Boolean, label: String, action: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        CircleIcon(icon, if (on) Color.White else Color.White.copy(.2f), if (on) Color.Black else Color.White, 60.dp, 22.dp) { action() }
        Spacer(Modifier.height(6.dp))
        Text(label, style = T.sans(12, T.Medium, Color.White.copy(.85f)))
    }
}

/** Barra verde no topo com a chamada minimizada (CallPill do iPhone): toca para voltar. */
@Composable
fun CallPill() {
    val m = CallCenter.model
    AnimatedVisibility(m != null && !CallCenter.shown, enter = slideInVertically { -it } + fadeIn(), exit = slideOutVertically { -it } + fadeOut()) {
        val secs by produceState(0) { while (true) { value = ((System.currentTimeMillis() - CallCenter.started) / 1000).toInt(); delay(1000) } }
        Box(Modifier.fillMaxWidth().statusBarsPadding().padding(top = 4.dp), Alignment.Center) {
            Row(Modifier.height(36.dp).clip(CircleShape).background(T.forest).press(0.96f) { CallCenter.shown = true }.padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Ic(Ph.phone, 16.dp, Color.White)
                Text(m?.participants?.joinToString(" + ") { Fala.jarvis.title(it) }.orEmpty(), style = T.sans(14, T.Semi, Color.White), maxLines = 1)
                Text(t("%d:%02d").format(secs / 60, secs % 60), style = T.sans(14, T.Semi, Color.White))
            }
        }
    }
}
