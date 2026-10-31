package com.fran.fala

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewFilterTest {
    @Test fun looped() {
        assertTrue(Dictation.looped("E, e, e, e, e, e."))
        assertTrue(Dictation.looped("E-mail e-mail e-mail e-mail e-mail."))
        assertFalse(Dictation.looped("Olá, isto é um teste, é mesmo um teste."))
    }
}
