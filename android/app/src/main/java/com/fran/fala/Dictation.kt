package com.fran.fala

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.IBinder
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.log10
import kotlin.math.sqrt

/** Microfone a 16 kHz mono PCM Int16 (o que o Whisper do Mac quer). Pausa = pára de gravar, mantém o que já disseste. */
object Recorder {
    var recording by mutableStateOf(false); private set
    var paused by mutableStateOf(false); private set
    var level by mutableFloatStateOf(0f); private set
    private val buf = ByteArrayOutputStream()
    private var rec: AudioRecord? = null
    private var thread: Thread? = null
    /** Cada bloco do micro (PCM Int16, bytes): o texto ao vivo no telemóvel (LiveSTT). */
    @Volatile var onChunk: ((ByteArray, Int) -> Unit)? = null
    val seconds get() = synchronized(buf) { buf.size() } / 32000.0

    fun permitted(c: Context) = ContextCompat.checkSelfPermission(c, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    private fun open(): Boolean {
        val min = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        // VOICE_RECOGNITION: sem AGC nem supressão agressiva, o áudio mais limpo para STT.
        val r = runCatching { AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, 16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, 6400) * 2) }.getOrNull()
        if (r == null || r.state != AudioRecord.STATE_INITIALIZED) { r?.release(); return false }
        r.startRecording(); rec = r
        thread = Thread {
            val b = ShortArray(512) // 32 ms: a onda mexe tão depressa como no iPhone
            val bytes = ByteArray(1024)
            while (rec === r) {
                val n = r.read(b, 0, b.size)
                if (n <= 0) continue
                var sum = 0.0
                for (i in 0 until n) { val v = b[i].toInt(); sum += v * v; bytes[2 * i] = v.toByte(); bytes[2 * i + 1] = (v shr 8).toByte() }
                synchronized(buf) { buf.write(bytes, 0, n * 2) }
                onChunk?.invoke(bytes, n * 2)
                // Escala em dB (-60 a -20 dBFS): o micro do Poco chega muito mais baixo do que o do iPhone, e a onda tem de mexer igual.
                level = ((20 * log10(maxOf(sqrt(sum / n) / 32768.0, 1e-6)) + 60) / 40).toFloat().coerceIn(0f, 1f)
            }
        }.apply { name = "fala-mic"; start() }
        return true
    }

    private fun close() { val r = rec; rec = null; runCatching { r?.stop() }; r?.release(); thread?.join(300); thread = null; level = 0f }

    fun start(): Boolean {
        if (recording) return true
        synchronized(buf) { buf.reset() }
        paused = false
        recording = open()
        return recording
    }
    fun pause() { if (recording && !paused) { close(); paused = true } }
    fun resume() { if (recording && paused) { paused = !open() } }
    /** O áudio até agora, sem parar (pré-visualização). */
    fun snapshot(): ByteArray = synchronized(buf) { buf.toByteArray() }
    fun stop(): ByteArray {
        close(); recording = false; paused = false
        // ponytail: o último ditado fica em last.pcm (adb pull) para medir o WER com o áudio real do telemóvel.
        val raw = synchronized(buf) { buf.toByteArray().also { buf.reset() } }
        runCatching { File(Outbox.dir.parentFile, "last.pcm").writeBytes(raw) }
        return raw // o ganho é feito no Mac (WhisperEngine.normalized): medido melhor do que aqui (8,5% vs 9,3% WER)
    }
}

/** Ditado para o Mac: o mesmo fluxo do certo da aba Ditar no iPhone (iOS/FalaApp.swift DictateView.finish). */
object Dictation {
    var phase by mutableStateOf<Phase>(Phase.Idle)
    var last by mutableStateOf("")
    var preview by mutableStateOf("")
    val toast = mutableStateOf<FlowToast?>(null)
    private var previewJob: Job? = null
    private val uploads = kotlinx.coroutines.sync.Mutex() // envios por ordem, sem bloquear a gravação seguinte

    fun begin(c: Context): Boolean {
        if (Recorder.recording) return true
        if (!Recorder.permitted(c)) return false
        if (!Recorder.start()) { toast.value = FlowToast("Sem acesso ao microfone", false); return true }
        preview = ""; phase = Phase.Listening
        ContextCompat.startForegroundService(c, Intent(c, DictationService::class.java))
        // Palavra a palavra no telemóvel (como o iPhone); sem o modelo, pré-visualização pelo Mac.
        if (!LiveSTT.begin { preview = it }) startPreview()
        return true
    }

    /**
     * Texto ao vivo como o SFSpeech do iPhone, mas com o Whisper do Mac: modo "a" (teste, não cola).
     * Só o áudio novo vai em cada pedido (janelas até ~10 s): o que já estava fica fixo e a resposta chega em <1 s.
     */
    private fun startPreview() {
        previewJob?.cancel()
        previewJob = Fala.scope.launch {
            var sent = 0; var base = 0; var committed = ""; var target = ""
            // Máquina de escrever: as palavras novas entram uma a uma (o Whisper devolve frases inteiras de ~1,5 em 1,5 s).
            val typer = launch {
                while (true) {
                    delay(70)
                    if (preview == target) continue
                    if (!target.startsWith(preview)) { // o Whisper corrigiu uma palavra: recua até à parte comum
                        preview = preview.commonPrefixWith(target).substringBeforeLast(' ', "").let { if (it.isEmpty()) "" else "$it " }.trimEnd()
                        continue
                    }
                    val rest = target.substring(preview.length)
                    val next = Regex("""^\s*\S+""").find(rest)?.value ?: rest
                    preview += next
                }
            }
            while (Recorder.recording) {
                delay(120) // o pedido seguinte sai assim que o anterior volta
                val a = Recorder.snapshot()
                if (Recorder.paused || a.size - sent < 9600 || !Fala.link.hasMac) continue
                val win = a.copyOfRange(base, a.size)
                if (!voiced(win)) continue // silêncio: o Whisper inventa ("E, e, e."); o iPhone também não mostra nada
                sent = a.size
                val t = Fala.link.sendAudio(win, enter = false, paste = false, timeoutS = 8.0)?.takeUnless(::looped) ?: continue
                if (!Recorder.recording) break
                target = listOf(committed, t.trim()).filter(String::isNotEmpty).joinToString(" ")
                if (win.size > 6 * 32000) { committed = target; base = a.size } // janelas de ~6 s: cada pedido volta mais depressa
            }
            typer.cancel()
        }
    }

    internal fun voiced(pcm: ByteArray): Boolean {
        val b = java.nio.ByteBuffer.wrap(pcm).order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        var sum = 0.0; var n = 0
        while (b.hasRemaining()) { val v = b.get().toDouble(); sum += v * v; if (++n == 320) { if (sum / n > 300.0 * 300.0) return true; sum = 0.0; n = 0 } }
        return false
    }
    /** Alucinação típica em silêncio/ruído: a mesma palavra 4+ vezes seguidas. */
    internal fun looped(t: String) = Regex("""(\b[\p{L}-]+\b)(?:[\s,.]+\1\b){3,}""", RegexOption.IGNORE_CASE).containsMatchIn(t)

    fun togglePause(c: Context) {
        if (!Recorder.recording) return
        if (Recorder.paused) { Recorder.resume(); phase = Phase.Listening } else { Recorder.pause(); phase = Phase.Paused }
        Haptics.tick(); DictationService.refresh(c)
    }

    fun cancel(c: Context) {
        previewJob?.cancel(); LiveSTT.end(); Recorder.stop(); preview = ""; phase = Phase.Idle
        c.stopService(Intent(c, DictationService::class.java))
    }

    /** Envia: o Mac transcreve com Whisper, cola e devolve o texto final. `again` = Novo (envia e começa outro). */
    fun finish(c: Context, again: Boolean = false) {
        if (!Recorder.recording) return
        previewJob?.cancel(); LiveSTT.end()
        val secs = Recorder.seconds
        val pcm = Recorder.stop()
        if (!again) c.stopService(Intent(c, DictationService::class.java))
        phase = Phase.Processing
        if (again) begin(c)
        Fala.scope.launch {
            uploads.withLock {
                val enter = Fala.prefs.getBoolean("autoEnter", false)
                if (pcm.size < 8000) { phase = if (Recorder.recording) Phase.Listening else Phase.Idle; return@launch }
                val toPC = Fala.prefs.getString("fala.dest", "Mac") == "PC"
                val dest = if (toPC) "PC" else "Mac"
                val id = LinkCrypto.newID()
                val t: String?; val ok: Boolean
                val local = Fala.store.dictionary.isNotEmpty() || Fala.store.snippets.isNotEmpty()
                if (toPC) { // Whisper no PC e Ctrl+V na janela ativa do PC
                    t = PCNode.transcribe(pcm, Fala.store.dictionary.values.take(40).joinToString(", "))?.let(Fala.store::apply)?.trim()
                    ok = !t.isNullOrBlank() && PCNode.paste(t, enter)
                } else if (local && Fala.link.hasMac) {
                    // Com dicionário/snippets do telemóvel: transcreve sem colar, aplica-os aqui e cola o texto final.
                    t = Fala.link.sendAudio(pcm, enter = false, paste = false, timeoutS = 12.0)?.let(Fala.store::apply)
                    ok = !t.isNullOrBlank() && Fala.link.send(t, enter)
                    if (t == null) Outbox.add(id, pcm, enter)
                } else {
                    t = if (Fala.link.hasMac) Fala.link.sendAudio(pcm, enter, paste = true, timeoutS = 12.0, id = id) else null
                    if (t == null) Outbox.add(id, pcm, enter)
                    ok = !t.isNullOrBlank()
                }
                if (!t.isNullOrBlank()) {
                    last = t
                    (c.getSystemService(ClipboardManager::class.java)).setPrimaryClip(ClipData.newPlainText(t("Fala"), t)) // rede de segurança
                    Fala.store.add(t, toMac = ok, seconds = secs)
                }
                phase = if (Recorder.recording) Phase.Listening else Phase.Done(if (ok) "Enviado para o $dest 🎉" else if (toPC) "Copiado, o PC não respondeu" else "Fica na fila, o Mac não respondeu")
                toast.value = if (ok) FlowToast("Colado no $dest") else FlowToast(
                    if (toPC) "PC sem resposta. Texto copiado" else if (Outbox.count > 0) "Vai para o Mac quando ligar (${Outbox.count} na fila)" else (Fala.link.lastError ?: "Abre a Fala no Mac"), false)
                preview = ""
                DictationService.refresh(c)
            }
            delay(2200)
            if (phase is Phase.Done) phase = Phase.Idle
        }
    }
}

/** Fila offline (igual ao iPhone): o áudio que não chegou sai sozinho quando o Mac volta. > 90 s: só histórico. */
object Outbox {
    lateinit var dir: File
    var count by mutableStateOf(0); private set
    private var flushing = false

    fun init(c: Context) { dir = File(c.filesDir, "outbox").apply { mkdirs() }; count = items().size }
    private fun items() = dir.listFiles { f -> f.extension == "json" }.orEmpty().sortedBy { it.lastModified() }

    fun add(id: ByteArray, pcm: ByteArray, enter: Boolean) {
        val n = id.hex()
        File(dir, "$n.pcm").writeBytes(pcm)
        File(dir, "$n.json").writeText(JSONObject().put("created", System.currentTimeMillis()).put("enter", enter).toString())
        count = items().size
    }

    suspend fun flush() {
        if (flushing || !Fala.link.paired) return
        flushing = true
        try {
            for (meta in items()) {
                val pcm = File(dir, meta.nameWithoutExtension + ".pcm")
                val j = runCatching { JSONObject(meta.readText()) }.getOrNull()
                val age = System.currentTimeMillis() - (j?.optLong("created") ?: 0)
                if (j == null || !pcm.exists() || age > 86_400_000) { meta.delete(); pcm.delete(); continue }
                if (!Fala.link.sendQueued(pcm.readBytes(), j.optBoolean("enter"), age < 90_000, meta.nameWithoutExtension.unhex())) return
                meta.delete(); pcm.delete()
            }
        } finally { flushing = false; count = items().size }
    }
}

/** Gravação em segundo plano: notificação persistente com Enviar / Pausar-Continuar / Novo (o equivalente à Live Activity). */
class DictationService : Service() {
    override fun onBind(i: Intent?): IBinder? = null

    // O MIUI só mostra no ecrã bloqueado o que chega depois de bloquear: ao apagar o ecrã, a notificação volta a entrar (outro id).
    private var nid = 1
    private val screenOff = object : android.content.BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            if (!Recorder.recording) return
            val old = nid; nid = if (nid == 1) 2 else 1; current = nid
            startForeground(nid, build(c), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            c.getSystemService(NotificationManager::class.java).cancel(old)
        }
    }
    override fun onCreate() { super.onCreate(); registerReceiver(screenOff, android.content.IntentFilter(Intent.ACTION_SCREEN_OFF)) }
    override fun onDestroy() { unregisterReceiver(screenOff); super.onDestroy() }

    override fun onStartCommand(i: Intent?, flags: Int, startId: Int): Int {
        when (i?.action) {
            SEND -> Dictation.finish(this)
            PAUSE -> Dictation.togglePause(this)
            NEW -> Dictation.finish(this, again = true)
        }
        if (!Recorder.recording && i?.action == null) { stopSelf(); return START_NOT_STICKY }
        startForeground(nid, build(this), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        current = nid
        return START_NOT_STICKY
    }

    companion object {
        const val CHANNEL = "dictation3" // importância normal sem som: o MIUI mostra-a aberta, com os 3 botões
        const val SEND = "fala.send"; const val PAUSE = "fala.pause"; const val NEW = "fala.new"

        fun channel(c: Context) {
            val nm = c.getSystemService(NotificationManager::class.java)
            listOf("dictation", "dictation2").forEach(nm::deleteNotificationChannel)
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Ditado", NotificationManager.IMPORTANCE_DEFAULT).apply {
                setShowBadge(false); setSound(null, null); enableVibration(false); lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            })
        }

        private fun action(c: Context, a: String, req: Int) =
            PendingIntent.getService(c, req, Intent(c, DictationService::class.java).setAction(a), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

        fun build(c: Context): Notification {
            val open = PendingIntent.getActivity(c, 0, Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
            val paused = Recorder.paused
            return NotificationCompat.Builder(c, CHANNEL)
                .setSmallIcon(R.drawable.ic_wave)
                .setContentTitle(if (paused) "Em pausa" else "A ouvir… fala à vontade")
                .setContentText(if (Recorder.recording) "Enviar cola no Mac. Novo envia e começa outro." else "A enviar para o Mac…")
                .setUsesChronometer(!paused).setWhen(System.currentTimeMillis() - (Recorder.seconds * 1000).toLong())
                .setOngoing(true).setOnlyAlertOnce(true).setContentIntent(open)
                .setColor(0xFF1A1A1A.toInt()).setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC) // botões também no ecrã bloqueado
                .addAction(0, "Enviar", action(c, SEND, 1))
                .addAction(0, if (paused) "Continuar" else "Pausar", action(c, PAUSE, 2))
                .addAction(0, "Novo", action(c, NEW, 3))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()
        }

        private var current = 1
        fun refresh(c: Context) {
            if (Recorder.recording) c.getSystemService(NotificationManager::class.java).notify(current, build(c))
        }
    }
}
