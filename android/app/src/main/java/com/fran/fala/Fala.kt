package com.fran.fala

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.net.InetSocketAddress
import java.time.LocalDate
import java.time.ZoneId

class FalaApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Fala.init(this)
    }
}

/** Estado da app (o equivalente aos @StateObject do FalaApp.swift). */
object Fala {
    lateinit var prefs: SharedPreferences
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    val link = MacLink()
    lateinit var store: Store
    val jarvis = JarvisModel()
    lateinit var app: Context
    val main = android.os.Handler(android.os.Looper.getMainLooper())

    fun init(c: Context) {
        app = c.applicationContext
        prefs = c.getSharedPreferences("fala", Context.MODE_PRIVATE)
        Haptics.init(c)
        Outbox.init(c)
        store = Store(prefs)
        link.token = prefs.getString("fala.token", "").orEmpty()
        link.host = prefs.getString("fala.macHost", "").orEmpty()
        DictationService.channel(c)
        c.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("jarvis", "Sessões", NotificationManager.IMPORTANCE_HIGH))
        Discovery.start(c)
        LiveSTT.init(c)
        // Rede mudou ou de 20 em 20 s: tenta a fila.
        c.getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(n: Network) { scope.launch { Outbox.flush() } }
        })
        scope.launch { while (true) { delay(20_000); if (Outbox.count > 0) Outbox.flush() } }
    }

    /** fala://pair?t=CÓDIGO&h=endereço (QR do Mac). */
    fun pair(url: String): Boolean {
        val u = android.net.Uri.parse(url)
        val t = u.getQueryParameter("t")?.trim()?.uppercase().orEmpty()
        if (t.isEmpty()) return false
        if (u.getQueryParameter("k") == "pc") { PCNode.set(t, u.getQueryParameter("h").orEmpty(), u.getQueryParameter("n").orEmpty()); return true } // QR da app Windows
        setToken(t); u.getQueryParameter("h")?.let { if (it.isNotEmpty()) setHost(it) }
        return true
    }
    fun setToken(t: String) { link.token = t.trim().uppercase(); prefs.edit().putString("fala.token", link.token).apply() }
    fun setHost(h: String) { link.host = h.trim(); prefs.edit().putString("fala.macHost", link.host).apply() }
}

/** Bonjour (_fala._tcp) pelo NsdManager. */
object Discovery {
    private var nsd: NsdManager? = null
    private var lock: WifiManager.MulticastLock? = null

    fun start(c: Context) {
        if (nsd != null) return
        val m = c.getSystemService(NsdManager::class.java); nsd = m
        lock = c.getSystemService(WifiManager::class.java).createMulticastLock("fala").apply { setReferenceCounted(false); runCatching { acquire() } }
        m.discoverServices(MacLink.TYPE, NsdManager.PROTOCOL_DNS_SD, object : NsdManager.DiscoveryListener {
            override fun onServiceFound(s: NsdServiceInfo) = resolve(m, s)
            override fun onServiceLost(s: NsdServiceInfo) { if (Fala.link.macName == s.serviceName) { Fala.link.local = null } }
            override fun onDiscoveryStarted(t: String) {}
            override fun onDiscoveryStopped(t: String) {}
            override fun onStartDiscoveryFailed(t: String, e: Int) {}
            override fun onStopDiscoveryFailed(t: String, e: Int) {}
        })
    }

    @Suppress("DEPRECATION")
    private fun resolve(m: NsdManager, s: NsdServiceInfo) {
        m.resolveService(s, object : NsdManager.ResolveListener {
            override fun onResolveFailed(i: NsdServiceInfo, e: Int) {
                if (e == NsdManager.FAILURE_ALREADY_ACTIVE) Fala.scope.launch { delay(600); resolve(m, s) }
            }
            override fun onServiceResolved(i: NsdServiceInfo) {
                Fala.scope.launch {
                    Fala.link.local = InetSocketAddress(i.host, i.port)
                    Fala.link.macName = i.serviceName
                    Outbox.flush()
                }
            }
        })
    }
}

// MARK: Histórico, estatísticas, dicionário (Shared/Store.swift)

/** Dicionário (ouvido -> certo) e snippets (gatilho -> texto), palavra inteira e sem maiúsculas, como Store.process no iOS. */
fun applyPairs(text: String, dictionary: Map<String, String>, snippets: Map<String, String>): String {
    fun bare(x: String) = x.lowercase().replace(Regex("[\\p{P}\\p{S}\\s]"), "")
    // Snippet dito sozinho (com pontuação à volta): o texto inteiro passa a ser a expansão.
    snippets.entries.firstOrNull { it.key.isNotBlank() && bare(it.key) == bare(text) }?.let { return it.value }
    var t = text
    for ((k, v) in dictionary + snippets) if (k.isNotBlank())
        t = t.replace(Regex("(?<![\\p{L}\\p{N}])" + Regex.escape(k) + "(?![\\p{L}\\p{N}])", RegexOption.IGNORE_CASE), Regex.escapeReplacement(v))
    return t
}

class Entry(val text: String, val date: Long, val toMac: Boolean, val seconds: Double?) {
    val words get() = text.split(Regex("\\s+")).count { it.isNotEmpty() }
}

class Store(private val p: SharedPreferences) {
    val entries = mutableStateListOf<Entry>()
    var dictionary by mutableStateOf(map("fala.dict")); private set
    var snippets by mutableStateOf(map("fala.snip")); private set
    var scratchpad by mutableStateOf(p.getString("fala.scratch", "").orEmpty())

    init {
        runCatching {
            val a = JSONArray(p.getString("fala.entries", "[]"))
            for (i in 0 until a.length()) a.getJSONObject(i).let { entries += Entry(it.getString("text"), it.getLong("date"), it.optBoolean("toMac"), if (it.has("seconds")) it.getDouble("seconds") else null) }
        }
    }

    private fun map(k: String): Map<String, String> = runCatching { JSONObject(p.getString(k, "{}")!!).let { o -> o.keys().asSequence().associateWith { o.getString(it) } } }.getOrDefault(emptyMap())

    fun add(text: String, toMac: Boolean = false, seconds: Double? = null) {
        val t = text.trim(); if (t.isEmpty()) return
        entries.add(0, Entry(t, System.currentTimeMillis(), toMac, seconds))
        val a = JSONArray()
        entries.take(2000).forEach { e -> a.put(JSONObject().put("text", e.text).put("date", e.date).put("toMac", e.toMac).apply { e.seconds?.let { put("seconds", it) } }) }
        p.edit().putString("fala.entries", a.toString()).apply()
    }

    fun setPair(snip: Boolean, k: String, v: String?) {
        val m = (if (snip) snippets else dictionary).toMutableMap()
        if (v == null) m.remove(k) else m[k] = v
        if (snip) snippets = m else dictionary = m
        p.edit().putString(if (snip) "fala.snip" else "fala.dict", JSONObject(m as Map<*, *>).toString()).apply()
    }

    fun saveScratch() = p.edit().putString("fala.scratch", scratchpad).apply()

    fun apply(text: String) = applyPairs(text, dictionary, snippets)

    private fun day(ms: Long) = java.time.Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).toLocalDate()
    val today get() = entries.filter { day(it.date) == LocalDate.now() }
    val totalWords get() = entries.sumOf { it.words }
    val minutesSaved get() = (totalWords * (1.0 / 40 - 1.0 / 150)).toInt()
    val wpm: Int get() {
        val timed = entries.filter { (it.seconds ?: 0.0) > 1 }
        val secs = timed.sumOf { it.seconds ?: 0.0 }
        return if (secs > 0) (timed.sumOf { it.words } / secs * 60).toInt() else 0
    }
    val streak: Int get() {
        val days = entries.map { day(it.date) }.toSet()
        var d = LocalDate.now(); var n = 0
        if (d !in days) d = d.minusDays(1)
        while (d in days) { n++; d = d.minusDays(1) }
        return n
    }
}

// MARK: Sessões Claude Code / Codex no Mac (Shared/Jarvis.swift + JarvisModel em iOS/Sessions.swift)

data class Session(val id: String, val kind: String, val name: String, val cwd: String, val status: String, val updatedAt: Long,
                   val pid: Int?, val lastReply: String?, val canSend: Boolean, val mode: String?, val tool: String?) {
    val folder get() = cwd.trimEnd('/').substringAfterLast('/')
    val needsYou get() = status in NEEDS
    val busy get() = status !in listOf("idle", "shell") + NEEDS
    val shell get() = status == "shell"
    val doing get() = tool?.let { doing(it) }
    companion object {
        val NEEDS = listOf("waiting", "permission", "needs_input", "approval", "requires_action")
        fun of(o: JSONObject) = Session(o.getString("id"), o.optString("kind", "claude"), o.optString("name"), o.optString("cwd"), o.optString("status", "idle"),
            o.optLong("updatedAt"), if (o.has("pid") && !o.isNull("pid")) o.getInt("pid") else null, o.optStringOrNull("lastReply"), o.optBoolean("canSend"),
            o.optStringOrNull("mode"), o.optStringOrNull("tool"))
        /** "Bash · git status" -> "A correr git status". */
        fun doing(tool: String): String {
            val parts = tool.split(" · "); val name = parts[0]; val arg = parts.drop(1).joinToString(" · ")
            if (name == "Desc") return arg.take(70)
            val verb = when (name) {
                "Bash", "exec_command", "shell", "PowerShell" -> "A correr"
                "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch" -> "A editar"
                "Read" -> "A ler"; "Grep", "Glob" -> "A procurar"
                "WebSearch", "WebFetch", "web_search" -> "A pesquisar"
                "Agent", "Task" -> "A delegar"; "TodoWrite" -> "A planear"
                else -> "A usar $name"
            }
            return if (arg.isEmpty() || verb == "A planear") verb else verb + " " + arg.take(60)
        }
    }
}

data class Msg(val id: String, val role: String, val text: String, val at: Long)

fun JSONObject.optStringOrNull(k: String): String? = if (has(k) && !isNull(k)) getString(k) else null

class JarvisModel {
    val sessions = mutableStateListOf<Session>()
    var loading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    val messages = mutableStateMapOf<String, List<Msg>>()
    val queued = mutableStateMapOf<String, List<String>>()
    var commands by mutableStateOf<List<String>>(emptyList())
    var commandsError by mutableStateOf<String?>(null)
    var chatOpen by mutableStateOf(false)
    var doneToday by mutableIntStateOf(0)
    private val p get() = Fala.prefs
    val alias = mutableStateMapOf<String, String>()
    var archived by mutableStateOf(setOf<String>())
    var pinned by mutableStateOf(setOf<String>())
    private var watching = false

    fun loadLocal() {
        if (alias.isEmpty()) runCatching { JSONObject(p.getString("jarvis.alias", "{}")!!).let { o -> o.keys().forEach { alias[it] = o.getString(it) } } }
        archived = p.getStringSet("jarvis.archived", emptySet())!!.toSet()
        pinned = p.getStringSet("jarvis.pinned", emptySet())!!.toSet()
        val today = LocalDate.now().toString()
        doneToday = if (p.getString("jarvis.doneDay", "") == today) p.getInt("jarvis.doneCount", 0) else 0
    }
    fun setAlias(id: String, n: String) { alias[id] = n; p.edit().putString("jarvis.alias", JSONObject(alias.toMap() as Map<*, *>).toString()).apply() }
    fun togglePin(id: String) { pinned = if (id in pinned) pinned - id else pinned + id; p.edit().putStringSet("jarvis.pinned", pinned).apply() }
    fun archive(id: String) { archived = archived + id; p.edit().putStringSet("jarvis.archived", archived).apply() }

    fun title(s: Session) = alias[s.id]?.takeIf { it.isNotEmpty() } ?: s.name
    fun isActive(s: Session) = s.pid != null || s.busy || s.needsYou || s.updatedAt > System.currentTimeMillis() - 1_800_000

    private fun req(op: String) = JSONObject().put("op", op)

    suspend fun refresh() {
        loading = sessions.isEmpty()
        try {
            val r = Fala.link.jarvis(req("list"))
            if (r == null) { error = Fala.link.lastError ?: "O Mac não respondeu"; return }
            error = null
            val a = r.optJSONArray("sessions") ?: JSONArray()
            val list = (0 until a.length()).map { Session.of(a.getJSONObject(it)) }
            if (list != sessions.toList()) { sessions.clear(); sessions.addAll(list) }
            if (!p.contains("jarvis.lastEvent") && r.has("lastEvent")) p.edit().putInt("jarvis.lastEvent", r.getInt("lastEvent")).apply()
        } finally { loading = false }
    }

    suspend fun load(id: String) {
        val r = Fala.link.jarvis(req("tail").put("id", id).put("limit", 60)) ?: return
        val a = r.optJSONArray("messages") ?: return
        val m = (0 until a.length()).map { a.getJSONObject(it).let { o -> Msg(o.getString("id"), o.getString("role"), o.optString("text"), o.optLong("at")) } }
        if ((m.isNotEmpty() || messages[id] == null) && m != messages[id]) messages[id] = m
        settle(id)
    }

    private fun settle(id: String) {
        val mine = messages[id].orEmpty().filter { it.role == "user" }.takeLast(10).map { it.text.trim() }
        queued[id] = queued[id].orEmpty().filterNot { q -> mine.any { it.startsWith(q.take(40)) } }
    }

    suspend fun send(id: String, text: String, fileName: String? = null, file: ByteArray? = null): String? {
        val j = req("send").put("id", id).put("text", text)
        if (file != null) j.put("fileName", fileName).put("file", android.util.Base64.encodeToString(file, android.util.Base64.NO_WRAP))
        val r = Fala.link.jarvis(j, if (file == null) 20.0 else 60.0) ?: return Fala.link.lastError ?: "O Mac não respondeu"
        if (!r.optBoolean("ok")) return r.optStringOrNull("error") ?: "Falhou"
        queued[id] = queued[id].orEmpty() + text.trim()
        delay(600); load(id)
        return null
    }

    /** Chamada a uma sessão: manda o pedido e espera pela resposta (mensagem nova do agente e 6 s sem mudanças). */
    suspend fun ask(id: String, text: String): String {
        val sent = System.currentTimeMillis()
        send(id, text)?.let { return it }
        var last: Msg? = null; var still = System.currentTimeMillis()
        repeat(300) {
            delay(2000); load(id)
            val reply = messages[id].orEmpty().lastOrNull { it.role == "agent" && it.at > sent - 2000 }
            if (reply?.id != last?.id || reply?.text != last?.text) { last = reply; still = System.currentTimeMillis() }
            if (last != null && System.currentTimeMillis() - still > 6000) return last!!.text
        }
        return last?.text ?: "A sessão ainda está a trabalhar."
    }

    suspend fun setMode(id: String, mode: String): String? {
        val r = Fala.link.jarvis(req("mode").put("id", id).put("text", mode), 20.0) ?: return "O Mac não respondeu"
        return if (r.optBoolean("ok")) { refresh(); null } else r.optStringOrNull("error") ?: "Falhou"
    }

    suspend fun loadCommands() {
        if (commands.isNotEmpty()) return
        val r = Fala.link.jarvis(req("commands"), 20.0)
        val a = r?.optJSONArray("commands")
        if (a != null && a.length() > 0) { commands = (0 until a.length()).map { a.getString(it) }; commandsError = null }
        else commandsError = Fala.link.lastError ?: "O Mac não mandou a lista"
    }

    suspend fun media(path: String): ByteArray? {
        val r = Fala.link.jarvis(req("file").put("text", path), 30.0) ?: return null
        return r.optStringOrNull("file")?.let { android.util.Base64.decode(it, android.util.Base64.DEFAULT) }
    }

    /** De 6 em 6 s: alguma sessão terminou ou precisa de ti? (notificação como no iPhone) */
    fun startWatching(c: Context) {
        if (watching) return
        watching = true
        Fala.scope.launch {
            while (true) {
                delay(6000)
                val since = if (p.contains("jarvis.lastEvent")) p.getInt("jarvis.lastEvent", 0) else continue
                if (!Fala.link.jarvisReady) continue
                val r = Fala.link.jarvis(req("events").put("since", since), 5.0) ?: continue
                val ev = r.optJSONArray("events") ?: JSONArray()
                for (i in 0 until ev.length()) notify(c, ev.getJSONObject(i))
                if (r.has("lastEvent")) p.edit().putInt("jarvis.lastEvent", r.getInt("lastEvent")).apply()
                if (ev.length() > 0) refresh()
            }
        }
    }

    private fun notify(c: Context, e: JSONObject) {
        val finished = e.optString("kind") == "finished"
        if (finished) {
            val today = LocalDate.now().toString()
            if (p.getString("jarvis.doneDay", "") != today) { p.edit().putString("jarvis.doneDay", today).apply(); doneToday = 0 }
            doneToday++; p.edit().putInt("jarvis.doneCount", doneToday).apply()
        }
        val name = e.optString("sessionName")
        val open = PendingIntent.getActivity(c, e.optInt("id"), Intent(c, MainActivity::class.java).putExtra("session", e.optString("sessionID")), PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(c, "jarvis").setSmallIcon(R.drawable.ic_wave)
            .setContentTitle(if (finished) "$name terminou" else "$name precisa de ti").setContentText(e.optString("summary"))
            .setStyle(NotificationCompat.BigTextStyle().bigText(e.optString("summary"))).setAutoCancel(true).setContentIntent(open)
            .setPriority(if (finished) NotificationCompat.PRIORITY_DEFAULT else NotificationCompat.PRIORITY_HIGH).build()
        runCatching { NotificationManagerCompat.from(c).notify(1000 + e.optInt("id"), n) }
    }
}
