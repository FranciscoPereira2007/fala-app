package com.fran.fala

import android.Manifest
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.sin

/** Onboarding na ordem do iOS (Flow): intro, quiz, resposta, configurar, ligar ao Mac, testar a magia, streak, pronto. */
@Composable
fun Onboarding(done: () -> Unit) {
    var step by remember { mutableStateOf(0) }
    val total = 8
    val picks = remember { mutableStateOf(setOf<Int>()) }
    BackHandler(step > 0) { step-- }
    LaunchedEffect(step) { Haptics.tick() }
    Column(Modifier.fillMaxSize().background(if (step == 0) T.ink else Color.White).statusBarsPadding().safeBottom()) {
        if (step > 0) Row(Modifier.padding(horizontal = 20.dp).padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.size(28.dp, 44.dp).press(0.9f) { step-- }, Alignment.Center) { Ic(Ph.caretLeft, 20.dp) }
            for (i in 1 until total) {
                val f by animateFloatAsState(if (i <= step) 1f else 0f, spring(stiffness = 300f), label = "seg")
                Box(Modifier.weight(1f).height(4.dp).clip(CircleShape).background(Color.Black.copy(.12f))) { Box(Modifier.fillMaxWidth(f).height(4.dp).clip(CircleShape).background(T.primary)) }
            }
            if (step == 5) Text(t("Saltar"), style = T.sans(16, color = T.muted), modifier = Modifier.press { step = 6 })
        }
        AnimatedContent(step, transitionSpec = { (slideInHorizontally(spring(stiffness = 400f)) { it } + fadeIn()) togetherWith fadeOut(tween(150)) }, label = "step") { s ->
            Box(Modifier.fillMaxSize()) {
                when (s) {
                    0 -> Intro { step = 1 }
                    1 -> Quiz(picks.value, { picks.value = if (it in picks.value) picks.value - it else picks.value + it }) { step = 2 }
                    2 -> Personalized(picks.value.minOrNull() ?: 0) { step = 3 }
                    3 -> LetsSetUp { step = 4 }
                    4 -> ConnectMac { step = 5 }
                    5 -> Magic { step = 6 }
                    6 -> Streak { step = 7 }
                    else -> Ready(done)
                }
            }
        }
    }
}

/** O "pill" do Flow: cápsula preta, X, onda branca, check. */
@Composable
fun WavePill(level: Float) {
    val t by androidx.compose.runtime.produceState(0L) { while (true) { delay(16); value = System.currentTimeMillis() } }
    Row(Modifier.height(40.dp).clip(CircleShape).background(T.ink).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Ic(Ph.x, 12.dp, Color.White.copy(.6f))
        Row(horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
            for (i in 0 until 12) {
                val seed = abs(sin(i * 1.7)); val wob = 0.75 + 0.25 * sin(t / 160.0 + i)
                val h by animateDpAsState((5 + level * 22 * seed * wob + 3).dp, spring(stiffness = 600f), label = "bar")
                Box(Modifier.width(3.dp).height(h).clip(CircleShape).background(Color.White))
            }
        }
        Ic(Ph.check, 12.dp, Color.White)
    }
}

private val SLIDES = listOf("A Fala é um teclado que " to "ouve", "4x mais rápido " to "do que escrever", "Fala no telemóvel, " to "escreve no Mac")

@Composable
private fun Intro(next: () -> Unit) {
    var slide by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { while (true) { delay(2400); slide = (slide + 1) % 3 } }
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.padding(top = 26.dp).scale(1.1f)) { FalaLogo(Color.White) }
        Spacer(Modifier.weight(1f))
        Box(contentAlignment = Alignment.Center) {
            val x by animateDpAsState(((slide - 1) * 60).dp, tween(500), label = "glow")
            // ponytail: Modifier.blur só existe no Android 12+; gradiente radial dá o mesmo brilho no Android 10.
            Box(Modifier.offset(x = x).size(420.dp).background(androidx.compose.ui.graphics.Brush.radialGradient(listOf(T.purple.copy(.32f), T.purple.copy(.12f), Color.Transparent))))
            Box(Modifier.scale(1.9f)) { WavePill(listOf(.5f, .9f, .7f)[slide]) }
        }
        Spacer(Modifier.weight(1f))
        AnimatedContent(slide, transitionSpec = { fadeIn(tween(500)) togetherWith fadeOut(tween(500)) }, label = "slide", modifier = Modifier.height(130.dp)) { i ->
            Text(italicTail(SLIDES[i].first, SLIDES[i].second), style = T.serif(38, color = Color.White), textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 30.dp))
        }
        Row(Modifier.padding(vertical = 22.dp), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            repeat(3) { i -> val w by animateDpAsState(if (i == slide) 18.dp else 7.dp, label = "dot"); Box(Modifier.width(w).height(7.dp).clip(CircleShape).background(Color.White.copy(if (i == slide) 1f else .35f))) }
        }
        Box(Modifier.padding(horizontal = 20.dp).padding(bottom = 16.dp).fillMaxWidth().height(54.dp).press(0.97f, onClick = next).clip(RoundedCornerShape(10.dp)).background(T.cream), Alignment.Center) {
            Text(t("Começar"), style = T.sans(17, T.Semi))
        }
    }
}

private val QUIZ = listOf(Ph.paperPlaneRight to "Não consigo acompanhar as mensagens", Ph.fileText to "Escrever emails demora imenso", Ph.sparkle to "Quero falar com IA mais depressa",
    Ph.notePencil to "Perco ideias por não as apontar", Ph.laptop to "O meu Mac aquece e deixa de me ouvir", Ph.keyboard to "Quero escrever mais rápido no computador")

@Composable
private fun Quiz(picks: Set<Int>, toggle: (Int) -> Unit, next: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(t("Com qual destas te identificas?"), style = T.serif(30), textAlign = TextAlign.Center, modifier = Modifier.padding(top = 24.dp))
        Text(t("Escolhe todas as que se aplicam."), style = T.sans(15))
        QUIZ.forEachIndexed { i, (icon, t) ->
            val on = i in picks
            Row(Modifier.fillMaxWidth().press(0.98f) { toggle(i) }.clip(RoundedCornerShape(12.dp)).background(if (on) T.cream else Color.White)
                .border(if (on) 2.dp else 1.dp, if (on) T.ink else Color.Black.copy(.15f), RoundedCornerShape(12.dp)).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                Ic(icon, 20.dp); Spacer(Modifier.width(12.dp)); Text(t, style = T.sans(15))
            }
        }
        Spacer(Modifier.weight(1f))
        DarkButton("Seguinte", picks.isNotEmpty(), onClick = next)
    }
}

@Composable
private fun Personalized(first: Int, next: () -> Unit) {
    val (word, icon, tint) = listOf(Triple("mensagens", Ph.paperPlaneRight, Color(0xFFDB4740)), Triple("emails", Ph.fileText, Color(0xFF2B73D9)),
        Triple("falar com IA", Ph.sparkle, T.purple), Triple("apontar ideias", Ph.notePencil, T.orange), Triple("o teu Mac", Ph.laptop, T.forest),
        Triple("escrever no computador", Ph.keyboard, T.forest))[first.coerceIn(0, 5)]
    val pulse by androidx.compose.animation.core.rememberInfiniteTransition(label = "p").animateFloat(.9f, 1.05f,
        androidx.compose.animation.core.infiniteRepeatable(tween(800), androidx.compose.animation.core.RepeatMode.Reverse), label = "pulse")
    Column(Modifier.fillMaxSize().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(italicTail("Perfeito, a Fala é ótima para ", word), style = T.serif(32), textAlign = TextAlign.Center, modifier = Modifier.padding(top = 24.dp, start = 4.dp, end = 4.dp))
        Spacer(Modifier.weight(1f))
        Box(Modifier.size(290.dp).clip(RoundedCornerShape(14.dp)).background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(tint.copy(.85f), tint)))) {
            Box(Modifier.padding(14.dp).size(64.dp).clip(RoundedCornerShape(15.dp)).background(Color.White.copy(.22f)), Alignment.Center) { Ic(icon as ImageVector, 30.dp, Color.White) }
            Box(Modifier.align(Alignment.Center).scale(1.6f * pulse)) { WavePill(.7f) }
        }
        Spacer(Modifier.weight(1f))
        DarkButton("Seguinte", onClick = next)
    }
}

@Composable
private fun LetsSetUp(next: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.weight(1f))
        Text(androidx.compose.ui.text.buildAnnotatedString {
            append("Vamos "); pushStyle(androidx.compose.ui.text.SpanStyle(color = T.orange)); append("configurar"); pop(); append(" a Fala")
        }, style = T.serif(56), textAlign = TextAlign.Center)
        Spacer(Modifier.height(18.dp))
        Text(t("Só demora um momento"), style = T.sans(17))
        Spacer(Modifier.weight(1f))
        Box(Modifier.fillMaxWidth().height(54.dp).press(0.97f, onClick = next).clip(RoundedCornerShape(12.dp)).background(T.lilac).border(1.5.dp, T.ink, RoundedCornerShape(12.dp)), Alignment.Center) {
            Text(t("Configurar"), style = T.sans(17, T.Semi))
        }
    }
}

/** No Android este passo liga ao Mac (no iPhone era ativar o teclado). */
@Composable
private fun ConnectMac(next: () -> Unit) {
    var code by remember { mutableStateOf(Fala.link.token) }
    var result by remember { mutableStateOf<String?>(null) }
    var testing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Text(t("Liga a Fala ao teu Mac"), style = T.serif(32), textAlign = TextAlign.Center, modifier = Modifier.padding(top = 24.dp))
        Text(t("No Mac abre a Fala, aba iPhone, e copia o código. O texto que ditares aqui cola lá, onde estiver o cursor."), style = T.sans(15, color = T.muted), textAlign = TextAlign.Center)
        FormField(code, "Código do Mac", mono = true, caps = true, bg = T.appBG) { code = it.uppercase() }
        Text(androidx.compose.ui.text.buildAnnotatedString {
            append("Os teus dados estão "); pushStyle(androidx.compose.ui.text.SpanStyle(fontStyle = androidx.compose.ui.text.font.FontStyle.Italic)); append("seguros"); pop()
            append(". Tudo vai cifrado com este código: nem a rede nem o relay leem o que dizes.")
        }, style = T.sans(15, color = Color.White), modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(T.primary).padding(14.dp))
        result?.let { Text(it, style = T.sans(15, T.Medium, if (it.startsWith("Ligado")) T.forest else T.red)) }
        Spacer(Modifier.heightIn(min = 20.dp))
        DarkButton(if (testing) "A ligar…" else "Ligar ao Mac", code.length >= 10 && !testing) {
            scope.launch {
                Fala.setToken(code); testing = true
                val n = Fala.link.ping(10.0); testing = false
                result = if (n != null) "Ligado a $n ✓" else Fala.link.lastError ?: "Sem resposta"
                if (n != null) { delay(700); next() }
            }
        }
        Text(t("Faço depois"), style = T.sans(15, color = T.muted), modifier = Modifier.press(onClick = next).padding(8.dp))
    }
}

@Composable
private fun Magic(next: () -> Unit) {
    val ctx = LocalContext.current
    var phase by remember { mutableStateOf<Phase>(Phase.Idle) }
    var tried by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { if (it && Recorder.start()) phase = Phase.Listening }
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(italicTail("Diz qualquer coisa, toca em ✓ e vê aparecer como magia ✨", ""), style = T.serif(30), textAlign = TextAlign.Center, modifier = Modifier.padding(top = 24.dp, start = 20.dp, end = 20.dp))
        Spacer(Modifier.height(18.dp))
        Text(when { phase == Phase.Listening -> "A ouvir…"; tried.isNotEmpty() -> tried; else -> "Diz alguma coisa!" }, style = T.sans(17, color = if (tried.isEmpty()) T.ink.copy(.35f) else T.ink),
            modifier = Modifier.padding(horizontal = 20.dp).fillMaxWidth().heightIn(min = 130.dp).border(1.dp, T.line, RoundedCornerShape(14.dp)).padding(16.dp))
        AnimatedVisibility(tried.isNotEmpty()) { Box(Modifier.padding(20.dp)) { DarkButton("Seguinte", onClick = next) } }
        Spacer(Modifier.weight(1f))
        FlowRecorderPanel(phase, Recorder.level, 30.dp, micLabel = "Microfone do telemóvel",
            start = { if (Recorder.permitted(ctx)) { if (Recorder.start()) phase = Phase.Listening } else ask.launch(Manifest.permission.RECORD_AUDIO) },
            cancel = { Recorder.stop(); phase = Phase.Idle },
            finish = {
                val secs = Recorder.seconds; val pcm = Recorder.stop(); phase = Phase.Processing
                scope.launch {
                    val t = if (Fala.link.paired) Fala.link.sendAudio(pcm, enter = false, paste = false, timeoutS = 15.0) else null
                    if (!t.isNullOrBlank()) { tried = t; Fala.store.add(t, seconds = secs); phase = Phase.Done("Parabéns 🎉") }
                    else { phase = Phase.Idle; tried = ""; Dictation.toast.value = FlowToast(Fala.link.lastError ?: "Liga primeiro ao Mac", false) }
                }
            })
    }
}

@Composable
private fun Streak(next: () -> Unit) {
    LaunchedEffect(Unit) { Haptics.success() }
    Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(26.dp)) {
        Text(italicTail("Parabéns! Já sentiste a ", "magia da Fala ✨"), style = T.serif(36), modifier = Modifier.padding(top = 40.dp))
        Column(Modifier.fillMaxWidth().border(1.dp, T.line, RoundedCornerShape(18.dp)).padding(22.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(t("1 dia seguido 🔥"), style = T.serif(26))
            Text(t("Usa a Fala nos próximos 5 dias e ela aprende contigo."), style = T.sans(15), textAlign = TextAlign.Center)
            Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                for (d in 1..5) Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(Modifier.size(26.dp).clip(CircleShape).background(if (d == 1) T.orange else T.line), Alignment.Center) { Ic(Ph.check, 13.dp, Color.White) }
                    Spacer(Modifier.height(6.dp)); Text("Dia $d", style = T.sans(11))
                }
            }
        }
        Spacer(Modifier.weight(1f))
        DarkButton("Continuar", onClick = next)
    }
}

@Composable
private fun Ready(done: () -> Unit) {
    LaunchedEffect(Unit) { Haptics.success() }
    Column(Modifier.fillMaxSize().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.weight(1f))
        Text(italicTail("Está ", "pronto!", T.orange), style = T.serif(46))
        Spacer(Modifier.height(20.dp))
        Text(t("Na aba Ditar falas aqui e o texto aparece no Mac. Nas Sessões falas com os teus agentes."), style = T.sans(17, color = T.muted), textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 20.dp))
        Spacer(Modifier.weight(1f))
        DarkButton("Entrar", onClick = done)
    }
}
