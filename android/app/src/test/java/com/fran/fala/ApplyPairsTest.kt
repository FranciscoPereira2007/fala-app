package com.fran.fala

import org.junit.Assert.assertEquals
import org.junit.Test

/** Dicionário e snippets do telemóvel aplicados ao texto do Whisper (revisão do Codex: não eram aplicados). */
class ApplyPairsTest {
    private val dict = mapOf("clode" to "Claude", "zira" to "Zyra")
    private val snip = mapOf("meu email" to "fran@repz.ai")

    @Test fun wholeWordCaseInsensitive() =
        assertEquals("Pede ao Claude para ligar à Zyra, não ao clodeX.", applyPairs("Pede ao clode para ligar à Zira, não ao clodeX.", dict, snip))
    @Test fun snippetInsideSentence() = assertEquals("Envia para fran@repz.ai amanhã.", applyPairs("Envia para meu email amanhã.", dict, snip))
    @Test fun snippetAlone() = assertEquals("fran@repz.ai", applyPairs("Meu email.", dict, snip))
    @Test fun noPairs() = assertEquals("Olá.", applyPairs("Olá.", emptyMap(), emptyMap()))
}
