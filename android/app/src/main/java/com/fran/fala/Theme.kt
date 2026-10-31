package com.fran.fala

import android.content.Context
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/** Paleta e componentes do iOS (Shared/Theme.swift + iOS/FlowUI.swift), valor a valor. */
object T {
    val cream = Color(0xFFFFFFED)
    val ink = Color(0xFF1A1A1A)
    val forest = Color(0xFF0B4D3E)
    val lilac = Color(0xFFEFD7FF)
    val muted = Color(0xFF6B6B61)
    val appBG = Color(0xFFF4F2F5)
    val primary = Color(0xFF302D36)
    val orange = Color(0xFFFEA946)
    val purple = Color(0xFFA992FF)
    val line = Color.Black.copy(alpha = 0.08f)
    val keyboardBG = Color(0xFFE3E6EF)
    val tabPill = Color(0xFFF6F6F8)
    val tabActive = Color(0xFFE3E3E5)
    val tabPurple = Color(0xFF5A3D8D)
    val green = Color(0xFF4FBF77)
    val greenSoft = Color(0xFFCBEAD8)
    val headerBG = Color(0xFFF4F2F5)
    val disabled = Color(0xFFADABAF)
    val red = Color(0xFFED4D4D)

    @OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
    private fun fig(w: Int) = Font(R.font.figtree, FontWeight(w), variationSettings = FontVariation.Settings(FontVariation.weight(w)))
    /** Figtree (OFL, fonte variável), como no iOS. */
    val figtree = FontFamily((300..900 step 100).map { fig(it) })
    val garamond = FontFamily(Font(R.font.garamond, FontWeight.Normal), Font(R.font.garamond_italic, FontWeight.Normal, FontStyle.Italic))

    fun sans(size: Int, weight: FontWeight = FontWeight.Normal, color: Color = ink) =
        TextStyle(fontFamily = figtree, fontSize = size.sp, fontWeight = weight, color = color, lineHeight = (size * 1.22).sp)
    fun serif(size: Int, italic: Boolean = false, color: Color = ink) =
        TextStyle(fontFamily = garamond, fontSize = size.sp, fontStyle = if (italic) FontStyle.Italic else FontStyle.Normal, color = color, lineHeight = (size * 1.12).sp)
    val mono = FontFamily.Monospace

    val Medium = FontWeight.Medium
    val Semi = FontWeight.SemiBold
    val Bold = FontWeight.Bold
}

// MARK: Hápticos (o vibrador do Poco imita os UIImpactFeedbackGenerator)

object Haptics {
    lateinit var vib: Vibrator
    fun init(c: Context) { vib = c.getSystemService(Vibrator::class.java) }
    private fun fx(e: VibrationEffect) = runCatching { vib.vibrate(e) }
    fun tick() = fx(VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK))
    fun medium() = fx(VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK))
    fun heavy() = fx(VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK))
    fun success() = fx(VibrationEffect.createWaveform(longArrayOf(0, 18, 70, 28), intArrayOf(0, 120, 0, 200), -1))
    fun warning() = fx(VibrationEffect.createWaveform(longArrayOf(0, 28, 90, 18), intArrayOf(0, 200, 0, 120), -1))
    fun error() = fx(VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK))
}

fun tick() = Haptics.tick()

/**
 * Margem de baixo como a do iPhone (barra do gesto). O MIUI com gestos diz que a barra de navegação tem 0 px,
 * e as abas, a caixa de texto e o painel encostavam ao fundo, cortados pelos cantos redondos do ecrã.
 */
@Composable
fun bottomSafe(): Dp = maxOf(with(androidx.compose.ui.platform.LocalDensity.current) { WindowInsets.navigationBars.getBottom(this).toDp() }, 20.dp)
fun Modifier.safeBottom(extra: Dp = 0.dp) = composed { padding(bottom = bottomSafe() + extra) }

/** O "press" do iOS: encolhe com mola ao carregar. */
@Composable
fun Modifier.press(scale: Float = 0.96f, enabled: Boolean = true, haptic: () -> Unit = ::tick, onClick: () -> Unit): Modifier {
    val src = remember { MutableInteractionSource() }
    val pressed by src.collectIsPressedAsState()
    val s by animateFloatAsState(if (pressed) scale else 1f, spring(dampingRatio = 0.6f, stiffness = 900f), label = "press")
    return this.scale(s).clickable(src, null, enabled = enabled) { haptic(); onClick() }
}

@Composable
fun Ic(v: ImageVector, size: Dp = 20.dp, color: Color = T.ink, modifier: Modifier = Modifier) =
    Icon(v, null, modifier.size(size), tint = color)

/** Cartão branco 20 pt, o "bloco" de todas as listas do iOS. */
fun Modifier.card(radius: Dp = 20.dp, color: Color = Color.White) = this.clip(RoundedCornerShape(radius)).background(color)

// MARK: Cabeçalho (☰ | título | ação) com linha fina

@Composable
fun FlowHeader(menuIcon: ImageVector? = Ph.list, onMenu: (() -> Unit)? = null, trailing: @Composable RowScope.() -> Unit = {}, center: @Composable BoxScope.() -> Unit) {
    Box(Modifier.fillMaxWidth().height(56.dp).background(T.headerBG).padding(horizontal = 10.dp)) {
        Box(Modifier.align(Alignment.Center), content = center)
        Row(Modifier.fillMaxWidth().align(Alignment.Center), verticalAlignment = Alignment.CenterVertically) {
            if (onMenu != null && menuIcon != null) Box(Modifier.size(44.dp).press(0.9f, onClick = onMenu), Alignment.Center) { Ic(menuIcon, 22.dp) }
            else Spacer(Modifier.size(44.dp))
            Spacer(Modifier.weight(1f))
            trailing()
        }
        Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(0.5.dp).background(Color.Black.copy(alpha = 0.12f)))
    }
}

@Composable
fun FalaLogo(color: Color = T.ink) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Row(horizontalArrangement = Arrangement.spacedBy(2.5.dp), verticalAlignment = Alignment.CenterVertically) {
            listOf(10, 16, 12, 18, 9).forEach { h -> Box(Modifier.width(2.6.dp).height(h.dp).clip(CircleShape).background(color)) }
        }
        Spacer(Modifier.width(6.dp))
        Text(t("Fala"), style = T.sans(22, T.Bold, color).copy(letterSpacing = (-0.4).sp))
    }
}

// MARK: Toast "Flow is on": pill escura, entra do topo com mola, ~1,7 s

data class FlowToast(val text: String, val ok: Boolean = true, val id: Long = System.nanoTime())

@Composable
fun BoxScope.ToastHost(state: MutableState<FlowToast?>, top: Dp = 66.dp) {
    val t = state.value
    LaunchedEffect(t?.id) {
        if (t == null) return@LaunchedEffect
        if (t.ok) Haptics.success() else Haptics.warning()
        delay(1700); if (state.value?.id == t.id) state.value = null
    }
    AnimatedVisibility(t != null, Modifier.align(Alignment.TopCenter).padding(top = top),
        enter = slideInVertically(spring(dampingRatio = 0.62f, stiffness = 380f)) { -it * 2 } + fadeIn(tween(200)),
        exit = slideOutVertically(tween(300)) { -it } + fadeOut(tween(300))) {
        val last = remember { mutableLastToast() }
        if (t != null) last.value = t
        val s = last.value ?: return@AnimatedVisibility
        Row(Modifier.shadow(10.dp, CircleShape, ambientColor = Color.Black.copy(.12f), spotColor = Color.Black.copy(.12f)).height(48.dp)
            .clip(CircleShape).background(T.primary).padding(start = 14.dp, end = 18.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(24.dp).clip(CircleShape).background(if (s.ok) T.green else T.red), Alignment.Center) {
                if (s.ok) Ic(Ph.check, 13.dp, Color.White) else Box(Modifier.width(10.dp).height(2.5.dp).background(Color.White))
            }
            Spacer(Modifier.width(10.dp))
            Text(s.text, style = T.sans(17, T.Medium, Color.White), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}
private fun mutableLastToast() = androidx.compose.runtime.mutableStateOf<FlowToast?>(null)

// MARK: Banner creme com X

@Composable
fun FlowBanner(title: androidx.compose.ui.text.AnnotatedString, body: androidx.compose.ui.text.AnnotatedString, cta: String, capsule: Boolean = false, onCta: () -> Unit, onClose: () -> Unit) {
    Box(Modifier.fillMaxWidth().card(20.dp, T.cream)) {
        Column(Modifier.fillMaxWidth().padding(18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.height(14.dp))
            Text(title, style = T.serif(29), textAlign = TextAlign.Center)
            Spacer(Modifier.height(12.dp))
            Text(body, style = T.sans(15, color = T.ink.copy(alpha = .75f)), textAlign = TextAlign.Center)
            Spacer(Modifier.height(if (capsule) 14.dp else 16.dp))
            if (capsule) Box(Modifier.height(44.dp).press { onCta() }.clip(CircleShape).background(T.primary).padding(horizontal = 40.dp), Alignment.Center) {
                Text(cta, style = T.sans(16, T.Medium, Color.White))
            } else DarkButton(cta, onClick = onCta)
        }
        Box(Modifier.align(Alignment.TopEnd).size(40.dp).press(0.9f, onClick = onClose), Alignment.Center) { Ic(Ph.x, 15.dp, T.ink.copy(alpha = .6f)) }
    }
}

fun italicTail(head: String, tail: String, tailColor: Color? = null) = buildAnnotatedString {
    append(head)
    withStyle(SpanStyle(fontStyle = FontStyle.Italic, color = tailColor ?: Color.Unspecified)) { append(tail) }
}

@Composable
fun DarkButton(text: String, enabled: Boolean = true, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(modifier.fillMaxWidth().height(54.dp).press(0.98f, enabled) { onClick() }.clip(RoundedCornerShape(12.dp))
        .background(if (enabled) T.primary else Color.Gray.copy(alpha = .45f)), Alignment.Center) {
        Text(text, style = T.sans(17, T.Medium, Color.White))
    }
}

@Composable
fun FlowFAB(modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(modifier.size(58.dp).press(0.92f, onClick = onClick).shadow(8.dp, CircleShape, spotColor = Color.Black.copy(.18f)).clip(CircleShape).background(T.primary), Alignment.Center) {
        Ic(Ph.plus, 26.dp, Color.White)
    }
}

@Composable
fun Pill(text: String, bg: Color = T.appBG, color: Color = T.ink, onClick: () -> Unit) {
    Box(Modifier.height(36.dp).press(0.95f, onClick = onClick).clip(CircleShape).background(bg).padding(horizontal = 12.dp), Alignment.Center) {
        Text(text, style = T.sans(14, T.Medium, color), maxLines = 1)
    }
}

@Composable
fun CircleIcon(v: ImageVector, bg: Color, tint: Color, size: Dp = 36.dp, icon: Dp = 19.dp, enabled: Boolean = true, haptic: () -> Unit = ::tick, onClick: () -> Unit) {
    Box(Modifier.size(size).press(0.9f, enabled, haptic, onClick).clip(CircleShape).background(bg), Alignment.Center) { Ic(v, icon, tint) }
}

// MARK: Onda do teclado Flow (FlowWaveform.swift): 10 barras de 5, espaço 8, 5 a 57

enum class WaveMode { Idle, Listening, Processing }

@Composable
fun FlowWaveform(level: Float, mode: WaveMode, tint: Color = T.ink, height: Dp = 60.dp, modifier: Modifier = Modifier) {
    var t by remember { mutableLongStateOf(0L) }
    var smooth by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(mode) {
        if (mode != WaveMode.Listening) smooth = 0f
        if (mode == WaveMode.Idle) return@LaunchedEffect
        while (true) withFrameMillis { t = it }
    }
    LaunchedEffect(level) { smooth = if (level > smooth) smooth * 0.4f + level * 0.6f else smooth * 0.82f + level * 0.18f }
    val fill = if (mode == WaveMode.Processing) tint.copy(alpha = .35f) else tint
    Canvas(modifier.width((10 * 5 + 9 * 8).dp).height(height)) {
        val s = t / 1000.0
        val w = 5.dp.toPx(); val gap = 8.dp.toPx()
        for (i in 0 until 10) {
            val h = when (mode) {
                WaveMode.Idle -> 5.0
                WaveMode.Processing -> 5 + 8 * ((sin(s * 2 * PI / 0.9 + i * 0.7) + 1) / 2).pow(3)
                WaveMode.Listening -> {
                    val taper = 0.35 + 0.65 * sin(PI * (i + 0.5) / 10)
                    val travel = 0.55 + 0.45 * sin(s * 2 * PI / 0.65 + i * 0.6)
                    val amp = max(0.05, min(1.0, sqrt(smooth.toDouble())))
                    5 + 52 * amp * taper * travel
                }
            }.dp.toPx()
            drawRoundRect(fill, Offset(i * (w + gap), (size.height - h) / 2), Size(w, h), CornerRadius(w / 2))
        }
    }
}

// MARK: Painel de gravação (FlowRecorderPanel)

sealed interface Phase { data object Idle : Phase; data object Listening : Phase; data object Paused : Phase; data object Processing : Phase; data class Done(val text: String) : Phase }

@Composable
fun FlowRecorderPanel(phase: Phase, level: Float, bottomInset: Dp, idleHint: String = "Toca no microfone para começar", micLabel: String,
                      start: () -> Unit, cancel: () -> Unit, finish: () -> Unit, pause: (() -> Unit)? = null) {
    val listening = phase == Phase.Listening || phase == Phase.Paused
    val busy = listening || phase == Phase.Processing
    LaunchedEffect(phase == Phase.Listening) { if (phase == Phase.Listening) Haptics.tick() }
    LaunchedEffect(phase is Phase.Done) { if (phase is Phase.Done) Haptics.success() }
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp)).background(T.keyboardBG).padding(bottom = bottomInset).height(250.dp)) {
        Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            AnimatedVisibility(busy, enter = scaleIn(initialScale = .6f) + fadeIn(), exit = scaleOut(targetScale = .6f) + fadeOut()) {
                CircleIcon(Ph.x, Color.White, T.ink, 45.dp, 18.dp) { cancel() }
            }
            if (!busy) Spacer(Modifier.size(45.dp))
            Spacer(Modifier.weight(1f).width(8.dp))
            Text(when (phase) {
                Phase.Idle -> "$idleHint →"
                Phase.Listening -> "Toca no ✓ para terminar →"
                Phase.Paused -> "Em pausa · toca para continuar"
                Phase.Processing -> " "
                is Phase.Done -> phase.text
            }, style = T.sans(16, color = T.ink.copy(alpha = .85f)), maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.then(if (phase == Phase.Paused && pause != null) Modifier.clickable { tick(); pause() } else Modifier))
            Spacer(Modifier.weight(1f).width(8.dp))
            Box(Modifier.size(45.dp).press(0.9f, phase != Phase.Processing) { if (listening) finish() else start() }
                .clip(CircleShape).background(if (phase == Phase.Processing) Color.White.copy(alpha = .6f) else T.ink), Alignment.Center) {
                when {
                    phase == Phase.Processing -> CircularProgressIndicator(Modifier.size(20.dp), T.ink, strokeWidth = 2.dp)
                    listening -> Ic(Ph.check, 20.dp, Color.White)
                    else -> Ic(Ph.microphoneFill, 21.dp, Color.White)
                }
            }
        }
        Spacer(Modifier.weight(1f))
        val mode = when (phase) { Phase.Listening -> WaveMode.Listening; Phase.Processing -> WaveMode.Processing; else -> WaveMode.Idle }
        FlowWaveform(level, mode, modifier = Modifier.align(Alignment.CenterHorizontally).alpha(if (phase == Phase.Idle || phase is Phase.Done || phase == Phase.Paused) .35f else 1f))
        Column(Modifier.fillMaxWidth().padding(top = 10.dp).height(54.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(when (phase) { Phase.Processing -> "A processar"; Phase.Listening -> "A ouvir"; Phase.Paused -> "Em pausa"; else -> "Pronta" },
                style = T.sans(15, T.Semi, if (phase == Phase.Processing) T.ink.copy(alpha = .4f) else T.ink))
            if (listening) Text(micLabel, style = T.sans(15, T.Semi))
        }
        Spacer(Modifier.weight(1f))
    }
}

/** Forma só com os cantos de cima redondos (painéis que sobem do fundo). */
val TopRounded: Shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp)

