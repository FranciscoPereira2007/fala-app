package com.fran.fala

import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Teclado da Fala (como o do iPhone/Wispr): o mic grava sem sair da app onde estás; o Whisper do Mac transcreve
 * (modo "a", não cola no Mac) e o texto entra aqui onde está o cursor, com o dicionário e os snippets do telemóvel.
 */
class FalaKeyboard : InputMethodService(), LifecycleOwner, SavedStateRegistryOwner {
    private val reg = LifecycleRegistry(this)
    private val saved = SavedStateRegistryController.create(this)
    override val lifecycle: Lifecycle get() = reg
    override val savedStateRegistry: SavedStateRegistry get() = saved.savedStateRegistry

    private var phase by mutableStateOf<Phase>(Phase.Idle)
    private var preview by mutableStateOf("")
    private var job: Job? = null

    override fun onCreate() { super.onCreate(); saved.performRestore(null); reg.currentState = Lifecycle.State.CREATED }
    override fun onDestroy() { reg.currentState = Lifecycle.State.DESTROYED; if (Recorder.recording) Recorder.stop(); super.onDestroy() }
    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) { reg.currentState = Lifecycle.State.RESUMED }
    override fun onFinishInputView(finishingInput: Boolean) { cancel(); reg.currentState = Lifecycle.State.STARTED }

    override fun onCreateInputView(): View {
        window.window?.decorView?.let { it.setViewTreeLifecycleOwner(this); it.setViewTreeSavedStateRegistryOwner(this) }
        return ComposeView(this).apply {
            setViewTreeLifecycleOwner(this@FalaKeyboard); setViewTreeSavedStateRegistryOwner(this@FalaKeyboard)
            setContent { Keyboard() }
        }
    }

    private fun start() {
        if (!Recorder.permitted(this)) { preview = "Abre a Fala uma vez e autoriza o microfone."; return }
        if (!Recorder.start()) return
        phase = Phase.Listening; preview = ""
        job = Fala.scope.launch { // pré-visualização ao vivo pelo Whisper do Mac
            var sent = 0
            while (Recorder.recording) {
                delay(900)
                val a = Recorder.snapshot()
                if (a.size - sent < 9600) continue
                sent = a.size
                Fala.link.sendAudio(a.copyOfRange(maxOf(0, a.size - 10 * 32000), a.size), enter = false, paste = false, timeoutS = 8.0)?.let { if (Recorder.recording) preview = it }
            }
        }
    }
    private fun cancel() { job?.cancel(); if (Recorder.recording) Recorder.stop(); phase = Phase.Idle; preview = "" }
    private fun finish() {
        job?.cancel()
        val pcm = Recorder.stop()
        phase = Phase.Processing
        Fala.scope.launch {
            val t = if (pcm.size > 8000) Fala.link.sendAudio(pcm, enter = false, paste = false, timeoutS = 12.0)?.let(Fala.store::apply)?.trim() else null
            if (!t.isNullOrEmpty()) {
                val before = currentInputConnection?.getTextBeforeCursor(1, 0)?.toString().orEmpty()
                currentInputConnection?.commitText((if (before.isNotEmpty() && !before.last().isWhitespace()) " " else "") + t, 1)
                Fala.store.add(t, seconds = pcm.size / 32000.0)
                phase = Phase.Done("Escrito ✓")
            } else phase = Phase.Done(Fala.link.lastError ?: "Não ouvi nada")
            preview = ""
            delay(1500); if (phase is Phase.Done) phase = Phase.Idle
        }
    }

    @androidx.compose.runtime.Composable
    private fun Keyboard() {
        Column(Modifier.fillMaxWidth().background(T.keyboardBG)) {
            FlowRecorderPanel(phase, Recorder.level, bottomInset = 0.dp, idleHint = "Toca no microfone e fala", micLabel = "Para o Mac transcrever",
                start = ::start, cancel = ::cancel, finish = ::finish)
            // Altura fixa: o texto ao vivo não empurra o ✓ (tocava-se no sítio errado).
            Text(preview, style = T.sans(14, color = T.ink.copy(.7f)), maxLines = 2, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth().height(40.dp).padding(horizontal = 16.dp))
            Row(Modifier.fillMaxWidth().safeBottom(6.dp).padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Key("🌐", 46) { switchToPreviousInputMethod() }
                Key("espaço", 0, Modifier.weight(1f)) { currentInputConnection?.commitText(" ", 1) }
                Key("⌫", 56) { currentInputConnection?.deleteSurroundingText(1, 0) }
                Key("↵", 56, dark = true) {
                    val ic = currentInputConnection
                    val action = currentInputEditorInfo?.imeOptions?.and(EditorInfo.IME_MASK_ACTION) ?: 0
                    if (action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED) ic?.performEditorAction(action) else ic?.commitText("\n", 1)
                }
            }
        }
    }

    @androidx.compose.runtime.Composable
    private fun Key(label: String, w: Int, m: Modifier = Modifier, dark: Boolean = false, onClick: () -> Unit) {
        Box(m.then(if (w > 0) Modifier.width(w.dp) else Modifier).height(46.dp).press(0.94f, onClick = onClick).clip(RoundedCornerShape(8.dp))
            .background(if (dark) T.ink else Color.White), Alignment.Center) {
            Text(label, style = T.sans(16, T.Medium, if (dark) Color.White else T.ink))
        }
    }
}

