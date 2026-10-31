package com.fran.fala

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

class L10nTest {
    @Test fun traduzPelaLinguaDoSistema() {
        val before = Locale.getDefault()
        try {
            Locale.setDefault(Locale.ENGLISH); assertEquals("Sessions", t("Sessões"))
            Locale.setDefault(Locale.FRENCH); assertEquals("Réglages", t("Definições"))
            Locale.setDefault(Locale("es")); assertEquals("Hoy", t("Hoje"))
            Locale.setDefault(Locale("pt", "PT")); assertEquals("Sessões", t("Sessões"))
        } finally { Locale.setDefault(before) }
    }
}
