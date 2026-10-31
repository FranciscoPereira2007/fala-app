package com.fran.fala

import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import org.junit.Test

/** Arrasto lento com toque longo (sem root): am instrument -e from x,y -e to x,y ... ex.: pôr a Fala na dock do launcher. */
class DragTest {
    @Test fun drag() {
        val a = InstrumentationRegistry.getArguments()
        val (x1, y1) = a.getString("from")!!.split(",").map(String::toInt)
        val (x2, y2) = a.getString("to")!!.split(",").map(String::toInt)
        UiDevice.getInstance(InstrumentationRegistry.getInstrumentation()).drag(x1, y1, x2, y2, 400) // ~2 s: o launcher lê como toque longo + arrastar
    }
}
