package com.fran.fala

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.roundToInt

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
            SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT))
        handle(intent)
        setContent {
            // A gravar: a Fala aparece por cima do ecrã bloqueado (o MIUI esconde lá as notificações em curso).
            // Bloqueado, só os controlos do ditado (✓, X, pausa): Sessões e Controlar exigem desbloquear.
            LaunchedEffect(Recorder.recording) { setShowWhenLocked(Recorder.recording) }
            if (locked && Recorder.recording) LockedDictation() else Root()
        }
    }
    private var locked by mutableStateOf(false)
    private fun checkLock() { locked = getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked }
    override fun onWindowFocusChanged(f: Boolean) { super.onWindowFocusChanged(f); checkLock() }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handle(intent) }
    override fun onResume() { super.onResume(); checkLock(); Fala.scope.launch { Outbox.flush() } }

    private fun handle(i: Intent?) {
        i?.data?.toString()?.let { url ->
            if (!url.startsWith("fala://pair") || !Fala.pair(url)) return@let
            Fala.scope.launch {
                if (i.data?.getQueryParameter("k") == "pc") Dictation.toast.value = if (PCNode.isUp()) FlowToast("PC ligado ✓ (${PCNode.name})") else FlowToast("PC guardado, mas não respondeu", false)
                else Fala.link.ping(10.0)
            }
        }
        i?.getStringExtra("session")?.let { Nav.openSession = it }
        if (i?.data?.toString() == "fala://call") Fala.scope.launch { CallCenter.callLast() }
        when (i?.getStringExtra("tab") ?: i?.data?.host) { "ditar", "record" -> Nav.tab = 1; "sessoes" -> Nav.tab = 2; "controlar" -> Nav.tab = 3 }
    }
}

/** Ecrã bloqueado a gravar: o texto ao vivo e o painel, mais nada. */
@Composable
fun LockedDictation() {
    val ctx = LocalContext.current
    Box(Modifier.fillMaxSize().background(T.appBG)) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            FlowHeader(onMenu = null) { Text("Mac", style = T.sans(18, T.Medium)) }
            Text(Dictation.preview.ifEmpty { "A ouvir… desbloqueia para ver o resto da Fala." }, style = T.sans(17),
                modifier = Modifier.weight(1f).fillMaxWidth().padding(18.dp).clip(RoundedCornerShape(16.dp)).background(Color.White).padding(16.dp))
            FlowRecorderPanel(Dictation.phase, Recorder.level, bottomInset = bottomSafe(), micLabel = "Microfone do telemóvel",
                start = {}, cancel = { Dictation.cancel(ctx) }, finish = { Dictation.finish(ctx) }, pause = { Dictation.togglePause(ctx) })
        }
    }
}

/** Pedidos de navegação vindos de fora (notificação, atalhos, adb). */
object Nav {
    var tab by mutableStateOf(-1)
    var openSession by mutableStateOf<String?>(null)
}

enum class Tab(val title: String, val icon: ImageVector) { Home("Home", Ph.house), Dictate("Ditar", Ph.microphone), Sessions("Sessões", Ph.terminalWindow), Control("Controlar", Ph.monitor) }

@Composable
fun Root() {
    var onboarded by remember { mutableStateOf(Fala.prefs.getBoolean("onboarded.v2", false)) }
    LaunchedEffect(RestartRoot.tick) { onboarded = Fala.prefs.getBoolean("onboarded.v2", false) }
    Box(Modifier.fillMaxSize().background(T.appBG)) {
        if (onboarded) RootTabs() else Onboarding { onboarded = true; Fala.prefs.edit().putBoolean("onboarded.v2", true).apply() }
    }
}

@Composable
fun RootTabs() {
    val pager = rememberPagerState(initialPage = Fala.prefs.getInt("fala.startTab", 0)) { 4 }
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var chat by remember { mutableStateOf<Session?>(null) }
    var dotChat by remember { mutableStateOf(false) }
    var call by remember { mutableStateOf<Pair<String, (suspend (String) -> String)?>?>(null) }
    val ctx = LocalContext.current
    LaunchedEffect(Nav.tab) { if (Nav.tab >= 0) { pager.animateScrollToPage(Nav.tab); Nav.tab = -1 } }
    LaunchedEffect(Unit) { Fala.jarvis.loadLocal(); Fala.jarvis.startWatching(ctx) }
    LaunchedEffect(Nav.openSession, Fala.jarvis.sessions.size) {
        val id = Nav.openSession ?: return@LaunchedEffect
        if (Fala.jarvis.sessions.none { it.id == id }) { pager.scrollToPage(2); Fala.jarvis.refresh() } // app aberta a frio pela notificação
        Fala.jarvis.sessions.firstOrNull { it.id == id }?.let { chat = it; Nav.openSession = null; pager.scrollToPage(2) }
    }
    LaunchedEffect(pager.currentPage) { Haptics.tick() }
    Fala.jarvis.chatOpen = chat != null || dotChat || call != null

    Box(Modifier.fillMaxSize()) {
        HorizontalPager(pager, Modifier.fillMaxSize().statusBarsPadding(), userScrollEnabled = !menu && !Fala.jarvis.chatOpen, beyondViewportPageCount = 1) { p ->
            when (Tab.entries[p]) {
                Tab.Home -> HomeScreen(go = { scope.launch { pager.animateScrollToPage(it.ordinal) } }, menu = { menu = true })
                Tab.Dictate -> DictateScreen()
                Tab.Sessions -> SessionsScreen(open = { chat = it }, dotChat = { dotChat = true }, call = { t, a -> call = t to a })
                Tab.Control -> ControlScreen()
            }
        }
        AnimatedVisibility(!Fala.jarvis.chatOpen, Modifier.align(Alignment.BottomCenter), enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            TabBar(pager.currentPage) { scope.launch { pager.animateScrollToPage(it) } }
        }
        // Conversa: entra da direita como o push do iOS; voltar = gesto/botão.
        AnimatedVisibility(chat != null, enter = slideInHorizontally(spring(stiffness = 500f, dampingRatio = 0.92f)) { it },
            exit = slideOutHorizontally(tween(260)) { it }) {
            val last = remember { mutableStateOf<Session?>(null) }
            chat?.let { last.value = it }
            last.value?.let { s -> SessionChat(s, close = { chat = null }, call = { CallCenter.call(s) }) }
        }
        AnimatedVisibility(dotChat, enter = slideInHorizontally(spring(stiffness = 500f, dampingRatio = 0.92f)) { it }, exit = slideOutHorizontally(tween(260)) { it }) {
            DotChat(close = { dotChat = false }, call = { call = "Jarvis" to null })
        }
        AnimatedVisibility(call != null, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            val last = remember { mutableStateOf<Pair<String, (suspend (String) -> String)?>?>(null) }
            call?.let { last.value = it }
            last.value?.let { (t, a) -> if (call != null) CallScreen(t, a) { call = null } }
        }
        // Chamada a uma sessão (como o iPhone): fica viva minimizada, com a barra verde no topo.
        AnimatedVisibility(CallCenter.shown && CallCenter.model != null, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
            val last = remember { mutableStateOf<CallModel?>(null) }
            CallCenter.model?.let { last.value = it }
            last.value?.let { SessionCallScreen(it) }
        }
        CallPill()
        SideMenu(menu) { menu = false }
        Box(Modifier.fillMaxSize().statusBarsPadding()) { ToastHost(Dictation.toast) }
    }
}

/** Pill #F6F6F8 com cápsula ativa #E3E3E5 que desliza (mola) e ícone ativo roxo. */
@Composable
fun TabBar(current: Int, select: (Int) -> Unit) {
    val pending = Fala.jarvis.sessions.count { it.needsYou }
    BoxWithConstraints(Modifier.fillMaxWidth().safeBottom().padding(start = 21.dp, end = 21.dp, bottom = 2.dp)) {
        val inner = maxWidth - 10.dp
        val w = inner / 4
        val x by animateDpAsState(w * current, spring(dampingRatio = 0.72f, stiffness = 420f), label = "pill")
        Box(Modifier.fillMaxWidth().shadow(12.dp, CircleShape, ambientColor = Color.Black.copy(.08f), spotColor = Color.Black.copy(.08f))
            .clip(CircleShape).background(T.tabPill.copy(alpha = .97f)).padding(5.dp)) {
            Box(Modifier.offset { IntOffset(x.roundToPx(), 0) }.width(w).height(52.dp).clip(CircleShape).background(T.tabActive))
            Row {
                Tab.entries.forEachIndexed { i, t ->
                    val on = i == current
                    val tint by animateColorAsState(if (on) T.tabPurple else T.ink, label = "tint")
                    Column(Modifier.width(w).height(52.dp).clickable(remember { MutableInteractionSource() }, null) { if (i != current) select(i) },
                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                        Box {
                            Ic(t.icon, 21.dp, tint)
                            if (t == Tab.Sessions && pending > 0) Box(Modifier.offset(12.dp, (-6).dp).size(16.dp).clip(CircleShape).background(T.orange), Alignment.Center) {
                                Text("$pending", style = T.sans(10, T.Bold, Color.White))
                            }
                        }
                        Spacer(Modifier.height(3.dp))
                        Text(t.title, style = T.sans(11, T.Medium), maxLines = 1)
                    }
                }
            }
        }
    }
}

// MARK: Home

@Composable
fun HomeScreen(go: (Tab) -> Unit, menu: () -> Unit) {
    val toast = remember { mutableStateOf<FlowToast?>(null) }
    var banner by remember { mutableStateOf(Fala.prefs.getBoolean("home.banner", true)) }
    val ctx = LocalContext.current
    val connected = Fala.link.macName != null
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            FlowHeader(onMenu = menu, trailing = {
                val bg by animateColorAsState(if (connected) T.greenSoft else Color.Black.copy(.06f), label = "bg")
                Box(Modifier.size(48.dp).press(0.92f) { toast.value = if (connected) FlowToast("Mac ligado") else FlowToast("Mac não encontrado", false) }
                    .clip(RoundedCornerShape(14.dp)).background(bg), Alignment.Center) {
                    Ic(Ph.laptop, 22.dp, if (connected) T.green else T.ink.copy(.45f))
                }
            }) { FalaLogo() }
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).safeBottom().padding(start = 18.dp, end = 18.dp, top = 18.dp, bottom = 110.dp)) {
                AnimatedVisibility(banner) {
                    Column {
                        FlowBanner(italicTail("Fala no telemóvel, ", "escreve no Mac"),
                            italicTail("Usa a tua voz para escrever emails, mensagens e notas. Na aba Ditar, o texto cola onde estiver o cursor.", ""),
                            "Experimentar", capsule = true, onCta = { go(Tab.Dictate) }, onClose = { banner = false; Fala.prefs.edit().putBoolean("home.banner", false).apply() })
                        Spacer(Modifier.height(18.dp))
                    }
                }
                Row(Modifier.padding(start = 2.dp, top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(t("Hoje"), style = T.sans(16, color = T.ink.copy(.6f))); Spacer(Modifier.width(6.dp)); Ic(Ph.info, 17.dp, T.ink.copy(.6f))
                }
                Spacer(Modifier.height(18.dp))
                val today = Fala.store.today
                if (today.isEmpty()) {
                    Text(t("Ainda nada hoje. Toca em Ditar e diz a tua primeira frase."), style = T.sans(16, color = T.muted), modifier = Modifier.fillMaxWidth().card().padding(18.dp))
                } else Column(Modifier.fillMaxWidth().card().padding(horizontal = 18.dp)) {
                    today.forEachIndexed { i, e ->
                        Column(Modifier.fillMaxWidth().clickable(remember { MutableInteractionSource() }, null) {
                            ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(t("Fala"), e.text)); toast.value = FlowToast("Copiado")
                        }.padding(vertical = 16.dp)) {
                            Text(e.text, style = T.sans(16))
                            Spacer(Modifier.height(16.dp))
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(hhmm(e.date), style = T.sans(13, color = T.ink.copy(.45f)))
                                if (e.toMac) { Spacer(Modifier.width(6.dp)); Ic(Ph.laptop, 14.dp, T.ink.copy(.45f)) }
                            }
                        }
                        if (i < today.lastIndex) HorizontalDivider(color = Color.Black.copy(.1f), thickness = 0.5.dp)
                    }
                }
            }
        }
        ToastHost(toast)
    }
}

fun hhmm(ms: Long): String = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern("HH:mm"))

// MARK: Ditar: fala aqui, cola no Mac

@Composable
fun DictateScreen() {
    val ctx = LocalContext.current
    var autoEnter by remember { mutableStateOf(Fala.prefs.getBoolean("autoEnter", false)) }
    var pairing by remember { mutableStateOf(false) }
    var dest by remember { mutableStateOf(Fala.prefs.getString("fala.dest", "Mac")!!) }
    val askMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { r ->
        if (r[Manifest.permission.RECORD_AUDIO] == true) Dictation.begin(ctx) else Dictation.toast.value = FlowToast("Sem acesso ao microfone", false)
    }
    fun begin() {
        val notif = android.os.Build.VERSION.SDK_INT >= 33 && androidx.core.content.ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED
        // Sem notificações não há Enviar/Pausar/Novo em fundo: pedidas à parte, mesmo com o micro já autorizado.
        if (!Recorder.permitted(ctx) || notif) askMic.launch(arrayOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS))
        else Dictation.begin(ctx)
    }
    val link = Fala.link
    val ph = Dictation.phase
    Column(Modifier.fillMaxSize()) {
        FlowHeader(onMenu = null, trailing = {
            Box(Modifier.size(44.dp), Alignment.Center) { Box(Modifier.size(9.dp).clip(CircleShape).background(if (link.hasMac) T.green else T.disabled)) }
        }) { Text(dest, style = T.sans(18, T.Medium)) }
        Column(Modifier.weight(1f).padding(horizontal = 18.dp)) {
            Spacer(Modifier.height(8.dp))
            Segmented(listOf("Mac", "PC"), if (dest == "PC") 1 else 0, enabled = ph == Phase.Idle || ph is Phase.Done) {
                dest = if (it == 1) "PC" else "Mac"; Fala.prefs.edit().putString("fala.dest", dest).apply()
                if (it == 1 && !PCNode.configured) pairing = true
            }
            Spacer(Modifier.height(18.dp))
            Text(italicTail("Fala aqui, ", "aparece no $dest", T.orange), style = T.serif(30), textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(12.dp))
            if (dest == "PC") Row(Modifier.fillMaxWidth().clickable(remember { MutableInteractionSource() }, null) { if (!PCNode.configured) pairing = true },
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Ic(Ph.desktop, 15.dp, T.muted); Spacer(Modifier.width(6.dp))
                Text(if (PCNode.configured) "Cola na janela ativa do ${PCNode.name}" else "Toca para ligar ao PC (QR da app Windows)", style = T.sans(13, color = T.muted))
            } else Row(Modifier.fillMaxWidth().clickable(remember { MutableInteractionSource() }, null) { if (!link.paired) pairing = true },
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Ic(if (link.hasMac) Ph.checkCircleFill else Ph.wifiSlash, 15.dp, if (link.hasMac) T.forest else T.muted)
                Spacer(Modifier.width(6.dp))
                Text(if (link.paired) link.label else "Toca para ligar ao Mac (QR)", style = T.sans(13, color = if (link.hasMac) T.forest else T.muted))
            }
            Spacer(Modifier.height(14.dp))
            val live = ph == Phase.Listening || ph == Phase.Paused
            val shown = when {
                live -> Dictation.preview.ifEmpty { "Diz alguma coisa!" }
                ph == Phase.Processing -> Dictation.preview.ifEmpty { "A transcrever no Mac…" }
                Dictation.last.isNotEmpty() -> Dictation.last
                else -> "Diz alguma coisa! O texto cola no $dest, onde estiver o cursor."
            }
            Box(Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color.White).border(1.dp, T.line, RoundedCornerShape(16.dp))
                .verticalScroll(rememberScrollState()).padding(16.dp)) {
                Text(shown, style = T.sans(17, color = if (live || Dictation.last.isNotEmpty()) T.ink else T.ink.copy(.35f)))
            }
            Spacer(Modifier.height(14.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(t("Carregar Enter depois de colar"), style = T.sans(15), modifier = Modifier.weight(1f))
                IOSSwitch(autoEnter) { autoEnter = it; Fala.prefs.edit().putBoolean("autoEnter", it).apply() }
            }
            Spacer(Modifier.height(12.dp))
        }
        FlowRecorderPanel(ph, Recorder.level, bottomInset = 96.dp + bottomSafe(), micLabel = "Microfone do telemóvel",
            start = ::begin, cancel = { Dictation.cancel(ctx) }, finish = { Dictation.finish(ctx) }, pause = { Dictation.togglePause(ctx) })
    }
    if (pairing) PairingSheet { pairing = false }
}

/** Interruptor do iOS (51x31, verde #4FBF77). */
@Composable
fun IOSSwitch(on: Boolean, change: (Boolean) -> Unit) {
    val x by animateDpAsState(if (on) 22.dp else 2.dp, spring(dampingRatio = 0.7f, stiffness = 600f), label = "thumb")
    val bg by animateColorAsState(if (on) T.green else Color(0x29787880), label = "bg")
    Box(Modifier.width(51.dp).height(31.dp).clip(CircleShape).background(bg).clickable(remember { MutableInteractionSource() }, null) { tick(); change(!on) }) {
        Box(Modifier.offset(x, 2.dp).size(27.dp).shadow(3.dp, CircleShape).clip(CircleShape).background(Color.White))
    }
}

/** Controlo segmentado do iOS. */
@Composable
fun Segmented(items: List<String>, selected: Int, enabled: Boolean = true, pick: (Int) -> Unit) {
    var sel by remember { mutableStateOf(selected) }
    BoxWithConstraints(Modifier.fillMaxWidth().height(32.dp).clip(RoundedCornerShape(9.dp)).background(Color(0x1F767680)).padding(2.dp)) {
        val w = maxWidth / items.size
        val x by animateDpAsState(w * sel, spring(dampingRatio = 0.8f, stiffness = 500f), label = "seg")
        Box(Modifier.offset(x, 0.dp).width(w).fillMaxHeight().shadow(2.dp, RoundedCornerShape(7.dp)).clip(RoundedCornerShape(7.dp)).background(Color.White))
        Row(Modifier.fillMaxSize()) {
            items.forEachIndexed { i, s ->
                Box(Modifier.width(w).fillMaxHeight().clickable(remember { MutableInteractionSource() }, null, enabled = enabled) { tick(); pick(i); sel = i }, Alignment.Center) {
                    Text(s, style = T.sans(13, if (i == sel) T.Semi else T.Medium))
                }
            }
        }
    }
}

// MARK: Controlar

@Composable
fun ControlScreen() {
    var pairing by remember { mutableStateOf(false) }
    var screen by remember { mutableStateOf(false) }
    var pcScreen by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).safeBottom().padding(20.dp).padding(bottom = 90.dp)) {
        Spacer(Modifier.height(8.dp))
        Text(t("Controlar"), style = T.serif(34))
        Spacer(Modifier.height(14.dp))
        Text(t("Vê o ecrã e mexe com o dedo, como num trackpad. Funciona em casa e do outro lado do mundo."), style = T.sans(15, color = T.muted))
        Spacer(Modifier.height(14.dp))
        ControlCard(Ph.laptop, "O teu Mac", if (Fala.link.paired) Fala.link.label else null) { if (Fala.link.paired) screen = true else pairing = true }
        Spacer(Modifier.height(14.dp))
        ControlCard(Ph.desktop, "O teu PC Windows", if (PCNode.configured) PCNode.name else null) { if (PCNode.configured) pcScreen = true else pairing = true }
        Spacer(Modifier.height(18.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Ic(Ph.handTap, 15.dp, T.muted); Spacer(Modifier.width(6.dp))
            Text(t("1 dedo mexe o rato, 2 dedos fazem scroll, toque longo é clique direito."), style = T.sans(13, color = T.muted))
        }
    }
    if (pairing) PairingSheet { pairing = false }
    if (screen) RemoteScreen { screen = false }
    if (pcScreen) RemoteScreen(pc = true) { pcScreen = false }
}

@Composable
private fun ControlCard(icon: ImageVector, title: String, connected: String?, tap: () -> Unit) {
    Row(Modifier.fillMaxWidth().press(0.98f, onClick = tap).card(22.dp).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(56.dp).clip(RoundedCornerShape(16.dp)).background(T.lilac), Alignment.Center) { Ic(icon, 28.dp) }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = T.sans(17, T.Semi))
            Spacer(Modifier.height(3.dp))
            Text(connected ?: "Ligar com o código QR", style = T.sans(14, color = if (connected == null) T.orange else T.muted))
        }
        Box(Modifier.height(36.dp).clip(CircleShape).background(T.ink).padding(horizontal = 16.dp), Alignment.Center) {
            Text(if (connected == null) "Ligar" else "Abrir", style = T.sans(15, T.Semi, Color.White))
        }
    }
}

// MARK: Menu lateral (desliza da esquerda com mola, fundo escurece)

@Composable
fun SideMenu(open: Boolean, close: () -> Unit) {
    var drag by remember { mutableFloatStateOf(0f) }
    var stats by remember { mutableStateOf(false) }
    var pairing by remember { mutableStateOf(false) }
    var dict by remember { mutableStateOf<Boolean?>(null) } // false = dicionário, true = snippets
    var notes by remember { mutableStateOf(false) }
    var accounts by remember { mutableStateOf(false) }
    var settings by remember { mutableStateOf(false) }
    BackHandler(open) { close() }
    LaunchedEffect(open) { if (open) Haptics.tick(); drag = 0f }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val w = minOf(300.dp, maxWidth * 0.74f)
        val wPx = with(LocalDensity.current) { w.toPx() }
        val shown by animateFloatAsState(if (open) 1f else 0f, spring(dampingRatio = 0.86f, stiffness = 380f), label = "menu")
        if (shown > 0.001f) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.32f * shown * (1 + drag / wPx).coerceIn(0f, 1f)))
            .clickable(remember { MutableInteractionSource() }, null) { close() })
        Column(Modifier.width(w).fillMaxHeight().offset { IntOffset(((shown - 1) * (wPx + 90) + drag).roundToInt(), 0) }.background(Color.White)
            .pointerInput(Unit) { detectHorizontalDragGestures(onDragEnd = { if (drag < -wPx / 3) close() else drag = 0f }) { _, d -> drag = (drag + d).coerceAtMost(0f) } }
            .statusBarsPadding().safeBottom().padding(start = 22.dp, end = 22.dp, top = 20.dp, bottom = 30.dp)) {
            val s = Fala.store
            Box(Modifier.size(52.dp).clip(CircleShape).background(T.ink), Alignment.Center) { Text("F", style = T.sans(22, T.Bold, Color.White)) }
            Spacer(Modifier.height(14.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(t("Fala"), style = T.sans(22, T.Semi)); Spacer(Modifier.width(8.dp))
                val on = Fala.link.macName != null
                Text(if (on) "Mac ligado" else "Sem Mac", style = T.sans(12, T.Medium, Color.White),
                    modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(if (on) T.purple else T.disabled).padding(horizontal = 6.dp, vertical = 3.dp))
            }
            Spacer(Modifier.height(4.dp))
            Text(t("%,d palavras · %d WPM").format(s.totalWords, s.wpm).replace(',', ' '), style = T.sans(15, color = T.ink.copy(.7f)))
            Spacer(Modifier.height(22.dp))
            Text("${minOf(s.streak, 5)} de 5 dias seguidos", style = T.sans(14, color = T.ink.copy(.7f)))
            Spacer(Modifier.height(8.dp))
            Box(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(Color.Black.copy(.1f))) {
                Box(Modifier.fillMaxWidth(minOf(s.streak, 5) / 5f).height(4.dp).clip(CircleShape).background(T.purple))
            }
            Spacer(Modifier.height(18.dp))
            Box(Modifier.height(40.dp).press(0.96f) { stats = true }.clip(RoundedCornerShape(10.dp)).background(T.lilac).padding(horizontal = 14.dp), Alignment.Center) {
                Text(t("Ver estatísticas"), style = T.sans(16, T.Medium))
            }
            Spacer(Modifier.weight(1f))
            MenuSection("Ligações")
            MenuItem(Ph.laptop, if (Fala.link.paired) Fala.link.label else "Ligar ao Mac (QR)") { pairing = true }
            MenuItem(Ph.desktop, if (PCNode.configured) "${PCNode.name} ligado" else "Ligar ao PC (QR)") { pairing = true }
            if (Fala.link.paired || PCNode.configured) MenuItem(Ph.sparkle, "Contas de IA") { accounts = true }
            MenuSection("App")
            MenuItem(Ph.sparkle, "Definições") { settings = true }
            MenuItem(Ph.bookOpen, "Dicionário") { dict = false }
            MenuItem(Ph.textAa, "Snippets") { dict = true }
            MenuItem(Ph.notePencil, "Notas") { notes = true }
            // Teclado da Fala (como no iPhone): ativar nas definições e escolher no seletor de teclados.
            MenuItem(Ph.keyboard, "Teclado da Fala") {
                val c = Fala.app
                val on = c.getSystemService(android.view.inputmethod.InputMethodManager::class.java).enabledInputMethodList.any { it.packageName == c.packageName }
                if (on) c.getSystemService(android.view.inputmethod.InputMethodManager::class.java).showInputMethodPicker()
                else c.startActivity(android.content.Intent(android.provider.Settings.ACTION_INPUT_METHOD_SETTINGS).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            MenuItem(Ph.question, "Rever o tutorial") { close(); Fala.prefs.edit().putBoolean("onboarded.v2", false).apply(); (Fala.scope).launch { RestartRoot.ask() } }
        }
    }
    if (stats) StatsSheet { stats = false }
    if (pairing) PairingSheet { pairing = false }
    dict?.let { snip -> PairsScreen(snip) { dict = null } }
    if (notes) NotesScreen { notes = false }
    if (accounts) AIAccountsScreen { accounts = false }
    if (settings) MascotSettings { settings = false }
}

/** "Rever o tutorial": volta ao onboarding sem reiniciar a app. */
object RestartRoot { var tick by mutableStateOf(0); fun ask() { tick++ } }

@Composable
private fun MenuSection(t: String) = Text(t.uppercase(), style = T.sans(12, T.Semi, T.muted), modifier = Modifier.padding(top = 14.dp, bottom = 2.dp))

@Composable
private fun MenuItem(icon: ImageVector, title: String, action: () -> Unit) {
    Row(Modifier.fillMaxWidth().height(44.dp).clickable(remember { MutableInteractionSource() }, null) { tick(); action() }, verticalAlignment = Alignment.CenterVertically) {
        Ic(icon, 19.dp); Spacer(Modifier.width(12.dp))
        Text(title, style = T.sans(17), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

// MARK: Folhas (sheets)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Sheet(onDismiss: () -> Unit, bg: Color = T.appBG, content: @Composable () -> Unit) {
    ModalBottomSheet(onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = bg,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp), dragHandle = {
            Box(Modifier.padding(top = 8.dp).width(36.dp).height(5.dp).clip(CircleShape).background(Color.Black.copy(.18f)))
        }) { Box(Modifier.imePadding().safeBottom()) { content() } }
}

@Composable
fun StatsSheet(close: () -> Unit) = Sheet(close) {
    val s = Fala.store
    Column(Modifier.fillMaxWidth().padding(22.dp)) {
        FalaLogo()
        Spacer(Modifier.height(18.dp))
        Text(t("%,d palavras · %d WPM").format(s.totalWords, s.wpm).replace(',', ' '), style = T.sans(15, color = T.muted))
        Spacer(Modifier.height(18.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Stat("%,d".format(s.totalWords).replace(',', ' '), "palavras ditas", T.forest, Modifier.weight(1f))
            Stat("${s.streak} 🔥", if (s.streak == 1) "dia seguido" else "dias seguidos", T.orange, Modifier.weight(1f))
        }
        Spacer(Modifier.height(10.dp))
        Stat("${s.minutesSaved} min", "poupados a escrever", T.forest, Modifier.fillMaxWidth())
        Spacer(Modifier.height(30.dp))
    }
}

@Composable
private fun Stat(v: String, l: String, c: Color, m: Modifier) = Column(m.card(18.dp).padding(16.dp)) {
    Text(v, style = T.serif(30, color = c)); Spacer(Modifier.height(4.dp)); Text(l, style = T.sans(14, color = T.muted))
}

@Composable
fun PairingSheet(close: () -> Unit) = Sheet(close) {
    var token by remember { mutableStateOf(Fala.link.token) }
    var host by remember { mutableStateOf(Fala.link.host) }
    var result by remember { mutableStateOf<String?>(null) }
    var testing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun save() { Fala.setToken(token); Fala.setHost(host) }
    fun test(internet: Boolean) = scope.launch {
        save(); testing = true
        val t0 = System.currentTimeMillis()
        val n = if (internet) Fala.link.pingInternet() else Fala.link.ping(10.0)
        result = if (n != null) "Ligado a $n via ${if (internet) "internet" else Fala.link.route ?: "rede"} · ${if (internet) System.currentTimeMillis() - t0 else Fala.link.latencyMs ?: 0} ms ✓" else Fala.link.lastError ?: "Sem resposta"
        if (n != null) Outbox.flush()
        testing = false
    }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 18.dp)) {
        Row(Modifier.fillMaxWidth().height(44.dp), verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.width(60.dp))
            Text(t("Ligar um computador"), style = T.sans(17, T.Semi), textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
            Text(t("Feito"), style = T.sans(17, T.Semi), modifier = Modifier.width(60.dp).clickable { tick(); save(); close() }, textAlign = TextAlign.End)
        }
        Spacer(Modifier.height(10.dp))
        val ctx = LocalContext.current
        // Ler o QR do Mac (app Fala no Mac, aba iPhone): scanner do Google Play Services, sem pedir a câmara à Fala.
        Column(Modifier.fillMaxWidth().card(12.dp).padding(horizontal = 16.dp)) {
            FormButton("Ler o QR do Mac ou do PC", true) {
                com.google.mlkit.vision.codescanner.GmsBarcodeScanning.getClient(ctx).startScan().addOnSuccessListener { b ->
                    val raw = b.rawValue.orEmpty()
                    if (raw.startsWith("fala://pair") && Fala.pair(raw)) {
                        if (android.net.Uri.parse(raw).getQueryParameter("k") == "pc") scope.launch { result = if (PCNode.isUp()) "PC ligado ✓ (${PCNode.name})" else "PC guardado, mas não respondeu" }
                        else { token = Fala.link.token; host = Fala.link.host; test(false) }
                    }
                    else result = "Este QR não é da Fala"
                }
            }
        }
        FormFooter("Aponta para o QR e fica ligado para sempre, de qualquer rede.")
        FormHeader("Código do Mac")
        FormField(token, "Código (ex.: K7QX2M9PAB…)", mono = true, caps = true) { token = it.uppercase() }
        FormFooter("Mac: app Fala, aba iPhone. Copia o código (ou abre o link fala://pair no telemóvel) e fica ligado para sempre.")
        FormHeader("Endereço remoto (opcional)")
        FormField(host, "macbook.tail1234.ts.net") { host = it }
        FormFooter("Fora de casa já funciona sozinho pela internet (cifrado). Só precisas disto se usares o Tailscale.")
        Column(Modifier.fillMaxWidth().card(12.dp).padding(horizontal = 16.dp)) {
            FormButton(if (testing) "A testar…" else "Testar ligação", !testing && token.isNotEmpty()) { test(false) }
            HorizontalDivider(color = Color.Black.copy(.1f), thickness = 0.5.dp)
            FormButton("Testar pela internet (como fora de casa)", !testing && token.isNotEmpty()) { test(true) }
            result?.let { HorizontalDivider(color = Color.Black.copy(.1f), thickness = 0.5.dp); Text(it, style = T.sans(17, color = if (it.startsWith("Ligado")) T.forest else T.red), modifier = Modifier.padding(vertical = 12.dp)) }
        }
        Spacer(Modifier.height(40.dp))
    }
}

@Composable private fun FormHeader(t: String) = Text(t.uppercase(), style = T.sans(13, color = T.muted), modifier = Modifier.padding(start = 16.dp, top = 18.dp, bottom = 7.dp))
@Composable private fun FormFooter(t: String) = Text(t, style = T.sans(13, color = T.muted), modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 7.dp))
@Composable private fun FormButton(t: String, enabled: Boolean, onClick: () -> Unit) =
    Text(t, style = T.sans(17, color = if (enabled) Color(0xFF007AFF) else T.disabled), modifier = Modifier.fillMaxWidth().clickable(enabled = enabled) { tick(); onClick() }.padding(vertical = 12.dp))

@Composable
fun FormField(v: String, hint: String, mono: Boolean = false, caps: Boolean = false, bg: Color = Color.White, change: (String) -> Unit) {
    Box(Modifier.fillMaxWidth().card(12.dp, bg).padding(horizontal = 16.dp, vertical = 13.dp)) {
        if (v.isEmpty()) Text(hint, style = T.sans(17, color = T.ink.copy(.3f)))
        BasicTextField(v, change, singleLine = true, cursorBrush = SolidColor(T.ink),
            textStyle = if (mono) T.sans(17).copy(fontFamily = T.mono) else T.sans(17), modifier = Modifier.fillMaxWidth(),
            keyboardOptions = KeyboardOptions(capitalization = if (caps) KeyboardCapitalization.Characters else KeyboardCapitalization.None, autoCorrectEnabled = false))
    }
}

// MARK: Dicionário / Snippets / Notas

@Composable
fun FullScreen(close: () -> Unit, content: @Composable () -> Unit) {
    BackHandler { close() }
    Box(Modifier.fillMaxSize().background(T.appBG).statusBarsPadding().clickable(remember { MutableInteractionSource() }, null) {}) { content() }
}

@Composable
fun PairsScreen(snip: Boolean, close: () -> Unit) = FullScreen(close) {
    var adding by remember { mutableStateOf(false) }
    var banner by remember { mutableStateOf(Fala.prefs.getBoolean(if (snip) "banner.snip" else "banner.dict", true)) }
    val items = (if (snip) Fala.store.snippets else Fala.store.dictionary).entries.sortedBy { it.key.lowercase() }
    Column(Modifier.fillMaxSize()) {
        FlowHeader(Ph.caretLeft, close) { Text(if (snip) "Snippets" else "Dicionário", style = T.sans(18, T.Medium)) }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(start = 18.dp, end = 18.dp, top = 18.dp, bottom = 110.dp)) {
            if (banner) {
                FlowBanner(italicTail(if (snip) "O que não devias ter de reescrever" else "A Fala escreve como tu falas", ""),
                    italicTail(if (snip) "Guarda atalhos para o que escreves muitas vezes: emails, links, moradas, bios. Diz o gatilho e aparece tudo."
                    else "A Fala aprende as tuas palavras: nomes, marcas, jargão da empresa e termos da área.", ""),
                    if (snip) "Novo snippet" else "Adicionar palavra", onCta = { adding = true }, onClose = { banner = false; Fala.prefs.edit().putBoolean(if (snip) "banner.snip" else "banner.dict", false).apply() })
                Spacer(Modifier.height(14.dp))
            }
            Text("${if (snip) "Os teus snippets" else "As tuas palavras"} (${items.size})", style = T.sans(16, color = T.ink.copy(.6f)), modifier = Modifier.padding(start = 2.dp, top = 8.dp, bottom = 14.dp))
            if (items.isNotEmpty()) Column(Modifier.fillMaxWidth().card().padding(horizontal = 18.dp)) {
                items.forEachIndexed { i, (k, v) ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 18.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(if (k == v) k else "$k → $v", style = T.sans(16), modifier = Modifier.weight(1f))
                        Box(Modifier.size(28.dp).press(0.9f) { Fala.store.setPair(snip, k, null) }, Alignment.Center) { Ic(Ph.trash, 17.dp, T.muted) }
                    }
                    if (i < items.lastIndex) HorizontalDivider(color = Color.Black.copy(.1f), thickness = 0.5.dp)
                }
            }
        }
        FlowFAB(Modifier.align(Alignment.End).offset((-22).dp, (-84).dp)) { adding = true }
    }
    if (adding) Sheet({ adding = false }, Color.White) {
        var from by remember { mutableStateOf("") }; var to by remember { mutableStateOf("") }
        var misspelling by remember { mutableStateOf(true) }
        val two = snip || misspelling
        val can = from.isNotEmpty() && (!two || to.isNotEmpty())
        Column(Modifier.fillMaxWidth().padding(22.dp)) {
            Text(if (snip) "Novo snippet" else "Adicionar ao dicionário", style = T.sans(18, T.Semi))
            Spacer(Modifier.height(16.dp))
            if (!snip) { Row(verticalAlignment = Alignment.CenterVertically) { Text(t("Corrigir um erro de escrita"), style = T.sans(16), modifier = Modifier.weight(1f)); IOSSwitch(misspelling) { misspelling = it } }; Spacer(Modifier.height(16.dp)) }
            GreyField(from, if (snip) "Gatilho (ex: meu email)" else if (misspelling) "O que a Fala ouve (ex: clode)" else "Palavra") { from = it }
            if (two) { Spacer(Modifier.height(16.dp)); GreyField(to, if (snip) "Texto a escrever" else "Como deve escrever (ex: Claude)") { to = it } }
            Spacer(Modifier.height(16.dp))
            DarkButton("Guardar", can) { Fala.store.setPair(snip, from.trim(), if (two) to.trim() else from.trim()); adding = false }
            Spacer(Modifier.height(20.dp))
        }
    }
}

@Composable
fun GreyField(v: String, hint: String, change: (String) -> Unit) {
    Box(Modifier.fillMaxWidth().height(50.dp).clip(RoundedCornerShape(12.dp)).background(T.appBG).padding(horizontal = 14.dp), Alignment.CenterStart) {
        if (v.isEmpty()) Text(hint, style = T.sans(16, color = T.ink.copy(.3f)))
        BasicTextField(v, change, singleLine = true, textStyle = T.sans(16), cursorBrush = SolidColor(T.ink), modifier = Modifier.fillMaxWidth())
    }
}

@Composable
fun NotesScreen(close: () -> Unit) = FullScreen({ Fala.store.saveScratch(); close() }) {
    Column(Modifier.fillMaxSize().imePadding()) {
        FlowHeader(Ph.caretLeft, { Fala.store.saveScratch(); close() }) { Text(t("Notas"), style = T.sans(18, T.Medium)) }
        Column(Modifier.weight(1f).padding(18.dp)) {
            Text(java.time.LocalDate.now().format(DateTimeFormatter.ofPattern("d MMM yyyy", java.util.Locale.forLanguageTag("pt-PT"))), style = T.sans(16, color = T.ink.copy(.6f)), modifier = Modifier.padding(start = 2.dp))
            Spacer(Modifier.height(12.dp))
            Box(Modifier.fillMaxSize().card().padding(17.dp)) {
                if (Fala.store.scratchpad.isEmpty()) Text(t("Apanha uma ideia antes que fuja…"), style = T.sans(16, color = T.ink.copy(.35f)))
                BasicTextField(Fala.store.scratchpad, { Fala.store.scratchpad = it }, textStyle = T.sans(16), cursorBrush = SolidColor(T.ink), modifier = Modifier.fillMaxSize())
            }
        }
    }
}
