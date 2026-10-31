package com.fran.fala

import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.runtime.DisposableEffect
import android.Manifest
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import kotlin.coroutines.resume
import kotlin.math.sin

/** O teu Jarvis (iOS/Dot.swift): agente no Mac, pedidos "dot" + "dotResult" (o trabalho pode levar minutos). */
object Dot {
    class Msg(val mine: Boolean, val text: String)
    val msgs = mutableStateListOf<Msg>()
    var thinking by mutableStateOf(false)

    fun load() {
        if (msgs.isNotEmpty()) return
        runCatching { JSONArray(Fala.prefs.getString("dot.msgs", "[]")).let { a -> for (i in 0 until a.length()) a.getJSONObject(i).let { msgs += Msg(it.getBoolean("mine"), it.getString("text")) } } }
    }
    private fun save() = Fala.prefs.edit().putString("dot.msgs", JSONArray(msgs.takeLast(200).map { JSONObject().put("mine", it.mine).put("text", it.text) }).toString()).apply()

    suspend fun ask(text: String, onProgress: (String) -> Unit = {}): String {
        val t = text.trim(); if (t.isEmpty()) return ""
        msgs += Msg(true, t); save(); thinking = true
        try {
            val reply = run(t, onProgress)
            msgs += Msg(false, reply)
            return reply
        } finally { thinking = false; save() }
    }

    private suspend fun run(t: String, onProgress: (String) -> Unit): String {
        val job = (if (Fala.link.paired) Fala.link.jarvis(JSONObject().put("op", "dot").put("text", t), 20.0)?.optStringOrNull("job") else null)
            ?: return runPC(t, onProgress)
        var seen = 0
        repeat(900) { // até ~10 min
            delay(700)
            val r = Fala.link.jarvis(JSONObject().put("op", "dotResult").put("id", job), 10.0) ?: return@repeat
            if (r.optBoolean("done")) return r.optStringOrNull("reply") ?: r.optStringOrNull("error") ?: "Sem resposta"
            val p = r.optJSONArray("progress") ?: JSONArray()
            for (i in seen until p.length()) onProgress(p.getString(i))
            seen = maxOf(seen, p.length())
        }
        return "O Jarvis ainda está a trabalhar nisso. Pergunta-lhe daqui a pouco."
    }

    /** Sem Mac: o Jarvis do PC (pc-node/jarvis.py), POST /jarvis e GET /jarvis?job=, como o iPhone. */
    private suspend fun runPC(t: String, onProgress: (String) -> Unit): String {
        if (!PCNode.configured) return "Não consegui chegar ao teu computador. Tem a Fala aberta?"
        val r = PCNode.request("POST", "/jarvis", body = JSONObject().put("text", t).toString().toByteArray(), timeoutS = 20)
        val job = r?.takeIf { it.first == 200 }?.let { runCatching { JSONObject(String(it.third)).optStringOrNull("job") }.getOrNull() }
            ?: return "Não consegui chegar ao teu computador. Tem a Fala aberta?"
        var seen = 0
        repeat(900) {
            delay(700)
            val g = PCNode.request("GET", "/jarvis?job=$job", timeoutS = 10)?.takeIf { it.first == 200 } ?: return@repeat
            val j = runCatching { JSONObject(String(g.third)) }.getOrNull() ?: return@repeat
            if (j.optBoolean("done")) return j.optStringOrNull("reply") ?: j.optStringOrNull("error") ?: "Sem resposta"
            val p = j.optJSONArray("progress") ?: JSONArray()
            for (i in seen until p.length()) onProgress(p.getString(i))
            seen = maxOf(seen, p.length())
        }
        return "O Jarvis ainda está a trabalhar nisso. Pergunta-lhe daqui a pouco."
    }

    /** Definições do Jarvis: Mac op "dotConfig" (text vazio = ler, JSON = gravar); PC GET/POST /jarvis/config. */
    suspend fun config(c: JSONObject?): JSONObject? {
        if (Fala.link.paired) Fala.link.jarvis(JSONObject().put("op", "dotConfig").put("text", c?.toString() ?: ""), 40.0)
            ?.optStringOrNull("reply")?.let { return runCatching { JSONObject(it) }.getOrNull() }
        if (PCNode.configured) PCNode.request(if (c == null) "GET" else "POST", "/jarvis/config", body = c?.toString()?.toByteArray(), timeoutS = 40)
            ?.takeIf { it.first == 200 }?.let { return runCatching { JSONObject(String(it.third)) }.getOrNull() }
        return null
    }
}

/** Resumo falado (Shared/Jarvis.swift SpokenSummary): prosa curta, sem código, caminhos nem links. */
object Spoken {
    fun make(text: String, maxSentences: Int = 3, maxWords: Int = 45): String {
        val s = text.replace(Regex("```[\\s\\S]*?```"), "\n")
        val paras = mutableListOf(mutableListOf<String>())
        for (l in s.split("\n").map { it.trim() }) {
            if (l.isEmpty() || l.startsWith("|") || l.startsWith("#") || l.startsWith("---") || l.startsWith(">")) { paras += mutableListOf<String>(); continue }
            paras.last() += l
        }
        val prose = paras.map { p -> p.map(::clean).filter { it.split(" ").size >= 3 }.joinToString(" ") }.filter { it.isNotEmpty() }
        if (prose.isEmpty()) return ""
        var chosen = prose.last()
        if (chosen.split(" ").size < 8 && prose.size > 1) chosen = prose[prose.size - 2] + " " + chosen
        val out = mutableListOf<String>(); var words = 0
        for (x in sentences(chosen).take(maxSentences)) { val w = x.split(" ").size; if (out.isNotEmpty() && words + w > maxWords) break; out += x; words += w }
        return out.joinToString(" ").split(" ").take(maxWords).joinToString(" ")
    }
    private fun clean(line: String): String {
        val ref = Regex("(https?://\\S+|(~|\\.{0,2})?/[\\w.@~-]+(/[\\w.@~-]+)+/?)")
        return sentences(line).filter { !ref.containsMatchIn(it) }.map { l ->
            l.replace(Regex("^([-*+]|\\d+[.)])\\s+"), "").replace(Regex("`[^`]*`"), "").replace(Regex("[*_~]{1,3}"), "")
                .replace(Regex("\\[([^\\]]*)]\\([^)]*\\)"), "$1").replace(Regex("[—–]"), ",").replace(Regex("\\s+([,.;:])"), "$1").replace(Regex("\\s{2,}"), " ").trim(' ', ',', ';', ':')
        }.filter { it.isNotEmpty() }.joinToString(" ")
    }
    private fun sentences(t: String): List<String> {
        val out = mutableListOf<String>(); val cur = StringBuilder()
        for ((i, ch) in t.withIndex()) {
            cur.append(ch)
            if (ch in ".!?" && (i + 1 == t.length || t[i + 1].isWhitespace())) { cur.toString().trim().let { if (it.length > 1) out += it }; cur.clear() }
        }
        cur.toString().trim().let { if (it.length > 1) out += if (it.endsWith(":")) it.dropLast(1) + "." else "$it." }
        return out
    }
}

/** A bolha do Jarvis: elipses azuis que respiram com a voz. */
@Composable
fun DotBlob(level: Float, thinking: Boolean = false, size: Dp = 180.dp) {
    var t by remember { mutableLongStateOf(0L) }
    LaunchedEffect(Unit) { while (true) withFrameMillis { t = it } }
    Canvas(Modifier.size(size * 1.2f)) {
        val s = t / 1000.0; val px = size.toPx(); val c = Offset(this.size.width / 2, this.size.height / 2)
        for (i in 2 downTo 0) {
            val wob = (sin(s * (1.3 + i * 0.4) + i) * 0.06).toFloat()
            val spin = ((if (thinking) s * 40 * (i + 1) else s * 8) + i * 50).toFloat()
            val w = px * (0.8f + 0.25f * level + wob); val h = px * (0.76f + 0.2f * level - wob)
            rotate(spin, c) {
                drawOval(Brush.radialGradient(listOf(Color(0xFF9EBFFF), Color(0xD94066FF)), Offset(c.x - w / 2, c.y - h / 2), px * 0.7f),
                    Offset(c.x - w / 2, c.y - h / 2), Size(w, h), alpha = if (i == 0) 1f else 0.25f)
            }
        }
        for (dx in listOf(-0.085f, 0.085f)) drawRoundRect(Color.White.copy(.95f), Offset(c.x + dx * px - px * 0.03f, c.y - px * 0.1f), Size(px * 0.06f, px * 0.12f), androidx.compose.ui.geometry.CornerRadius(px * 0.03f))
    }
}

/** Cartão no topo das Sessões. */
@Composable
fun DotCard(open: () -> Unit, call: () -> Unit) {
    LaunchedEffect(Unit) { Dot.load() }
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(Brush.linearGradient(listOf(Color(0xFF1F33BF), Color(0xFF336BFF))))
        .press(0.98f, onClick = open).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        DotBlob(.15f, size = 46.dp)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(t("O teu Jarvis"), style = T.sans(17, T.Semi, Color.White))
            Text(if (Dot.thinking) "A trabalhar…" else Dot.msgs.lastOrNull()?.text ?: "Pede-lhe qualquer coisa. Corre no teu " + (if (Fala.link.paired) "Mac." else "PC."), style = T.sans(13, color = Color.White.copy(.8f)), maxLines = 2)
        }
        Spacer(Modifier.width(4.dp))
        CircleIcon(Ph.phone, Color.White.copy(.22f), Color.White, 44.dp, 20.dp, haptic = Haptics::heavy) { call() }
    }
}

/** Chat com o Jarvis. */
@Composable
fun DotChat(close: () -> Unit, call: () -> Unit) {
    var draft by remember { mutableStateOf("") }
    var settings by remember { mutableStateOf(false) }
    if (settings) { DotSettings { settings = false }; return }
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()
    BackHandler { close() }
    LaunchedEffect(Unit) { Dot.load() }
    LaunchedEffect(Dot.msgs.size, Dot.thinking) { if (Dot.msgs.isNotEmpty()) list.animateScrollToItem(Dot.msgs.size) }
    Box(Modifier.fillMaxSize().background(T.appBG)) {
        Column(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
            FlowHeader(Ph.caretLeft, close, trailing = { Row {
                Box(Modifier.size(44.dp).press(0.9f) { settings = true }, Alignment.Center) { Ic(Ph.sliders, 21.dp) }
                Box(Modifier.size(44.dp).press(0.9f, haptic = Haptics::heavy, onClick = call), Alignment.Center) { Ic(Ph.phone, 21.dp) } } }) {
                Text(t("O teu Jarvis"), style = T.sans(17, T.Semi))
            }
            LazyColumn(Modifier.weight(1f).fillMaxWidth(), list, contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (Dot.msgs.isEmpty()) item {
                    Column(Modifier.fillMaxWidth().padding(top = 40.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        DotBlob(.2f, size = 110.dp)
                        Text(t("Olá! Sou o teu Jarvis."), style = T.serif(26))
                        Text(t("Trabalho no teu ") + (if (Fala.link.paired) "Mac" else "PC") + ", com a tua conta. Lembro-me do que me dizes. Experimenta: \"Resume-me os emails de hoje\" ou \"Cria uma pasta para o projeto novo\".",
                            style = T.sans(15, color = T.muted), textAlign = TextAlign.Center)
                    }
                }
                items(Dot.msgs) { m ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (m.mine) Arrangement.End else Arrangement.Start) {
                        Text(m.text, style = T.sans(16), modifier = Modifier.clip(RoundedCornerShape(18.dp)).background(if (m.mine) T.lilac else Color.White).padding(12.dp))
                    }
                }
                if (Dot.thinking) item { WorkingRow() }
            }
            Row(Modifier.padding(horizontal = 12.dp).safeBottom(14.dp).padding(top = 6.dp).fillMaxWidth().card(24.dp).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    if (draft.isEmpty()) Text(t("Pede ao Jarvis…"), style = T.sans(16, color = T.ink.copy(.3f)))
                    BasicTextField(draft, { draft = it }, textStyle = T.sans(16), cursorBrush = SolidColor(T.ink), maxLines = 5, modifier = Modifier.fillMaxWidth())
                }
                Spacer(Modifier.width(10.dp))
                CircleIcon(Ph.arrowUp, if (draft.isEmpty()) T.disabled else T.ink, Color.White, 38.dp, 18.dp, enabled = draft.isNotEmpty() && !Dot.thinking) {
                    val t = draft; draft = ""; scope.launch { Dot.ask(t) }
                }
            }
        }
    }
}

// MARK: Chamada por voz (com o Jarvis ou com uma sessão): ouvir -> Whisper do Mac -> agente -> voz do Android

/** Voz pt-PT do Android (grátis, no telemóvel). */
class Voice(c: android.content.Context) {
    companion object { fun chosenName() = Fala.prefs.getString("dot.voice", "").orEmpty().ifEmpty { "Automática" }.substringAfter('-').substringAfter('-') }
    private var ready = false
    var speaking by mutableStateOf(false); private set
    private val tts = TextToSpeech(c) { ok -> ready = ok == TextToSpeech.SUCCESS }
    init {
        tts.language = Locale.forLanguageTag("pt-PT")
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) { speaking = true }
            override fun onDone(id: String?) { speaking = false; done?.invoke() }
            @Deprecated("API antiga") override fun onError(id: String?) { speaking = false; done?.invoke() }
        })
    }
    private var done: (() -> Unit)? = null
    suspend fun say(text: String) {
        if (text.isBlank()) return
        repeat(30) { if (!ready) delay(100) }
        if (!ready) return // sem motor de voz: a chamada continua (só texto)
        tts.language = Locale.forLanguageTag("pt-PT")
        Fala.prefs.getString("dot.voice", "").takeIf { !it.isNullOrEmpty() }?.let { n -> tts.voices?.firstOrNull { it.name == n }?.let { tts.voice = it } }
        kotlinx.coroutines.withTimeoutOrNull(60_000L + text.length * 120L) {
            suspendCancellableCoroutine { k ->
                done = { done = null; if (k.isActive) k.resume(Unit) }
                k.invokeOnCancellation { tts.stop() }
                if (tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "fala") == TextToSpeech.ERROR) done?.invoke()
            }
        }
    }
    fun stop() { tts.stop(); speaking = false; done?.invoke() }
    fun release() { tts.stop(); tts.shutdown() }
}

/** Ecrã da chamada. `ask` null = o teu Jarvis; senão uma sessão (JarvisModel.ask). */
@Composable
fun CallScreen(title: String, ask: (suspend (String) -> String)?, close: () -> Unit) {
    val ctx = LocalContext.current
    val voice = remember { Voice(ctx) }
    var state by remember { mutableStateOf("A ligar…") }
    var heard by remember { mutableStateOf("") }
    var lastReply by remember { mutableStateOf("") }
    var muted by remember { mutableStateOf(false) }
    val start = remember { System.currentTimeMillis() }
    val secs by produceState(0) { while (true) { delay(1000); value = ((System.currentTimeMillis() - start) / 1000).toInt() } }
    var loop by remember { mutableStateOf<Job?>(null) }
    val scope = rememberCoroutineScope()
    fun hangup() { loop?.cancel(); voice.stop(); if (Recorder.recording) Recorder.stop(); voice.release(); close() }
    BackHandler { hangup() }

    /** Ouve até haver fala e depois ~1,4 s de silêncio (ou 25 s); o Mac transcreve (modo teste, não cola). */
    suspend fun listen(): String {
        if (!Recorder.start()) return ""
        // Texto ao vivo enquanto falas (como o iPhone): janelas curtas pelo Whisper do Mac, só quando há voz.
        val preview = scope.launch {
            var sent = 0
            while (Recorder.recording) {
                delay(900)
                val a = Recorder.snapshot()
                if (a.size - sent < 9600 || !Dictation.voiced(a)) continue
                sent = a.size
                Fala.link.sendAudio(a.copyOfRange(maxOf(0, a.size - 10 * 32000), a.size), enter = false, paste = false, timeoutS = 6.0)
                    ?.takeUnless(Dictation::looped)?.let { if (Recorder.recording) heard = it.trim() }
            }
        }
        val t0 = System.currentTimeMillis(); var floor = -1f; var spoke = false; var quietSince = 0L
        while (Recorder.recording && !muted) {
            delay(100)
            val l = Recorder.level
            floor = if (floor < 0 || l < floor) l else floor * 0.995f + l * 0.005f // chão de ruído: desce logo, sobe devagar
            if (l > floor + 0.18f) { spoke = true; quietSince = 0 } else if (spoke && quietSince == 0L) quietSince = System.currentTimeMillis()
            if (spoke && quietSince > 0 && System.currentTimeMillis() - quietSince > 1400) break
            if (System.currentTimeMillis() - t0 > 25_000) break
            if (!spoke && System.currentTimeMillis() - t0 > 12_000) { preview.cancel(); Recorder.stop(); return "" }
        }
        preview.cancel()
        val pcm = Recorder.stop()
        if (!spoke || pcm.size < 8000) return ""
        state = "A perceber…"
        return Fala.link.sendAudio(pcm, enter = false, paste = false, timeoutS = 15.0)?.trim().orEmpty()
    }

    var noMic by remember { mutableStateOf(false) }
    var speaker by remember { mutableStateOf(true) }
    val am = remember { ctx.getSystemService(android.media.AudioManager::class.java) }
    DisposableEffect(Unit) { am.isSpeakerphoneOn = true; onDispose { am.isSpeakerphoneOn = false } }
    val view = androidx.compose.ui.platform.LocalView.current
    DisposableEffect(Unit) { view.keepScreenOn = true; onDispose { view.keepScreenOn = false } }
    LaunchedEffect(state) { Haptics.tick() }
    // Enquanto a voz fala, a bolha mexe-se como no iPhone (nível aleatório suave).
    val talk by produceState(0f, voice.speaking) { while (voice.speaking) { value = 0.25f + kotlin.random.Random.nextFloat() * 0.45f; delay(120) }; value = 0f }
    val askMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok -> noMic = !ok }
    LaunchedEffect(Unit) {
        if (!Recorder.permitted(ctx)) askMic.launch(Manifest.permission.RECORD_AUDIO)
        loop = scope.launch {
            voice.say("Olá! Diz-me.")
            while (true) {
                if (muted) { state = "Microfone desligado"; delay(300); continue }
                if (noMic || !Recorder.permitted(ctx)) { state = "Sem acesso ao microfone"; delay(500); continue }
                state = "A ouvir…"; heard = ""
                delay(250)
                val said = listen()
                if (said.isEmpty()) continue
                heard = said; state = "A pensar…"
                val queue = mutableListOf<String>(); var result: String? = null
                val work = launch { result = ask?.invoke(said) ?: Dot.ask(said) { queue += it } }
                voice.say(listOf("Deixa ver.", "Um segundo.", "Vou já ver isso.", "Ok, já trato.", "Vou ver e já te digo.").random())
                while (result == null) {
                    if (queue.isNotEmpty()) { state = "A falar…"; voice.say(Spoken.make(queue.removeAt(0), 2, 35)); state = "A pensar…" } else delay(150)
                }
                work.join()
                state = "A falar…"; lastReply = result!!
                voice.say(Spoken.make(result!!, 3, 60).ifEmpty { result!!.take(300) })
            }
        }
    }

    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF0D1F8C), Color(0xFF2152F2))))) {
        Column(Modifier.fillMaxSize().statusBarsPadding().safeBottom(), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.height(30.dp))
            DotBlob(if (voice.speaking) talk else Recorder.level * 0.8f, Dot.thinking, 70.dp)
            Text(title, style = T.sans(20, T.Semi, Color.White), maxLines = 1)
            Text(t("%d:%02d").format(secs / 60, secs % 60), style = T.sans(15, color = Color.White.copy(.7f)))
            Spacer(Modifier.weight(1f))
            DotBlob(if (voice.speaking) talk else Recorder.level * 0.8f, Dot.thinking, 200.dp)
            Text(state, style = T.sans(16, T.Medium, Color.White.copy(.85f)), modifier = Modifier.padding(top = 10.dp))
            Text(if (state == "A ouvir…" || state == "A perceber…") heard else lastReply, style = T.sans(15, color = Color.White.copy(.65f)), textAlign = TextAlign.Center, maxLines = 4,
                modifier = Modifier.padding(horizontal = 30.dp).heightIn(min = 80.dp))
            Spacer(Modifier.weight(1f))
            Row(Modifier.padding(bottom = 40.dp), horizontalArrangement = Arrangement.spacedBy(34.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircleIcon(if (speaker) Ph.speakerHigh else Ph.ear, if (speaker) Color.White else Color.White.copy(.2f), if (speaker) Color.Black else Color.White, 60.dp, 24.dp) {
                        speaker = !speaker; am.isSpeakerphoneOn = speaker
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(if (speaker) "Altifalante" else "Ao ouvido", style = T.sans(12, T.Medium, Color.White.copy(.85f)))
                }
                Box(Modifier.size(72.dp).press(0.9f, haptic = Haptics::heavy) { hangup() }.clip(CircleShape).background(Color(0xFFFF3B30)), Alignment.Center) {
                    Ic(Ph.phone, 28.dp, Color.White, Modifier.graphicsLayer { rotationZ = 135f })
                }
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircleIcon(Ph.microphone, if (muted) Color.White else Color.White.copy(.2f), if (muted) Color.Black else Color.White, 60.dp, 24.dp) {
                        muted = !muted; if (muted && Recorder.recording) Recorder.stop()
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(if (muted) "Silenciado" else "Silenciar", style = T.sans(12, T.Medium, Color.White.copy(.85f)))
                }
            }
        }
    }
}


// MARK: Contas de IA (iOS/Account.swift AIAccountsView): Claude e ChatGPT ligados no Mac/PC; "Entrar" abre o login lá e o ecrã remoto.

@Composable
fun AIAccountsScreen(close: () -> Unit) = FullScreen(close) {
    var mac by remember { mutableStateOf<JSONObject?>(null) }
    var pc by remember { mutableStateOf<JSONObject?>(null) }
    var note by remember { mutableStateOf<String?>(null) }
    var screen by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    suspend fun load() {
        if (Fala.link.paired) mac = Fala.link.jarvis(JSONObject().put("op", "accounts"), 20.0)?.optJSONObject("accounts")
        if (PCNode.configured) pc = PCNode.request("GET", "/accounts", timeoutS = 20)?.takeIf { it.first == 200 }?.let { runCatching { JSONObject(String(it.third)) }.getOrNull() }
        if (mac == null && pc == null) note = "O computador não respondeu. Tem a Fala aberta?"
    }
    LaunchedEffect(Unit) { load() }
    androidx.compose.foundation.layout.Column(Modifier.fillMaxSize()) {
        FlowHeader(Ph.caretLeft, close) { Text(t("Contas de IA"), style = T.sans(18, T.Medium)) }
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            for ((title, acc, isPc) in listOf(Triple("Mac", mac, false), Triple(PCNode.name, pc, true))) {
                if (if (isPc) !PCNode.configured else !Fala.link.paired) continue
                Text(title.uppercase(), style = T.sans(13, color = T.muted), modifier = Modifier.padding(start = 16.dp, top = 8.dp))
                Column(Modifier.fillMaxWidth().card(12.dp).padding(horizontal = 16.dp)) {
                    for (k in listOf("claude", "codex")) {
                        val a = acc?.optJSONObject(k); val logged = a?.optBoolean("loggedIn") == true; val installed = a?.optBoolean("installed", true) != false
                        Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(if (k == "claude") "Claude" else "ChatGPT", style = T.sans(16, T.Semi))
                                Text(if (acc == null) "A ver…" else if (logged) "Ligado ✓" else if (!installed) "Não instalado" else "Não ligado", style = T.sans(13, color = if (logged) T.forest else T.muted))
                            }
                            Pill(if (logged) "Trocar" else if (!installed) "Instalar" else "Entrar", T.ink, Color.White) {
                                scope.launch {
                                    val ok = if (isPc) PCNode.request("POST", "/accounts/login", body = JSONObject().put("which", k).toString().toByteArray(), timeoutS = 15)?.first == 200
                                             else Fala.link.jarvis(JSONObject().put("op", "login").put("id", k), 15.0)?.optBoolean("ok") == true
                                    note = if (ok) "Abri o login no ${if (isPc) "PC" else "Mac"}. Acaba-o no browser de lá: abro-te o ecrã." else "O ${if (isPc) "PC" else "Mac"} não respondeu."
                                    if (ok && !isPc) { delay(1500); screen = true }
                                }
                            }
                        }
                    }
                }
            }
            if (!Fala.link.paired && !PCNode.configured) Text(t("Liga primeiro o teu Mac ou PC (menu, Ligar ao Mac)."), style = T.sans(15, color = T.muted))
            note?.let { Text(it, style = T.sans(14, color = T.muted)) }
        }
    }
    if (screen) RemoteScreen { screen = false }
}


/** DotSettingsView do iPhone: conta (ChatGPT/Claude), modelo, até onde pode mexer, e a voz. */
@Composable
fun DotSettings(close: () -> Unit) {
    var cfg by remember { mutableStateOf(JSONObject()) }
    var loading by remember { mutableStateOf(true) }
    var voices by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    BackHandler { if (voices) voices = false else close() }
    LaunchedEffect(Unit) { Dot.config(null)?.let { cfg = it }; loading = false }
    val engine = cfg.optString("engine", "auto"); val model = cfg.optString("model", ""); val access = cfg.optString("access", "computador")
    fun models(e: String) = cfg.optJSONObject("models")?.optJSONArray(e)?.let { a -> List(a.length()) { a.getString(it) } } ?: emptyList()
    fun logged(e: String) = cfg.optJSONObject("accounts")?.optBoolean(e) ?: false
    fun set(k: String, v: String) {
        val c = JSONObject().put(k, v).apply { if (k == "engine") put("model", "") }
        cfg = JSONObject(cfg.toString()).put(k, v).apply { if (k == "engine") put("model", "") }
        scope.launch { Dot.config(c)?.let { r -> cfg = JSONObject(cfg.toString()).also { o -> r.keys().forEach { o.put(it, r.get(it)) } } } }
    }
    if (voices) { VoicePicker { voices = false }; return }
    Column(Modifier.fillMaxSize().background(T.appBG).statusBarsPadding()) {
        FlowHeader(Ph.caretLeft, close) { Text(t("Jarvis"), style = T.sans(17, T.Semi)) }
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp).safeBottom(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (loading) Row(verticalAlignment = Alignment.CenterVertically) { CircularProgressIndicator(Modifier.size(16.dp), T.muted, strokeWidth = 2.dp); Spacer(Modifier.width(8.dp)); Text(t("A perguntar ao computador…"), style = T.sans(15, color = T.muted)) }
            Section("CÉREBRO", "Corre com a tua própria conta. Mudar de modelo começa uma conversa nova (a memória dele fica).") {
                Choice("Automático", engine == "auto") { set("engine", "auto") }
                Choice("ChatGPT" + if (logged("codex")) "" else " (não ligada)", engine == "codex") { set("engine", "codex") }
                Choice("Claude" + if (logged("claude")) "" else " (não ligada)", engine == "claude", last = true) { set("engine", "claude") }
            }
            val ms = when (engine) { "claude" -> models("claude"); "codex" -> models("codex"); else -> models("codex") + models("claude") }
            Section("MODELO", null) {
                Choice("O da conta", model.isEmpty(), last = ms.isEmpty()) { set("model", "") }
                ms.forEachIndexed { i, m -> Choice(m, model == m, last = i == ms.lastIndex) { set("model", m) } }
            }
            Section("ATÉ ONDE PODE MEXER", "Com todo o computador, o Jarvis abre apps, mexe nos teus projetos e manda nas outras sessões, como o Dot. Pede sempre confirmação antes de apagar, pagar ou enviar.") {
                Choice("Todo o computador", access == "computador") { set("access", "computador") }
                Choice("Só a pasta dele", access == "pasta", last = true) { set("access", "pasta") }
            }
            Section("VOZ", "Para vozes mais naturais (grátis): Definições do Android › Idioma › Saída de texto para voz › instala os dados de voz de Português (Portugal).") {
                Row(Modifier.fillMaxWidth().press(0.98f) { voices = true }.padding(16.dp, 14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(t("Voz do Jarvis"), style = T.sans(16), modifier = Modifier.weight(1f))
                    Text(Voice.chosenName(), style = T.sans(15, color = T.muted)); Spacer(Modifier.width(6.dp)); Ic(Ph.caretRight, 14.dp, T.muted)
                }
            }
        }
    }
}

@Composable
private fun Section(title: String, footer: String?, content: @Composable ColumnScope.() -> Unit) {
    Text(title, style = T.sans(13, T.Medium, T.muted), modifier = Modifier.padding(start = 16.dp, top = 12.dp))
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Color.White), content = content)
    footer?.let { Text(it, style = T.sans(13, color = T.muted), modifier = Modifier.padding(horizontal = 16.dp)) }
}

@Composable
private fun Choice(label: String, on: Boolean, last: Boolean = false, pick: () -> Unit) {
    Row(Modifier.fillMaxWidth().press(0.98f) { pick() }.padding(16.dp, 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = T.sans(16), modifier = Modifier.weight(1f))
        if (on) Ic(Ph.check, 18.dp, T.purple)
    }
    if (!last) HorizontalDivider(Modifier.padding(start = 16.dp), thickness = 0.5.dp, color = Color.Black.copy(.1f))
}

/** DotVoicePicker do iPhone: todas as vozes do motor de voz do Android; tocar = ouve e escolhe. */
@Composable
private fun VoicePicker(close: () -> Unit) {
    val ctx = LocalContext.current
    var list by remember { mutableStateOf<List<android.speech.tts.Voice>>(emptyList()) }
    var chosen by remember { mutableStateOf(Fala.prefs.getString("dot.voice", "").orEmpty()) }
    val tts = remember { arrayOfNulls<TextToSpeech>(1) }
    DisposableEffect(Unit) {
        tts[0] = TextToSpeech(ctx) { ok -> if (ok == TextToSpeech.SUCCESS) list = tts[0]!!.voices.orEmpty().filter { !it.isNetworkConnectionRequired }
            .sortedWith(compareBy({ if (it.locale.toLanguageTag() == "pt-PT") 0 else if (it.locale.language == "pt") 1 else 2 }, { -it.quality }, { it.name })) }
        onDispose { tts[0]?.shutdown() }
    }
    fun pick(v: android.speech.tts.Voice?) {
        tick(); chosen = v?.name.orEmpty(); Fala.prefs.edit().putString("dot.voice", chosen).apply()
        tts[0]?.let { t -> if (v != null) t.voice = v else t.language = Locale.forLanguageTag("pt-PT"); t.speak(if (v == null || v.locale.language == "pt") "Olá! Sou o teu Jarvis. Em que posso ajudar?" else "Hi! I'm your Jarvis.", TextToSpeech.QUEUE_FLUSH, null, "v") }
    }
    Column(Modifier.fillMaxSize().background(T.appBG).statusBarsPadding()) {
        FlowHeader(Ph.caretLeft, close) { Text("Voz", style = T.sans(17, T.Semi)) }
        LazyColumn(contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp)) {
            item { Column(Modifier.clip(RoundedCornerShape(14.dp)).background(Color.White)) { Choice("Automática", chosen.isEmpty(), last = true) { pick(null) } } }
            val groups = list.groupBy { if (it.locale.toLanguageTag() == "pt-PT") "PORTUGUÊS (PORTUGAL)" else if (it.locale.language == "pt") "PORTUGUÊS (BRASIL)" else "OUTRAS LÍNGUAS" }
            for ((g, vs) in groups) {
                item { Text(g, style = T.sans(13, T.Medium, T.muted), modifier = Modifier.padding(start = 16.dp, top = 18.dp, bottom = 6.dp)) }
                item { Column(Modifier.clip(RoundedCornerShape(14.dp)).background(Color.White)) {
                    vs.forEachIndexed { i, v -> Choice(v.name.substringAfter('-').substringAfter('-') + if (v.quality >= android.speech.tts.Voice.QUALITY_HIGH) " · melhorada" else "", chosen == v.name, last = i == vs.lastIndex) { pick(v) } }
                } }
            }
        }
    }
}
