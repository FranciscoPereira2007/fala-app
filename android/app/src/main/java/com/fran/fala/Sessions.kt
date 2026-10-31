package com.fran.fala

import androidx.compose.runtime.mutableStateListOf
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.Canvas
import androidx.compose.ui.graphics.StrokeJoin
import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.max
import kotlin.math.sin

// MARK: Aba Sessões

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionsScreen(open: (Session) -> Unit, dotChat: () -> Unit = {}, call: (String, (suspend (String) -> String)?) -> Unit = { _, _ -> }) {
    val j = Fala.jarvis
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<Session?>(null) }
    val toast = remember { mutableStateOf<FlowToast?>(null) }
    // Estados ao vivo (a trabalhar / precisa de ti) enquanto a aba está aberta.
    LaunchedEffect(Unit) { while (true) { if (!j.chatOpen) j.refresh(); delay(6000) } }
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            FlowHeader(onMenu = null, trailing = {
                Box(Modifier.size(44.dp).press(0.9f) { scope.launch { j.refresh() } }, Alignment.Center) { Ic(Ph.arrowClockwise, 20.dp) }
            }) { Text(t("Sessões"), style = T.sans(18, T.Medium)) }
            PullToRefreshBox(refreshing, { scope.launch { refreshing = true; j.refresh(); refreshing = false } }, Modifier.fillMaxSize()) {
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).safeBottom().padding(start = 18.dp, end = 18.dp, bottom = 110.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text(italicTail("Os teus agentes, ", "no bolso", T.orange), style = T.serif(28), modifier = Modifier.padding(top = 8.dp))
                    if (Fala.link.paired || PCNode.configured) DotCard(open = dotChat, call = { call("Jarvis", null) })
                    if (j.doneToday > 0) Row(verticalAlignment = Alignment.CenterVertically) {
                        Ic(Ph.sealCheckFill, 17.dp, T.forest); Spacer(Modifier.width(6.dp))
                        Text("Hoje: ${j.doneToday} ${if (j.doneToday == 1) "tarefa terminada" else "tarefas terminadas"}", style = T.sans(14, T.Semi, T.forest))
                    }
                    if (j.error != null && j.sessions.isEmpty()) Row(verticalAlignment = Alignment.CenterVertically) {
                        Ic(Ph.wifiSlash, 16.dp, T.muted); Spacer(Modifier.width(6.dp)); Text(j.error!!, style = T.sans(14, color = T.muted))
                    }
                    if (j.loading) Box(Modifier.fillMaxWidth().padding(30.dp), Alignment.Center) { CircularProgressIndicator(Modifier.size(24.dp), T.muted, strokeWidth = 2.dp) }
                    if (!j.loading && j.sessions.isEmpty() && j.error == null) Column(Modifier.fillMaxWidth().card().padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(t("Nenhuma sessão a correr no Mac."), style = T.sans(16, T.Semi))
                        Text(t("Abre o Claude Code no iTerm ou uma conversa no Codex e ela aparece aqui sozinha."), style = T.sans(14, color = T.muted))
                        Row(Modifier.press { scope.launch { j.refresh() } }, verticalAlignment = Alignment.CenterVertically) { Ic(Ph.arrowClockwise, 15.dp); Spacer(Modifier.width(6.dp)); Text(t("Procurar outra vez"), style = T.sans(14, T.Semi)) }
                    }
                    // As conversas do teu Jarvis (pasta Fala/Jarvis) vivem no cartão dele, não na lista.
                    val shown = j.sessions.filter { it.id !in j.archived && !it.cwd.endsWith("Fala/Jarvis") }
                    val pins = shown.filter { it.id in j.pinned }; val rest = shown.filter { it.id !in j.pinned }
                    val active = rest.filter(j::isActive).sortedBy { if (it.needsYou) 0 else if (it.busy) 1 else 2 }
                    Group("Afixadas", pins, open, onRename = { renaming = it }, toast)
                    Group("Ativas agora", active, open, onRename = { renaming = it }, toast)
                    Group("Antigas", rest.filter { !j.isActive(it) }, open, onRename = { renaming = it }, toast)
                }
            }
        }
        ToastHost(toast)
    }
    renaming?.let { s ->
        Sheet({ renaming = null }, Color.White) {
            var n by remember { mutableStateOf(j.title(s)) }
            Column(Modifier.fillMaxWidth().padding(22.dp)) {
                Text(t("Renomear sessão"), style = T.sans(18, T.Semi)); Spacer(Modifier.height(16.dp))
                GreyField(n, "Nome") { n = it }; Spacer(Modifier.height(16.dp))
                DarkButton("Guardar") {
                    val name = n.trim(); j.setAlias(s.id, name); renaming = null
                    if (s.kind == "claude" && name.isNotEmpty()) Fala.scope.launch { j.send(s.id, "/rename $name") }
                }
                Spacer(Modifier.height(20.dp))
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Group(title: String, list: List<Session>, open: (Session) -> Unit, onRename: (Session) -> Unit, toast: androidx.compose.runtime.MutableState<FlowToast?>) {
    if (list.isEmpty()) return
    val j = Fala.jarvis
    val ctx = LocalContext.current
    Column {
        Text(title.uppercase() + " · ${list.size}", style = T.sans(12, T.Semi, T.muted), modifier = Modifier.padding(top = 6.dp, bottom = 14.dp))
        Column(Modifier.fillMaxWidth().card().alpha(if (title == "Antigas") .75f else 1f).padding(horizontal = 16.dp).animateContentSize()) {
            list.forEachIndexed { i, s ->
                var menu by remember { mutableStateOf(false) }
                Box {
                    Row(Modifier.fillMaxWidth().combinedClickable(remember { MutableInteractionSource() }, null,
                        onLongClick = { Haptics.medium(); menu = true }) { tick(); open(s) }.padding(vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                        SessionPet(s.id, s.busy, j.isActive(s), s.needsYou)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(j.title(s), style = T.sans(16, T.Semi), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, false))
                                DeviceTag(s.id)
                            }
                            Spacer(Modifier.height(3.dp))
                            when {
                                s.needsYou -> Text(t("Precisa de ti"), style = T.sans(14, T.Medium, T.orange))
                                s.busy -> Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(s.doing ?: s.lastReply ?: "A trabalhar", style = T.sans(14, color = T.green), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, false))
                                    WorkingDots(T.green)
                                }
                                s.shell -> Row(verticalAlignment = Alignment.CenterVertically) { Ic(Ph.terminalWindow, 14.dp, T.muted); Spacer(Modifier.width(4.dp)); Text(t("Comando em fundo a correr"), style = T.sans(13, color = T.muted)) }
                                !s.lastReply.isNullOrEmpty() -> Text(s.lastReply, style = T.sans(14, color = T.ink.copy(.55f)), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                    IOSMenu(menu, { menu = false }, listOf(
                        MenuAction("Ligar", Ph.phone) { CallCenter.call(s) },
                        MenuAction(if (s.id in j.pinned) "Desafixar" else "Afixar", if (s.id in j.pinned) Ph.pushPinSlash else Ph.pushPin) { j.togglePin(s.id) },
                        MenuAction("Mudar o nome", Ph.pencilSimple) { onRename(s) },
                        MenuAction("Copiar ID", Ph.copy) { ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("id", s.id)); toast.value = FlowToast("ID copiado") },
                        MenuAction("Arquivar", Ph.archive, destructive = true) { j.archive(s.id) }))
                }
                if (i < list.lastIndex) HorizontalDivider(color = Color.Black.copy(.1f), thickness = 0.5.dp)
            }
        }
    }
}

class MenuAction(val title: String, val icon: ImageVector? = null, val destructive: Boolean = false, val checked: Boolean = false, val run: () -> Unit)

/** Menu de contexto ao estilo do iOS (cartão branco, linhas finas, ícone à direita). */
@Composable
fun IOSMenu(expanded: Boolean, dismiss: () -> Unit, actions: List<MenuAction>, header: String? = null) {
    DropdownMenu(expanded, dismiss, shape = RoundedCornerShape(13.dp), containerColor = Color(0xFFF7F7F8), shadowElevation = 14.dp, modifier = Modifier.widthIn(min = 230.dp)) {
        header?.let { Text(it, style = T.sans(13, color = T.muted), modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) }
        actions.forEachIndexed { i, a ->
            val c = if (a.destructive) T.red else T.ink
            DropdownMenuItem(text = { Text(a.title, style = T.sans(17, color = c)) }, onClick = { tick(); dismiss(); a.run() },
                leadingIcon = if (a.checked) ({ Ic(Ph.check, 17.dp, c) }) else null,
                trailingIcon = a.icon?.let { { Ic(it, 19.dp, c) } })
            if (i < actions.lastIndex) HorizontalDivider(color = Color.Black.copy(.08f), thickness = 0.5.dp)
        }
    }
}

@Composable
fun DeviceTag(id: String) {
    val s = Fala.jarvis.sessions
    if (s.any { it.id.startsWith("pc:") } && s.any { !it.id.startsWith("pc:") } || s.any { it.cwd.contains(":\\") || it.cwd.startsWith("C:/") }) {
        val pc = id.startsWith("pc:") || s.firstOrNull { it.id == id }?.cwd?.let { it.contains(":\\") || it.matches(Regex("^[A-Z]:/.*")) } == true
        Spacer(Modifier.width(6.dp))
        Text(if (pc) "PC" else "Mac", style = T.sans(10, T.Semi, T.muted), modifier = Modifier.clip(CircleShape).background(T.ink.copy(.06f)).padding(horizontal = 6.dp, vertical = 2.dp))
    }
}

// MARK: Conversa com uma sessão

@Composable
fun SessionChat(session: Session, close: () -> Unit, call: () -> Unit = {}) {
    val j = Fala.jarvis
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val live = j.sessions.firstOrNull { it.id == session.id } ?: session
    var draft by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var dictating by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    var attach by remember { mutableStateOf<Pair<String, ByteArray>?>(null) }
    var viewer by remember { mutableStateOf<Pair<String, ByteArray>?>(null) }
    val toast = remember { mutableStateOf<FlowToast?>(null) }
    val list = rememberLazyListState()
    BackHandler { if (dictating) { Recorder.stop(); dictating = false } else close() }

    LaunchedEffect(session.id) { while (true) { j.load(session.id); delay(if (live.busy) 2000 else 5000) } }
    LaunchedEffect(Unit) { j.loadCommands() }
    var wasBusy by remember { mutableStateOf(live.busy) }
    LaunchedEffect(live.busy) {
        if (wasBusy && !live.busy) { Haptics.success(); toast.value = FlowToast("Terminou ✓ " + (live.lastReply ?: "").take(70)) }
        wasBusy = live.busy
    }
    val msgs = j.messages[session.id].orEmpty()
    val queued = j.queued[session.id].orEmpty()
    LaunchedEffect(msgs.lastOrNull()?.id, queued.size) { val n = msgs.size + queued.size + 1; if (n > 0) list.animateScrollToItem(n - 1) }

    val askMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { if (it) dictating = Recorder.start() }
    /** Pára o ditado e espera pelo texto do Whisper (Enviar a meio do ditado manda o que disseste). */
    suspend fun stopDictation() {
        dictating = false
        val pcm = Recorder.stop()
        // O Whisper do Mac transcreve em modo teste (não cola nada no Mac); o texto fica na caixa.
        if (pcm.size > 8000) Fala.link.sendAudio(pcm, enter = false, paste = false, timeoutS = 12.0)?.takeIf { it.isNotBlank() }?.let { draft = listOf(draft, it).filter(String::isNotEmpty).joinToString(" ") }
        else toast.value = FlowToast("Não ouvi nada", false)
    }
    fun toggleDictation() {
        if (!dictating) { if (Recorder.permitted(ctx)) dictating = Recorder.start() else askMic.launch(Manifest.permission.RECORD_AUDIO); return }
        scope.launch { stopDictation() }
    }
    suspend fun send(force: Boolean) {
        val t = draft.trim()
        if (t.isEmpty() && attach == null) return
        if (live.busy && !force) { confirm = true; return }
        sending = true
        val e = j.send(session.id, t, attach?.first, attach?.second)
        sending = false
        if (e != null) { Haptics.error(); toast.value = FlowToast(e, false) } else { draft = ""; attach = null; toast.value = FlowToast("Enviado") }
    }
    // Sair da conversa por qualquer caminho (seta, gesto, notificação) fecha o micro dela.
    androidx.compose.runtime.DisposableEffect(Unit) { onDispose { if (dictating) Recorder.stop() } }

    val cam = remember { File(ctx.cacheDir, "foto.jpg") }
    val takePhoto = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok -> if (ok) attach = "foto.jpg" to shrink(cam.readBytes()) }
    val pickPhoto = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { u -> u?.let { attach = "foto.jpg" to shrink(read(ctx, it)) } }
    val pickFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { u -> u?.let { attach = name(ctx, it) to read(ctx, it) } }

    Box(Modifier.fillMaxSize().background(T.appBG)) {
        Column(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
            FlowHeader(Ph.caretLeft, close, trailing = {
                CircleIcon(Ph.phone, T.green, Color.White, 44.dp, 20.dp, haptic = Haptics::heavy) { call() }
            }) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 50.dp)) {
                    Box(Modifier.size(38.dp, 40.dp), Alignment.Center) { SessionPet(session.id, live.busy, true, live.needsYou, Modifier.scale(.8f)) }
                    Spacer(Modifier.width(4.dp))
                    Text(j.title(live), style = T.sans(17, T.Semi), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, false))
                    DeviceTag(session.id)
                }
            }
            LazyColumn(Modifier.weight(1f).fillMaxWidth(), list, contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp, 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                items(msgs, key = { it.id }) { m -> Bubble(m, onMedia = { p, d -> viewer = p to d }) }
                items(queued.size) { i ->
                    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End) {
                        Box(Modifier.alpha(.75f)) { Bubble(Msg("q$i", "user", queued[i], 0)) { _, _ -> } }
                        Spacer(Modifier.height(4.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) { Ic(Ph.clock, 13.dp, T.muted); Spacer(Modifier.width(4.dp)); Text(if (live.busy) "Na fila: entra quando acabar o que está a fazer" else "Enviada", style = T.sans(12, color = T.muted)) }
                    }
                }
                item {
                    if (live.busy) WorkingRow()
                    else if (live.shell) Row(Modifier.padding(start = 4.dp), verticalAlignment = Alignment.CenterVertically) { Ic(Ph.terminalWindow, 14.dp, T.muted); Spacer(Modifier.width(6.dp)); Text(t("Parado, com um comando em fundo a correr"), style = T.sans(13, color = T.muted)) }
                }
            }
            Composer(live, draft, { draft = it }, dictating, sending, attach, { attach = null },
                onPlus = { which -> when (which) {
                    0 -> { val u = FileProvider.getUriForFile(ctx, ctx.packageName + ".files", cam); takePhoto.launch(u) }
                    1 -> pickPhoto.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    else -> pickFile.launch(arrayOf("*/*"))
                } },
                onMic = ::toggleDictation, onSend = { scope.launch { if (dictating) stopDictation(); send(false) } }, toast = toast)
        }
        Box(Modifier.statusBarsPadding()) { ToastHost(toast) }
    }
    if (confirm) Sheet({ confirm = false }, Color.White) {
        Column(Modifier.fillMaxWidth().padding(22.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(t("A sessão está ocupada. Mandar na mesma? Fica na fila do agente."), style = T.sans(15, color = T.muted))
            DarkButton("Enviar") { confirm = false; scope.launch { send(true) } }
            Text(t("Cancelar"), style = T.sans(17, T.Semi), modifier = Modifier.fillMaxWidth().clickable { confirm = false }.padding(12.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Spacer(Modifier.height(8.dp))
        }
    }
    viewer?.let { (p, d) -> MediaViewer(p, d, onAttach = { out, n -> attach = n to out }) { viewer = null } }
}

@Composable
private fun Composer(live: Session, draft: String, setDraft: (String) -> Unit, dictating: Boolean, sending: Boolean, attach: Pair<String, ByteArray>?, clearAttach: () -> Unit,
                     onPlus: (Int) -> Unit, onMic: () -> Unit, onSend: () -> Unit, toast: androidx.compose.runtime.MutableState<FlowToast?>) {
    val j = Fala.jarvis
    val scope = rememberCoroutineScope()
    val canSend = draft.isNotBlank() || attach != null
    // Última palavra começa por "/" (ou "mcp:") = lista filtrada, como no Claude Code.
    val word = draft.split(" ").lastOrNull()?.takeIf { it.startsWith("/") || it.startsWith("mcp:") }?.lowercase()
    val suggestions = remember(word, j.commands, j.commandsError) {
        if (word == null) emptyList()
        else if (j.commands.isEmpty()) listOf((j.commandsError?.let { "⚠︎ $it" } ?: "A carregar a lista…") + "\t")
        else {
            val q = word.removePrefix("/")
            fun n(c: String) = c.lowercase().substringBefore("\t").trim('/')
            if (q.isEmpty()) j.commands.take(200) else (j.commands.filter { n(it).startsWith(q) } + j.commands.filter { !n(it).startsWith(q) && n(it).contains(q) }).take(60)
        }
    }
    Column(Modifier.fillMaxWidth().safeBottom().padding(top = 6.dp, bottom = 14.dp)) {
        AnimatedVisibility(suggestions.isNotEmpty(), enter = slideInVertically { it / 3 } + fadeIn(), exit = slideOutVertically { it / 3 } + fadeOut()) {
            LazyColumn(Modifier.padding(horizontal = 12.dp).padding(bottom = 8.dp).heightIn(max = 260.dp).fillMaxWidth().card(18.dp)) {
                items(suggestions) { c ->
                    val p = c.split("\t")
                    Column(Modifier.fillMaxWidth().clickable {
                        tick()
                        if (c.startsWith("⚠︎") || c.startsWith("A carregar")) { j.commandsError = null; scope.launch { j.loadCommands() } }
                        else { val ins = if (p[0].startsWith("mcp:")) "usa o MCP " + p[0].drop(4) else p[0]; setDraft((draft.split(" ").dropLast(1) + ins).joinToString(" ") + " ") }
                    }.padding(horizontal = 14.dp, vertical = 8.dp)) {
                        Text(p[0], style = T.sans(15, T.Semi).copy(fontFamily = T.mono))
                        if (p.size > 1 && p[1].isNotEmpty()) Text(p[1], style = T.sans(12, color = T.muted), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
        Column(Modifier.padding(horizontal = 12.dp).fillMaxWidth().card(24.dp).padding(14.dp).animateContentSize(spring(stiffness = 500f)), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            attach?.let { (n, d) -> AttachPreview(n, d, clearAttach) }
            if (dictating) {
                FlowWaveform(Recorder.level, WaveMode.Listening, height = 44.dp, modifier = Modifier.align(Alignment.CenterHorizontally))
                Text(if (draft.isEmpty()) "A ouvir… diz o teu prompt" else draft, style = T.sans(16, color = if (draft.isEmpty()) T.muted else T.ink), modifier = Modifier.fillMaxWidth().heightIn(min = 60.dp))
            } else Box {
                if (draft.isEmpty()) Text(if (live.busy) "Adiciona à fila para depois deste" else "Escreve ou dita um prompt", style = T.sans(16, color = T.ink.copy(.3f)))
                BasicTextField(draft, setDraft, textStyle = T.sans(16), cursorBrush = SolidColor(T.ink), maxLines = 6, modifier = Modifier.fillMaxWidth())
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                var plus by remember { mutableStateOf(false) }
                Box {
                    CircleIcon(Ph.plus, T.appBG, T.ink, 36.dp, 19.dp) { plus = true }
                    IOSMenu(plus, { plus = false }, listOf(MenuAction("Câmara", Ph.camera) { onPlus(0) }, MenuAction("Fotos", Ph.images) { onPlus(1) }, MenuAction("Ficheiro", Ph.file) { onPlus(2) }))
                }
                if (live.kind == "claude") {
                    var model by remember { mutableStateOf(false) }
                    val p = Fala.prefs
                    Box {
                        Pill(p.getString("jarvis.model.${live.id}", "Modelo")!! + (p.getString("jarvis.effort.${live.id}", null)?.let { " $it" } ?: "")) { model = true }
                        IOSMenu(model, { model = false }, MODELS.map { (l, v) -> MenuAction(l) { scope.launch { command(live.id, "/model $v", "model", l, toast) } } } +
                            EFFORTS.map { (l, v) -> MenuAction("Effort: $l") { scope.launch { command(live.id, "/effort $v", "effort", l, toast) } } })
                    }
                    var mode by remember { mutableStateOf(false) }
                    Box {
                        Pill(MODES.firstOrNull { it.second == (live.mode ?: "default") }?.first ?: "Normal", color = if (live.mode == "bypassPermissions") T.orange else T.ink) { mode = true }
                        IOSMenu(mode, { mode = false }, MODES.map { (l, v) -> MenuAction(l, checked = (live.mode ?: "default") == v) {
                            scope.launch { val e = j.setMode(live.id, v); toast.value = if (e == null) FlowToast("Modo: $l") else FlowToast(e, false) } } })
                    }
                }
                Spacer(Modifier.weight(1f))
                CircleIcon(if (dictating) Ph.check else Ph.microphone, if (dictating) T.orange else T.appBG, if (dictating) Color.White else T.ink, 36.dp, 19.dp, haptic = Haptics::medium) { onMic() }
                CircleIcon(if (sending) Ph.hourglass else Ph.arrowUp, if (canSend || dictating) T.ink else T.disabled, Color.White, 36.dp, 19.dp, enabled = (canSend || dictating) && !sending, haptic = Haptics::medium) { onSend() }
            }
        }
    }
}

private val MODELS = listOf("Opus" to "opus", "Sonnet" to "sonnet", "Haiku" to "haiku")
private val MODES = listOf("Normal" to "default", "Aceitar edições" to "acceptEdits", "Planear" to "plan", "Sem perguntas" to "bypassPermissions")
private val EFFORTS = listOf("Baixo" to "low", "Médio" to "medium", "Alto" to "high", "Máximo" to "max")

private suspend fun command(id: String, c: String, key: String, label: String, toast: androidx.compose.runtime.MutableState<FlowToast?>) {
    val e = Fala.jarvis.send(id, c)
    if (e != null) { toast.value = FlowToast(e, false); return }
    Fala.prefs.edit().putString("jarvis.$key.$id", label).apply()
    toast.value = FlowToast(label)
}

private fun read(c: android.content.Context, u: Uri) = c.contentResolver.openInputStream(u)?.use { it.readBytes() } ?: ByteArray(0)
private fun name(c: android.content.Context, u: Uri) = c.contentResolver.query(u, null, null, null, null)?.use { if (it.moveToFirst()) it.getString(it.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME)) else null } ?: "ficheiro"

/** JPEG 1600 px chega para o agente ler (como o iPhone). */
private fun shrink(d: ByteArray, max: Int = 1600): ByteArray {
    val b = BitmapFactory.decodeByteArray(d, 0, d.size) ?: return d
    val k = minOf(1f, max.toFloat() / maxOf(b.width, b.height))
    val s = if (k < 1) android.graphics.Bitmap.createScaledBitmap(b, (b.width * k).toInt(), (b.height * k).toInt(), true) else b
    return ByteArrayOutputStream().also { s.compress(android.graphics.Bitmap.CompressFormat.JPEG, 75, it) }.toByteArray()
}

@Composable
private fun AttachPreview(n: String, d: ByteArray, remove: () -> Unit) {
    val bmp = remember(d) { BitmapFactory.decodeByteArray(d, 0, d.size)?.asImageBitmap() }
    Box {
        if (bmp != null) Image(bmp, null, Modifier.size(64.dp).clip(RoundedCornerShape(12.dp)), contentScale = ContentScale.Crop)
        else Row(Modifier.clip(RoundedCornerShape(12.dp)).background(T.appBG).padding(10.dp), verticalAlignment = Alignment.CenterVertically) { Ic(Ph.file, 18.dp); Spacer(Modifier.width(6.dp)); Text(n, style = T.sans(14), maxLines = 1) }
        Box(Modifier.offset(if (bmp != null) 52.dp else 0.dp, (-6).dp).size(22.dp).press(0.9f, onClick = remove).clip(CircleShape).background(T.ink), Alignment.Center) { Ic(Ph.x, 12.dp, Color.White) }
    }
}

// MARK: Bolhas

@Composable
private fun Bubble(m: Msg, onMedia: (String, ByteArray) -> Unit) {
    when {
        m.role == "tool" && toolImage(m.text) != null -> MediaThumb(toolImage(m.text)!!, onMedia)
        m.role == "tool" && m.text.startsWith("Desc · ") -> Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(T.ink.copy(.04f)).padding(horizontal = 12.dp, vertical = 8.dp)) {
            Ic(Ph.terminalWindow, 14.dp, T.orange, Modifier.padding(top = 2.dp)); Spacer(Modifier.width(8.dp))
            Text(m.text.drop(7), style = T.sans(14, color = T.ink.copy(.7f)), maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
        m.role == "tool" -> {
            val p = m.text.split(" · ")
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(T.ink.copy(.04f)).padding(horizontal = 12.dp, vertical = 8.dp)) {
                Ic(toolIcon(p[0]), 14.dp, T.orange, Modifier.padding(top = 2.dp)); Spacer(Modifier.width(8.dp))
                Text(buildAnnotatedString {
                    withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(p[0]) }
                    if (p.size > 1) withStyle(SpanStyle(color = T.ink.copy(.6f))) { append("  " + p.drop(1).joinToString(" · ")) }
                }, style = T.sans(13).copy(fontFamily = T.mono), maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
        }
        else -> {
            val mine = m.role == "user"
            Row(Modifier.fillMaxWidth(), horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
                if (mine) Spacer(Modifier.width(40.dp))
                SelectionContainer(Modifier.weight(1f, false).clip(RoundedCornerShape(16.dp)).background(if (mine) T.lilac else Color.White).padding(12.dp)) {
                    RichText(if (m.text.length > 2500) m.text.take(2500) + "…" else m.text)
                }
                if (!mine) Spacer(Modifier.width(40.dp))
            }
            val media = mediaPaths(m.text)
            if (media.isNotEmpty()) Row(Modifier.horizontalScroll(rememberScrollState()).padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) { media.forEach { MediaThumb(it, onMedia) } }
        }
    }
}

private fun toolImage(t: String): String? {
    for (p in listOf("Image · ", "Read · ")) if (t.startsWith(p)) {
        val path = t.removePrefix(p)
        if (path.startsWith("/") && path.substringAfterLast('.').lowercase() in listOf("png", "jpg", "jpeg", "gif", "webp", "heic", "mp4", "mov", "m4v")) return path
    }
    return null
}

private fun mediaPaths(t: String) = Regex("((?:/Users|/private|/tmp|/var)/[^\\s`'\"()<>]+?\\.(?:png|jpe?g|gif|webp|heic|mp4|mov|m4v))", RegexOption.IGNORE_CASE)
    .findAll(t).map { it.groupValues[1] }.distinct().take(6).toList()

private fun toolIcon(n: String) = when (n) {
    "Bash" -> Ph.terminalWindow; "Edit", "Write", "MultiEdit", "NotebookEdit" -> Ph.pencilSimple; "Read" -> Ph.fileText
    "Grep", "Glob", "ToolSearch" -> Ph.magnifyingGlass; "Agent", "Task" -> Ph.users; "WebFetch", "WebSearch" -> Ph.globe
    else -> Ph.wrench
}

private val mediaCache = HashMap<String, ByteArray>()

private fun isVideo(p: String) = p.substringAfterLast('.').lowercase() in listOf("mp4", "mov", "m4v")

@Composable
private fun MediaThumb(path: String, open: (String, ByteArray) -> Unit) {
    var failed by remember(path) { mutableStateOf(false) }
    val data by produceState(mediaCache[path], path) { if (value == null) { value = Fala.jarvis.media(path)?.also { mediaCache[path] = it }; failed = value == null } }
    val video = isVideo(path)
    val bmp = remember(data) { if (video) null else data?.let { BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap() } }
    Box(Modifier.size(150.dp).clip(RoundedCornerShape(14.dp)).background(T.ink.copy(.06f)).clickable(enabled = data != null) { tick(); open(path, data!!) }, Alignment.Center) {
        when {
            bmp != null -> Image(bmp, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            failed -> Ic(Ph.info, 22.dp, T.muted)
            data == null -> CircularProgressIndicator(Modifier.size(18.dp), T.muted, strokeWidth = 2.dp)
        }
        if (video) Box(Modifier.size(44.dp).clip(CircleShape).background(Color.Black.copy(.45f)), Alignment.Center) { Ic(Ph.play, 22.dp, Color.White) }
    }
}

/** Ecrã inteiro (Media.swift do iPhone): ver, rodear com o lápis vermelho e mandar a imagem (marcada) para a caixa do chat. */
@Composable
private fun MediaViewer(path: String, d: ByteArray, onAttach: (ByteArray, String) -> Unit, close: () -> Unit) {
    val ctx = LocalContext.current
    val video = isVideo(path)
    val bmp = remember(d) { if (video) null else BitmapFactory.decodeByteArray(d, 0, d.size) }
    val strokes = remember { mutableStateListOf<List<Offset>>() }
    var current by remember { mutableStateOf<List<Offset>>(emptyList()) }
    var pencil by remember { mutableStateOf(false) }
    var box by remember { mutableStateOf(androidx.compose.ui.unit.IntSize.Zero) }
    Dialog(close, DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            if (video) AndroidView({ c ->
                android.widget.VideoView(c).apply {
                    val f = java.io.File(c.cacheDir, path.substringAfterLast('/')); if (!f.exists()) f.writeBytes(d)
                    setVideoPath(f.path); setMediaController(android.widget.MediaController(c).also { it.setAnchorView(this) }); start()
                }
            }, Modifier.fillMaxSize().safeBottom())
            else if (bmp != null) {
                val img = bmp.asImageBitmap()
                Box(Modifier.fillMaxSize(), Alignment.Center) {
                    val ar = bmp.width.toFloat() / bmp.height
                    Box(Modifier.fillMaxWidth().aspectRatio(ar).onSizeChanged { box = it }) {
                        Image(img, null, Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds)
                        Canvas(Modifier.fillMaxSize().then(if (pencil) Modifier.pointerInput(Unit) {
                            detectDragGestures(onDragStart = { current = listOf(it) }, onDragEnd = { strokes += current; current = emptyList() }) { ch, _ -> current = current + ch.position }
                        } else Modifier)) {
                            for (st in strokes + listOf(current)) if (st.size > 1) drawPath(Path().apply { moveTo(st[0].x, st[0].y); st.drop(1).forEach { lineTo(it.x, it.y) } },
                                Color(0xFFFF3B30), style = Stroke(6.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
                        }
                    }
                }
            }
            Row(Modifier.fillMaxWidth().statusBarsPadding().padding(16.dp, 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                CircleIcon(Ph.x, Color.White.copy(.18f), Color.White, 44.dp, 17.dp) { close() }
                Spacer(Modifier.weight(1f))
                if (!video) {
                    if (strokes.isNotEmpty()) CircleIcon(Ph.arrowClockwise, Color.White.copy(.18f), Color.White, 44.dp, 17.dp) { strokes.removeAt(strokes.lastIndex) }
                    CircleIcon(Ph.pencilSimple, if (pencil) Color.White else Color.White.copy(.18f), if (pencil) T.ink else Color.White, 44.dp, 17.dp) { pencil = !pencil }
                }
            }
            if (!video && bmp != null) Row(Modifier.align(Alignment.BottomCenter).safeBottom(24.dp).clip(CircleShape).background(Color.White)
                .press(0.96f, haptic = Haptics::heavy) {
                    val out = if (strokes.isEmpty()) d else render(bmp, strokes, box) ?: d
                    onAttach(out, (if (strokes.isEmpty()) "" else "marcada-") + path.substringAfterLast('/')); close()
                }.padding(20.dp, 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Ic(Ph.arrowUp, 18.dp, T.ink); Spacer(Modifier.width(8.dp))
                Text(if (strokes.isEmpty()) "Usar no chat" else "Usar com as marcas", style = T.sans(16, T.Semi))
            }
        }
    }
}

/** Imagem original com as marcas por cima, à resolução da imagem. */
private fun render(b: android.graphics.Bitmap, strokes: List<List<Offset>>, box: androidx.compose.ui.unit.IntSize): ByteArray? {
    if (box.width == 0) return null
    val out = b.copy(android.graphics.Bitmap.Config.ARGB_8888, true)
    val c = android.graphics.Canvas(out); val k = b.width.toFloat() / box.width
    val p = android.graphics.Paint().apply { color = 0xFFFF3B30.toInt(); style = android.graphics.Paint.Style.STROKE; strokeWidth = 6 * Fala.app.resources.displayMetrics.density * k; strokeCap = android.graphics.Paint.Cap.ROUND; strokeJoin = android.graphics.Paint.Join.ROUND; isAntiAlias = true }
    for (st in strokes) if (st.size > 1) c.drawPath(android.graphics.Path().apply { moveTo(st[0].x * k, st[0].y * k); st.drop(1).forEach { lineTo(it.x * k, it.y * k) } }, p)
    return java.io.ByteArrayOutputStream().also { out.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
}

// MARK: Markdown do agente (negrito, itálico, código, títulos, listas e tabelas)

@Composable
fun RichText(text: String) {
    val blocks = remember(text) { mdBlocks(text) }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        for (b in blocks) when (b) {
            is String -> Text(inline(b), style = T.sans(15))
            is List<*> -> {
                @Suppress("UNCHECKED_CAST") val rows = b as List<List<String>>
                Column(Modifier.horizontalScroll(rememberScrollState()).clip(RoundedCornerShape(10.dp)).border(1.dp, T.ink.copy(.12f), RoundedCornerShape(10.dp))) {
                    rows.forEachIndexed { i, r ->
                        Row(Modifier.background(if (i == 0) T.ink.copy(.06f) else if (i % 2 == 0) T.ink.copy(.025f) else Color.Transparent)) {
                            r.forEach { c -> Text(inline(c), style = T.sans(14, if (i == 0) T.Semi else FontWeight.Normal), modifier = Modifier.width(140.dp).padding(horizontal = 10.dp, vertical = 8.dp)) }
                        }
                        if (i < rows.lastIndex) HorizontalDivider(color = T.ink.copy(.1f), thickness = 0.5.dp)
                    }
                }
            }
        }
    }
}

private fun mdBlocks(text: String): List<Any> {
    val out = mutableListOf<Any>(); val buf = mutableListOf<String>(); val rows = mutableListOf<List<String>>()
    fun flushText() { if (buf.isNotEmpty()) { out.add(buf.joinToString("\n").trim('\n')); buf.clear() } }
    fun flushTable() { if (rows.isNotEmpty()) { out.add(rows.toList()); rows.clear() } }
    var code = false
    for (line in text.split("\n")) {
        val t = line.trim()
        if (t.startsWith("```")) { code = !code; continue }
        if (code) { buf += "`$line`"; continue }
        if (t.length > 1 && t.startsWith("|") && t.endsWith("|")) {
            flushText()
            val cells = t.drop(1).dropLast(1).split("|").map { it.trim() }
            if (!cells.all { c -> c.isNotEmpty() && c.all { it in "-:" } }) rows += cells
        } else {
            flushTable()
            buf += when {
                Regex("^#{1,4} ").containsMatchIn(line) -> "**" + line.replace(Regex("^#{1,4} "), "") + "**"
                Regex("^\\s*[-*] ").containsMatchIn(line) -> "•  " + line.replace(Regex("^\\s*[-*] "), "")
                else -> line
            }
        }
    }
    flushText(); flushTable()
    return out.filter { it !is String || it.isNotEmpty() }
}

private fun inline(s: String): AnnotatedString = buildAnnotatedString {
    var i = 0
    val re = Regex("\\*\\*(.+?)\\*\\*|`([^`]+)`|\\*([^*\\s][^*]*?)\\*|_([^_\\s][^_]*?)_|\\[([^\\]]+)]\\([^)]*\\)")
    for (m in re.findAll(s)) {
        append(s.substring(i, m.range.first))
        val g = m.groupValues
        when {
            g[1].isNotEmpty() -> withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(g[1]) }
            g[2].isNotEmpty() -> withStyle(SpanStyle(fontFamily = T.mono, background = T.ink.copy(.06f))) { append(g[2]) }
            g[3].isNotEmpty() -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(g[3]) }
            g[4].isNotEmpty() -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(g[4]) }
            else -> withStyle(SpanStyle(color = Color(0xFF007AFF))) { append(g[5]) }
        }
        i = m.range.last + 1
    }
    append(s.substring(i))
}

// MARK: "A pensar…" (WorkingRow) e pontinhos

private val GLYPHS = listOf("·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢").map { it + "\uFE0E" }
private val VERBS = listOf("A pensar", "A cozinhar", "A magicar", "A matutar", "A congeminar", "A engendrar", "A tricotar", "A esmiuçar", "A burilar", "A desenrascar", "A remexer", "A afinar")

@Composable
fun WorkingRow() {
    val start = remember { System.currentTimeMillis() }
    val now by produceState(start) { while (true) { delay(120); value = System.currentTimeMillis() } }
    val s = ((now - start) / 1000).toInt()
    Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(GLYPHS[((now / 120) % GLYPHS.size).toInt()], style = T.sans(17, T.Bold, T.orange), modifier = Modifier.width(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(VERBS[(s / 6) % VERBS.size] + "…", style = T.sans(15, T.Medium, T.orange))
        Spacer(Modifier.width(8.dp))
        Text("(" + (if (s < 60) "$s s" else "${s / 60} min ${s % 60} s") + ")", style = T.sans(13, color = T.muted))
    }
}

@Composable
fun WorkingDots(c: Color) {
    val k by produceState(0) { while (true) { delay(180); value = (value + 1) % 4 } }
    Row(Modifier.padding(start = 2.dp, top = 4.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        repeat(3) { i ->
            val y by animateFloatAsState(if (k == i) -3f else 0f, spring(dampingRatio = .6f, stiffness = 900f), label = "dot")
            Box(Modifier.offset(0.dp, y.dp).size(4.dp).alpha(if (k == i) 1f else .45f).clip(CircleShape).background(c))
        }
    }
}

// MARK: Pets (CodePet do iOS, desenhado à mão no Canvas)

val PALETTE = listOf(
    Color(0xFF8CB8FF) to Color(0xFF4D80FF), Color(0xFFFFC78C) to Color(0xFFFF944D), Color(0xFFD1B8FF) to Color(0xFF9E80FA),
    Color(0xFF99EBD1) to Color(0xFF4DC7A8), Color(0xFFFFBFD9) to Color(0xFFFF8CB8), Color(0xFFFFE68C) to Color(0xFFFFC24D),
    Color(0xFFB3E699) to Color(0xFF73C766), Color(0xFF99E0FF) to Color(0xFF59B8F2), Color(0xFFFFAD9E) to Color(0xFFFA736B),
    Color(0xFFD9BFA6) to Color(0xFFB38C6B), Color(0xFFFAFAFA) to Color(0xFFDBE0F0), Color(0xFF80859E) to Color(0xFF4D526B))
private val PET_INK = Color(0xFF292638)
private val PINK = Color(0xFFFFC0CB)
private val ORDER = listOf(8, 0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 11)

/** Pet fixo por sessão: o menos usado na altura em que a sessão aparece, e fica para sempre (o iPhone reciclava com >12 sessões e os pets mudavam de cor). */
private val slots = HashMap<String, Int>()
fun petSlot(id: String): Int = slots.getOrPut(id) {
    val p = Fala.prefs
    val map = runCatching { org.json.JSONObject(p.getString("pet.slots", "{}")!!) }.getOrDefault(org.json.JSONObject())
    if (map.has(id)) return@getOrPut map.getInt(id)
    val used = map.keys().asSequence().map { map.getInt(it) }.groupingBy { it }.eachCount()
    val n = ORDER.minBy { used[it] ?: 0 }
    map.put(id, n); p.edit().putString("pet.slots", map.toString()).apply()
    n
}

@Composable
fun SessionPet(id: String, busy: Boolean, active: Boolean, needsYou: Boolean, modifier: Modifier = Modifier) {
    val pet = Mascots.resolve(id)
    if (pet == null) { CodePet(id, busy, active, needsYou, modifier); return }
    Box(modifier.size(46.dp, 48.dp).alpha(if (active) 1f else .5f)
        .semantics { contentDescription = pet.name + ": " + (if (!active) "A descansar" else if (needsYou) "Precisa de ti" else if (busy) "A trabalhar" else "À espera de ti") }, Alignment.Center) {
        if (needsYou) Canvas(Modifier.fillMaxSize()) { drawCircle(T.orange.copy(alpha = .2f)) }
        MascotPreview(pet.id, if (!active) 0 else if (busy) 2 else 1, active, Modifier.size(44.dp, 48.dp))
        if (needsYou) Text("!", style = T.sans(10, T.Bold, Color.White), modifier = Modifier.align(Alignment.TopEnd).clip(CircleShape).background(T.orange).padding(horizontal = 5.dp))
    }
}

@Composable
private fun CodePet(id: String, busy: Boolean, active: Boolean, needsYou: Boolean, modifier: Modifier = Modifier) {
    val seed = remember(id) { petSlot(id) }
    var t by remember { mutableLongStateOf(0L) }
    LaunchedEffect(active) { if (active) while (true) { withFrameMillis { t = it }; delay(30) } }
    val (top, bottom) = PALETTE[seed % 12]
    val kind = seed % 6
    Canvas(modifier.size(46.dp, 48.dp).alpha(if (active) 1f else .7f)) {
        val u = size.width / 46f // 1 pt do iOS
        val s = t / 1000.0 + seed * 0.37
        val hop = if (busy) max(0.0, sin(s * 8)) else 0.0
        val squash = if (busy) (1 - hop) * 0.16 else sin(s * 1.8) * 0.025
        val sway = if (busy) sin(s * 4) * 7 else sin(s * 1.2) * (if (needsYou) 6 else 3)
        val wave = sin(s * (if (needsYou) 9 else 3))
        val cx = size.width / 2; val cy = size.height / 2
        fun c(col: Color) = if (active) col else desat(col)
        if (needsYou) drawCircle(T.orange.copy(alpha = (0.18 + 0.1 * sin(s * 4)).toFloat()), 23 * u, Offset(cx, cy))
        drawOval(Color.Black.copy(.08f), Offset(cx - (13 - hop * 3).toFloat() * u, cy + 19 * u), Size((26 - hop * 6).toFloat() * u, 4 * u))
        rotate(sway.toFloat(), Offset(cx, cy + 15.5f * u)) {
            translate(0f, (-hop * 8).toFloat() * u) {
                ears(kind, c(top), c(bottom), cx, cy + 3 * u, u)
                val feetY = cy + (31 * (1 - squash) / 2 - 2.5).toFloat() * u
                for (dx in listOf(-10.5f, 10.5f)) drawOval(c(bottom), Offset(cx + dx * u - 5 * u, feetY - 3 * u), Size(10 * u, 6 * u))
                arms(s, c(bottom), wave, busy, active, cx, cy, u)
                val bw = (34 * (1 + squash)).toFloat() * u; val bh = (31 * (1 - squash)).toFloat() * u
                drawOval(Brush.verticalGradient(listOf(c(top), c(bottom)), cy - bh / 2, cy + bh / 2), Offset(cx - bw / 2, cy - bh / 2), Size(bw, bh))
                rotate(-25f, Offset(cx - bw / 2 + 11.5f * u, cy - bh / 2 + 7.5f * u)) { drawOval(Color.White.copy(.55f), Offset(cx - bw / 2 + 7 * u, cy - bh / 2 + 5 * u), Size(9 * u, 5 * u)) }
                face(s, c(top), busy, active, needsYou, cx, cy + 1 * u, u)
            }
        }
        if (active && !busy) {
            val sc = (1 + 0.08 * sin(s * 3)).toFloat()
            val bc = Offset(cx + 17 * u, cy - 19 * u)
            drawCircle(Color.Black.copy(.12f), 7.5f * u * sc, bc + Offset(0f, 1 * u))
            drawCircle(if (needsYou) T.orange else Color.White, 7.5f * u * sc, bc)
            val p = Path()
            if (needsYou) { drawLine(Color.White, bc + Offset(0f, -3.5f * u), bc + Offset(0f, 1 * u), 2f * u, StrokeCap.Round); drawCircle(Color.White, 1.1f * u, bc + Offset(0f, 3.6f * u)) }
            else {
                p.moveTo(bc.x - 2.3f * u, bc.y - 1.6f * u); p.cubicTo(bc.x - 2.3f * u, bc.y - 4.8f * u, bc.x + 2.6f * u, bc.y - 4.8f * u, bc.x + 2.4f * u, bc.y - 1.6f * u)
                p.cubicTo(bc.x + 2.2f * u, bc.y, bc.x, bc.y - 0.3f * u, bc.x, bc.y + 1.4f * u)
                drawPath(p, PET_INK, style = Stroke(1.8f * u, cap = StrokeCap.Round)); drawCircle(PET_INK, 1f * u, bc + Offset(0f, 3.8f * u))
            }
        }
        if (busy) for (i in 0..1) {
            val a = max(0.0, sin(s * 5 + i * 2.5)).toFloat()
            val o = Offset(cx + (if (i == 0) -20 else 20) * u, cy + (-14 + i * 4) * u)
            drawLine(T.orange.copy(alpha = a), o + Offset(0f, -3.5f * u), o + Offset(0f, 3.5f * u), 1.6f * u, StrokeCap.Round)
            drawLine(T.orange.copy(alpha = a), o + Offset(-3.5f * u, 0f), o + Offset(3.5f * u, 0f), 1.6f * u, StrokeCap.Round)
        }
    }
}

private fun desat(c: Color): Color { val g = 0.3f * c.red + 0.59f * c.green + 0.11f * c.blue; val k = 0.4f; return Color(g + (c.red - g) * k, g + (c.green - g) * k, g + (c.blue - g) * k, c.alpha) }

private fun DrawScope.ears(k: Int, top: Color, bottom: Color, cx: Float, cy: Float, u: Float) {
    when (k) {
        1 -> for ((dx, r) in listOf(-11f to -12f, 11f to 12f)) rotate(r, Offset(cx + dx * u, cy - 17.5f * u)) {
            val p = Path().apply { moveTo(cx + dx * u, cy - 23.5f * u); lineTo(cx + (dx + 6) * u, cy - 11.5f * u); lineTo(cx + (dx - 6) * u, cy - 11.5f * u); close() }
            drawPath(p, top); drawPath(p, top, style = Stroke(3 * u, join = androidx.compose.ui.graphics.StrokeJoin.Round))
            val q = Path().apply { moveTo(cx + dx * u, cy - 18.5f * u); lineTo(cx + (dx + 3) * u, cy - 12.5f * u); lineTo(cx + (dx - 3) * u, cy - 12.5f * u); close() }
            drawPath(q, PINK.copy(.6f))
        }
        2 -> { drawLine(bottom, Offset(cx, cy - 23.5f * u), Offset(cx, cy - 14.5f * u), 2.5f * u, StrokeCap.Round); drawCircle(T.orange.copy(.35f), 5 * u, Offset(cx, cy - 25.5f * u)); drawCircle(T.orange, 3 * u, Offset(cx, cy - 25.5f * u)) }
        3 -> for ((dx, r) in listOf(-7.5f to -10f, 7.5f to 10f)) rotate(r, Offset(cx + dx * u, cy - 19 * u)) {
            drawRoundRect(top, Offset(cx + (dx - 4) * u, cy - 27.5f * u), Size(8 * u, 17 * u), androidx.compose.ui.geometry.CornerRadius(4 * u))
            drawRoundRect(PINK.copy(.6f), Offset(cx + (dx - 1.75f) * u, cy - 24.5f * u), Size(3.5f * u, 11 * u), androidx.compose.ui.geometry.CornerRadius(1.75f * u))
        }
        4 -> {
            rotate(-30f, Offset(cx - 3 * u, cy - 17 * u)) { drawOval(Color(0xFF73CC66), Offset(cx - 7 * u, cy - 19.5f * u), Size(8 * u, 5 * u)) }
            rotate(30f, Offset(cx + 3 * u, cy - 17 * u)) { drawOval(Color(0xFF59B859), Offset(cx - 1 * u, cy - 19.5f * u), Size(8 * u, 5 * u)) }
        }
        5 -> for (dx in listOf(-13.5f, 13.5f)) { drawCircle(bottom, 5.5f * u, Offset(cx + dx * u, cy - 13 * u)); drawCircle(top, 2.5f * u, Offset(cx + dx * u, cy - 13 * u)) }
    }
}

private fun DrawScope.arms(s: Double, c: Color, wave: Double, busy: Boolean, active: Boolean, cx: Float, cy: Float, u: Float) {
    if (!active || busy) {
        for ((dx, base, ph) in listOf(Triple(-17.5f, -20.0, 0.0), Triple(17.5f, 20.0, 1.5))) {
            val r = if (busy) (base + (if (dx < 0) 1 else -1) * sin(s * 16 + ph) * 25).toFloat() else 0f
            rotate(r, Offset(cx + dx * u, cy + 5 * u)) { drawOval(c, Offset(cx + (dx - 3.5f) * u, cy + 0.5f * u), Size(7 * u, 9 * u)) }
        }
    } else {
        drawOval(c, Offset(cx - 19.5f * u, cy + 1.5f * u), Size(7 * u, 9 * u))
        rotate((25 + wave * 18).toFloat(), Offset(cx + 16 * u, cy + 0.5f * u)) { drawRoundRect(c, Offset(cx + 12.75f * u, cy - 12.5f * u), Size(6.5f * u, 13 * u), androidx.compose.ui.geometry.CornerRadius(3.25f * u)) }
    }
}

private fun DrawScope.face(s: Double, lid: Color, busy: Boolean, active: Boolean, needsYou: Boolean, cx: Float, cy: Float, u: Float) {
    val blink = (s * 8).toInt() % 29 == 0
    val ey = cy - 3 * u
    for (dx in listOf(-7.5f, 7.5f)) {
        val ex = cx + dx * u
        when {
            !active -> drawArc(PET_INK, 0f, 180f, false, Offset(ex - 3 * u, ey - 3 * u), Size(6 * u, 4 * u), style = Stroke(1.6f * u, cap = StrokeCap.Round))
            blink -> drawLine(PET_INK, Offset(ex - 3 * u, ey), Offset(ex + 3 * u, ey), 1.6f * u, StrokeCap.Round)
            else -> {
                val w = (if (busy) 5f else 6f) * u; val h = (if (busy) 5.5f else 7.5f) * u
                val ox = if (busy) (sin(s * 3.2) * 1.8).toFloat() * u else 0f; val oy = if (busy) 1 * u else 0f
                drawOval(PET_INK, Offset(ex - w / 2 + ox, ey - h / 2 + oy), Size(w, h))
                drawCircle(Color.White, 1.1f * u, Offset(ex + w / 2 - 1.7f * u + ox, ey - h / 2 + 1.9f * u + oy))
                if (!busy && !needsYou) drawRect(lid, Offset(ex - w / 2 - 0.5f * u, ey - h / 2 - 0.3f * u), Size(w + u, 3.4f * u)) // pálpebra a meio: à espera
            }
        }
    }
    val my = cy + 4.5f * u
    for (dx in listOf(-10.5f, 10.5f)) drawOval(PINK.copy(.75f), Offset(cx + dx * u - 3 * u, my - 1.75f * u), Size(6 * u, 3.5f * u))
    when {
        busy -> drawLine(PET_INK, Offset(cx - 1.75f * u, my), Offset(cx + 1.75f * u, my), 1.4f * u, StrokeCap.Round)
        needsYou -> drawOval(PET_INK, Offset(cx - 1.6f * u, my - 1.9f * u), Size(3.2f * u, 3.8f * u))
        else -> drawLine(PET_INK, Offset(cx - 1.45f * u, my), Offset(cx + 3.05f * u, my), 1.4f * u, StrokeCap.Round)
    }
}

