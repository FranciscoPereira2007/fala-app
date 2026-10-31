package com.fran.fala

import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs

/**
 * O ecrã do Mac no telemóvel (iOS/RemoteScreen.swift): imagens JPEG que só vêm quando mudam ("h" = resumo).
 * Toque = clique no sítio, toque longo = clique direito, 2 dedos = scroll, beliscar = zoom no telemóvel.
 */
@Composable
fun RemoteScreen(pc: Boolean = false, close: () -> Unit) {
    var img by remember { mutableStateOf<ImageBitmap?>(null) }
    var pcNote by remember { mutableStateOf<String?>(null) }
    var have by remember { mutableStateOf<String?>(null) }
    var fps by remember { mutableFloatStateOf(0f) }
    var keyboard by remember { mutableStateOf(false) }
    var zoom by remember { mutableFloatStateOf(1f) }
    var pan by remember { mutableStateOf(Offset.Zero) }
    var monitors by remember { mutableStateOf<List<Pair<Long, String>>>(emptyList()) }
    var monitor by remember { mutableStateOf(Fala.prefs.getLong("remote.monitor", 0L)) } // 0 = onde está o rato
    var monMenu by remember { mutableStateOf(false) }
    var autoZoom by remember { mutableStateOf(false) }
    var zoomLocked by remember { mutableStateOf(false) }
    var holding by remember { mutableStateOf(false) }
    var zoomOut by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    val scope = rememberCoroutineScope()
    BackHandler { close() }
    // O ecrã do Mac é largo: abre na horizontal para ocupar o ecrã todo; ao sair volta ao vertical.
    val act = androidx.compose.ui.platform.LocalContext.current as android.app.Activity
    androidx.compose.runtime.DisposableEffect(Unit) {
        act.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        onDispose { act.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
    }

    suspend fun refresh(x: Double? = null, y: Double? = null, right: Boolean = false, double: Boolean = false, scroll: Int? = null): Boolean? {
        if (pc) { // PC Windows (pc-node): rato/scroll por /input, imagem por /screen, como no iPhone
            if (x != null && y != null) PCNode.input(org.json.JSONObject().put("ax", x).put("ay", y).put("c", if (right) 3 else 1))
            scroll?.let { PCNode.input(org.json.JSONObject().put("sx", 0).put("sy", it)) }
            val d = PCNode.request("GET", "/screen", timeoutS = 12)?.takeIf { it.first == 200 }?.third ?: run { pcNote = "O PC não respondeu"; return null }
            if (d.isEmpty()) { pcNote = "O PC respondeu sem imagem: o ecrã dele está bloqueado ou desligado?"; return null }
            pcNote = null
            if (MacLink.digest(d) == have) return false
            BitmapFactory.decodeByteArray(d, 0, d.size)?.let { img = it.asImageBitmap(); have = MacLink.digest(d) }
            return true
        }
        val d = Fala.link.screen(1600, x, y, right, double, scroll, have, monitor.takeIf { it != 0L }) ?: return null
        if (d.isEmpty()) return false
        BitmapFactory.decodeByteArray(d, 0, d.size)?.let { img = it.asImageBitmap(); have = MacLink.digest(d) }
        return true
    }
    // Vídeo ao vivo (H.264) na rede local, como no iPhone; sem ele, imagens soltas (fora de casa pelo relay).
    var liveSize by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    var liveOn by remember { mutableStateOf(false) }
    val live = remember { LiveScreen(onSize = { w, h -> liveSize = w to h }, onEnd = { liveOn = false }) }
    androidx.compose.runtime.DisposableEffect(Unit) { onDispose { live.close() } }
    LaunchedEffect(Unit) {
        if (!pc) {
            monitors = Fala.link.monitors()
            // Monitor guardado que já não existe (desligado): volta a seguir o rato.
            if (monitor != 0L && monitors.isNotEmpty() && monitors.none { it.first == monitor }) { monitor = 0L; Fala.prefs.edit().putLong("remote.monitor", 0L).apply() }
        }
    }
    fun pick(id: Long) {
        tick(); monitor = id; have = null; monMenu = false
        Fala.prefs.edit().putLong("remote.monitor", id).apply()
        live.send(org.json.JSONObject().put("mon", id))
    }
    LaunchedEffect(Unit) {
        liveOn = !pc && live.connect(1920)
        if (liveOn && monitor != 0L) live.send(org.json.JSONObject().put("mon", monitor))
        var frames = 0; var t0 = System.currentTimeMillis()
        while (true) {
            if (liveOn) { fps = live.fps; delay(500); continue }
            val r = refresh()
            if (r != null) frames++
            if (r != true) delay(60)
            val dt = (System.currentTimeMillis() - t0) / 1000f
            if (dt >= 1) { fps = frames / dt; frames = 0; t0 = System.currentTimeMillis() }
        }
    }

    Dialog(close, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            BoxWithConstraints(Modifier.fillMaxSize()) {
                val i = img
                if (liveOn) {
                    val bw = constraints.maxWidth.toFloat(); val bh = constraints.maxHeight.toFloat()
                    val (vw, vh) = liveSize ?: (16 to 10)
                    val k = minOf(bw / vw, bh / vh); val fw = vw * k; val fh = vh * k // o ecrã todo à vista, sem cortar (pedido do Fran); zoom para aproximar
                    val dens = androidx.compose.ui.platform.LocalDensity.current
                    androidx.compose.ui.viewinterop.AndroidView({ c -> android.view.TextureView(c).apply {
                        surfaceTextureListener = object : android.view.TextureView.SurfaceTextureListener {
                            override fun onSurfaceTextureAvailable(t: android.graphics.SurfaceTexture, w: Int, h: Int) = live.attach(android.view.Surface(t))
                            override fun onSurfaceTextureSizeChanged(t: android.graphics.SurfaceTexture, w: Int, h: Int) {}
                            override fun onSurfaceTextureDestroyed(t: android.graphics.SurfaceTexture): Boolean { live.attach(null); return true }
                            override fun onSurfaceTextureUpdated(t: android.graphics.SurfaceTexture) {}
                        }
                    } }, Modifier.align(Alignment.Center).requiredSize(with(dens) { fw.toDp() }, with(dens) { fh.toDp() })
                        .graphicsLayer { scaleX = zoom; scaleY = zoom; translationX = pan.x; translationY = pan.y })
                    fun toMac(p: Offset): Pair<Double, Double>? {
                        val c = Offset(bw / 2, bh / 2)
                        val q = Offset(c.x + (p.x - c.x - pan.x) / zoom, c.y + (p.y - c.y - pan.y) / zoom)
                        val x = (q.x - (bw - fw) / 2) / fw; val y = (q.y - (bh - fh) / 2) / fh
                        return if (x in 0f..1f && y in 0f..1f) x.toDouble() to y.toDouble() else null
                    }
                    // Lupa como no iPhone: ao tocar aproxima 1,5x e segue o dedo; ao largar fica 3 s ("Fixar zoom" para ficar).
                    fun follow(p: Offset) = Offset(((bw / 2 - p.x) * (zoom - 1)).coerceIn(-(bw * (zoom - 1) / 2), bw * (zoom - 1) / 2),
                        ((bh / 2 - p.y) * (zoom - 1)).coerceIn(-(bh * (zoom - 1) / 2), bh * (zoom - 1) / 2))
                    // Toque = clique, longo = clique direito, 2 dedos = scroll, beliscar = zoom (ctrl na mesma ligação).
                    Box(Modifier.fillMaxSize().pointerInput(liveSize) {
                        awaitEachGesture {
                            val down = awaitFirstDown(); val t0 = System.currentTimeMillis(); var moved = 0f; var multi = false; var acc = 0f
                            zoomOut?.cancel()
                            val magnify = !zoomLocked && (zoom == 1f || autoZoom)
                            if (magnify) { autoZoom = true; holding = false; zoom = 1.5f; pan = follow(down.position) }
                            var last = down.position
                            while (true) {
                                val e = awaitPointerEvent(); val n = e.changes.count { it.pressed }
                                if (n == 0) break
                                if (n >= 2) {
                                    multi = true
                                    val z = e.calculateZoom()
                                    if (abs(z - 1) > 0.01f) { autoZoom = false; zoom = (zoom * z).coerceIn(1f, 5f); if (zoom == 1f) pan = Offset.Zero }
                                    else { acc += e.calculatePan().y; if (abs(acc) > 12) { live.send(org.json.JSONObject().put("sx", 0).put("sy", (acc / 12).toInt())); acc = 0f } }
                                    e.changes.forEach { it.consume() }
                                } else {
                                    val d = e.calculatePan(); moved += d.getDistance(); last = e.changes.first().position
                                    if (autoZoom && !zoomLocked) pan = follow(last)
                                    else if (zoom > 1f && moved > 12) pan += d
                                }
                            }
                            if (!multi && (moved < 12 || autoZoom)) toMac(if (autoZoom) last else down.position)?.let { (x, y) ->
                                val long = System.currentTimeMillis() - t0 > 450
                                if (long) Haptics.medium() else tick()
                                live.send(org.json.JSONObject().put("ax", x).put("ay", y).put("c", if (long) 3 else 1))
                            }
                            if (autoZoom && !zoomLocked) { holding = true; zoomOut = scope.launch { delay(3000); if (!zoomLocked) { autoZoom = false; holding = false; zoom = 1f; pan = Offset.Zero } } }
                        }
                    })
                } else if (i == null) Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(Modifier.size(26.dp), Color.White, strokeWidth = 2.dp)
                    Spacer(Modifier.height(12.dp))
                    Text(pcNote ?: Fala.link.lastError?.takeIf { Fala.link.route == null && !pc } ?: if (pc) "A ligar ao ecrã do PC…" else "A ligar ao ecrã do Mac…", style = T.sans(16, color = Color.White.copy(.8f)))
                } else {
                    val bw = constraints.maxWidth.toFloat(); val bh = constraints.maxHeight.toFloat()
                    val k = minOf(bw / i.width, bh / i.height)
                    val fw = i.width * k; val fh = i.height * k
                    /** Ponto no ecrã -> 0..1 no Mac, desfazendo zoom e deslocamento. */
                    fun toMac(p: Offset): Pair<Double, Double>? {
                        val c = Offset(bw / 2, bh / 2)
                        val q = Offset(c.x + (p.x - c.x - pan.x) / zoom, c.y + (p.y - c.y - pan.y) / zoom)
                        val x = (q.x - (bw - fw) / 2) / fw; val y = (q.y - (bh - fh) / 2) / fh
                        return if (x in 0f..1f && y in 0f..1f) x.toDouble() to y.toDouble() else null
                    }
                    Image(i, null, Modifier.fillMaxSize().graphicsLayer { scaleX = zoom; scaleY = zoom; translationX = pan.x; translationY = pan.y }, contentScale = ContentScale.Fit)
                    Box(Modifier.fillMaxSize().pointerInput(Unit) {
                        awaitEachGesture {
                            val down = awaitFirstDown()
                            val t0 = System.currentTimeMillis()
                            var moved = 0f; var multi = false; var scrollAcc = 0f
                            while (true) {
                                val e = awaitPointerEvent()
                                val pressed = e.changes.count { it.pressed }
                                if (pressed == 0) break
                                if (pressed >= 2) {
                                    multi = true
                                    val z = e.calculateZoom()
                                    if (abs(z - 1) > 0.01f) { zoom = (zoom * z).coerceIn(1f, 5f); if (zoom == 1f) pan = Offset.Zero }
                                    else {
                                        val dy = e.calculatePan().y
                                        if (zoom > 1f) pan += e.calculatePan()
                                        else { scrollAcc += dy; if (abs(scrollAcc) > 24) { val n = (scrollAcc / 24).toInt(); scrollAcc -= n * 24; scope.launch { refresh(scroll = n) } } }
                                    }
                                    e.changes.forEach { it.consume() }
                                } else {
                                    val d = e.calculatePan(); moved += d.getDistance()
                                    if (zoom > 1f && moved > 12) { pan += d; e.changes.forEach { it.consume() } }
                                }
                            }
                            if (!multi && moved < 12) {
                                val long = System.currentTimeMillis() - t0 > 450
                                toMac(down.position)?.let { (x, y) -> if (long) Haptics.medium() else tick(); scope.launch { refresh(x, y, right = long) } }
                            }
                        }
                    })
                }
            }
            Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.Top) {
                CircleIcon(Ph.x, Color.White.copy(.18f), Color.White, 44.dp, 20.dp) { close() }
                Spacer(Modifier.weight(1f))
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    if (monitors.size > 1) Box {
                        Row(Modifier.height(36.dp).clip(CircleShape).background(Color.White.copy(.18f)).press { monMenu = true }.padding(horizontal = 14.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Ic(Ph.monitor, 16.dp, Color.White)
                            Text(if (monitor == 0L) "Onde está o rato" else monitors.firstOrNull { it.first == monitor }?.second ?: "Ecrã", style = T.sans(14, color = Color.White))
                            Ic(Ph.caretRight, 10.dp, Color.White, Modifier.graphicsLayer { rotationZ = 90f })
                        }
                        IOSMenu(monMenu, { monMenu = false }, listOf(MenuAction("Onde está o rato" + if (monitor == 0L) " ✓" else "", Ph.cursorClick) { pick(0L) }) +
                            monitors.map { (id, n) -> MenuAction(n + if (id == monitor) " ✓" else "", Ph.monitor) { pick(id) } })
                    }
                    if (holding && !zoomLocked) Text(t("Fixar zoom"), style = T.sans(14, T.Semi, Color.Black), modifier = Modifier.clip(CircleShape).background(Color.White)
                        .press(haptic = Haptics::medium) { zoomOut?.cancel(); zoomLocked = true; autoZoom = false; holding = false }.padding(horizontal = 14.dp, vertical = 7.dp))
                    else if (zoom > 1f) Text(if (zoomLocked) "Zoom fixo %.1fx · soltar".format(zoom) else "%.1fx · repor".format(zoom), style = T.sans(13, color = Color.Black), modifier = Modifier.clip(CircleShape).background(Color.White)
                        .press { zoomLocked = false; autoZoom = false; holding = false; zoom = 1f; pan = Offset.Zero }.padding(horizontal = 12.dp, vertical = 6.dp))
                    Text((if (liveOn) (if (live.relayed) "%.0f img/s · ao vivo pela internet" else "%.0f img/s · ao vivo") else "%.1f img/s").format(fps), style = T.sans(12, color = Color.White.copy(.6f)), modifier = Modifier.padding(top = 4.dp))
                }
                Spacer(Modifier.weight(1f))
                CircleIcon(Ph.keyboard, Color.White.copy(.18f), Color.White, 44.dp, 20.dp) { keyboard = !keyboard }
            }
            if (keyboard) RemoteKeyboard(Modifier.align(Alignment.BottomCenter), pc) { keyboard = false }
        }
    }
}

/** Teclado remoto: escreve no Mac como se estivesses ao teclado dele (texto e teclas especiais). */
@Composable
fun RemoteKeyboard(modifier: Modifier, pc: Boolean = false, close: () -> Unit) {
    var text by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    fun key(k: String, mods: List<String> = emptyList()) = scope.launch { tick(); keyTo(pc, key = k, mods = mods) }
    Column(modifier.fillMaxWidth().clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp)).background(T.appBG).safeBottom().imePadding().padding(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f).height(44.dp).card(12.dp).padding(horizontal = 12.dp), Alignment.CenterStart) {
                if (text.isEmpty()) Text(t("Escreve aqui, vai para o Mac"), style = T.sans(16, color = T.ink.copy(.3f)))
                BasicTextField(text, { text = it }, singleLine = true, textStyle = T.sans(16), cursorBrush = SolidColor(T.ink), modifier = Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send), keyboardActions = KeyboardActions(onSend = {
                        val t = text; text = ""; scope.launch { keyTo(pc, text = t); keyTo(pc, key = "return") }
                    }))
            }
            Spacer(Modifier.width(8.dp))
            CircleIcon(Ph.arrowUp, T.ink, Color.White, 44.dp) { val t = text; text = ""; scope.launch { if (t.isNotEmpty()) keyTo(pc, text = t) } }
        }
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(6.dp)) {
            Pill("esc", Color.White) { key("escape") }
            Pill("tab", Color.White) { key("tab") }
            Pill("⌫", Color.White) { key("delete") }
            Pill("↵", Color.White) { key("return") }
            Pill("⌘C", Color.White) { key("c", listOf("cmd")) }
            Pill("⌘V", Color.White) { key("v", listOf("cmd")) }
            Pill("✕", Color.White) { close() }
        }
    }
}


/** Teclas/texto para o Mac (protocolo K) ou para o PC (/input), o mesmo JSON. */
private suspend fun keyTo(pc: Boolean, text: String? = null, key: String? = null, mods: List<String> = emptyList()): Boolean {
    if (!pc) return Fala.link.key(text, key, mods)
    val j = org.json.JSONObject(); text?.let { j.put("t", it) }; key?.let { j.put("k", it).put("m", org.json.JSONArray(mods)) }
    return PCNode.input(j)
}
