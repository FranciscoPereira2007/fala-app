package com.fran.fala

import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray

data class Mascot(val id: String, val name: String, val isNew: Boolean)

/** Mesmos IDs, ordem e tiras que iOS/Mac; preferência guardada por ID. */
object Mascots {
    const val PREFERENCE = "fala.mascot"
    val all: List<Mascot> by lazy {
        runCatching {
            val json = Fala.app.assets.open("catalog.json").bufferedReader().use { JSONArray(it.readText()) }
            (0 until json.length()).map { i -> json.getJSONObject(i).let { Mascot(it.getString("id"), it.getString("name"), it.getBoolean("isNew")) } }
        }.getOrDefault(emptyList())
    }
    var selection by mutableStateOf(Fala.prefs.getString(PREFERENCE, "").orEmpty())
        private set
    fun select(id: String) {
        selection = id
        Fala.prefs.edit().putString(PREFERENCE, id).apply()
    }
    fun resolve(session: String): Mascot? {
        all.firstOrNull { it.id == selection }?.let { return it }
        if (all.isEmpty()) return null
        var hash = 5381u
        session.toByteArray(Charsets.UTF_8).forEach { hash = hash * 33u + it.toUByte().toUInt() }
        return all[(hash % all.size.toUInt()).toInt()]
    }
    private val cache = object : LruCache<String, ImageBitmap>(12 * 1024 * 1024) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
    }
    fun strip(id: String): ImageBitmap = synchronized(cache) {
        cache[id] ?: Fala.app.assets.open("$id.png").use {
            BitmapFactory.decodeStream(it).asImageBitmap().also { bitmap -> cache.put(id, bitmap) }
        }
    }
}

@Composable
fun MascotPreview(id: String, row: Int, animated: Boolean, modifier: Modifier = Modifier) {
    val strip by produceState<ImageBitmap?>(null, id) { value = withContext(Dispatchers.IO) { Mascots.strip(id) } }
    var frame by remember { mutableIntStateOf(0) }
    val motion = android.animation.ValueAnimator.areAnimatorsEnabled()
    LaunchedEffect(id, row, animated, motion) {
        frame = 0
        if (animated && motion) while (true) { delay(if (row == 2) 120L else 150L); frame = (frame + 1) % 6 }
    }
    Canvas(modifier) {
        strip?.let { drawImage(it, srcOffset = IntOffset(frame * 96, row * 104), srcSize = IntSize(96, 104),
            dstSize = IntSize(size.width.toInt(), size.height.toInt())) }
    }
}

@Composable
fun MascotSettings(close: () -> Unit) {
    BackHandler(onBack = close)
    var row by remember { mutableIntStateOf(1) }
    val selected = Mascots.selection.takeIf { id -> Mascots.all.any { it.id == id } }.orEmpty()
    Column(Modifier.fillMaxSize().background(T.appBG).statusBarsPadding().safeBottom()) {
        FlowHeader(Ph.caretLeft, close) { Text(t("Definições"), style = T.sans(18, T.Medium)) }
        Text(t("Mascote"), style = T.sans(22, T.Semi), modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp))
        Text(t("Escolhe quem te acompanha nas sessões."), style = T.sans(14, color = T.muted), modifier = Modifier.padding(horizontal = 20.dp))
        Row(Modifier.padding(20.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("Calmo", "À espera", "A trabalhar").forEachIndexed { i, label ->
                Box(Modifier.weight(1f).clip(RoundedCornerShape(8.dp)).background(if (row == i) T.lilac else Color.White)
                    .clickable(role = Role.RadioButton, onClick = { row = i }).padding(vertical = 10.dp), Alignment.Center) {
                    Text(label, style = T.sans(13))
                }
            }
        }
        LazyVerticalGrid(GridCells.Adaptive(100.dp), Modifier.weight(1f),
            contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            items(listOf(Mascot("", "Automático", false)) + Mascots.all, key = { it.id }) { pet ->
                val chosen = selected == pet.id
                Column(Modifier.clip(RoundedCornerShape(12.dp)).background(if (chosen) T.lilac else Color.White)
                    .border(if (chosen) 2.dp else 1.dp, if (chosen) T.ink else T.line, RoundedCornerShape(12.dp))
                    .clickable(role = Role.RadioButton, onClick = { tick(); Mascots.select(pet.id) })
                    .semantics { contentDescription = pet.name + if (chosen) ", selecionado" else "" }
                    .padding(8.dp).heightIn(min = 106.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    MascotPreview(pet.id.ifEmpty { "fala-jarvis" }, row, chosen, Modifier.size(65.dp, 70.dp))
                    Text((if (chosen) "✓ " else "") + pet.name, style = T.sans(13, if (chosen) T.Semi else androidx.compose.ui.text.font.FontWeight.Normal))
                }
            }
        }
        Text(t("Automático varia por sessão. A escolha fica guardada neste dispositivo."), style = T.sans(12, color = T.muted), modifier = Modifier.padding(20.dp))
    }
}
