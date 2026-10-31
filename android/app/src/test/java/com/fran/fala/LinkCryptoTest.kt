package com.fran.fala

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Test
import java.io.File

/** Cifra Kotlin <-> Swift nos dois sentidos, com o LinkCrypto.swift verdadeiro compilado por swiftc. */
class LinkCryptoTest {
    companion object {
        private val root = File(System.getProperty("user.dir")).let { if (it.name == "app") it.parentFile else it }
        private val bin = File(root, "interop/linkcrypto")
        private var swift = false

        @BeforeClass @JvmStatic fun build() {
            if (!File("/usr/bin/swiftc").exists()) return
            val src = File(root, "../Shared/LinkCrypto.swift")
            val p = ProcessBuilder("swiftc", "-O", src.path, File(root, "interop/main.swift").path, "-o", bin.path).inheritIO().start()
            swift = p.waitFor() == 0
        }

        fun run(vararg a: String): String {
            val p = ProcessBuilder(listOf(bin.path) + a).redirectErrorStream(true).start()
            return p.inputStream.bufferedReader().readText().trim().also { p.waitFor() }
        }
    }

    private val token = "K7QX2M9PABCDEFGHJKMNPQRSTU" // gitleaks:allow — fixed interoperability test vector, not a service credential
    private val body = "A1R".toByteArray() + ByteArray(3200) { (it % 251).toByte() }

    @Test fun hkdfRfc5869Case1() {
        val okm = LinkCrypto.hkdf("0b".repeat(22).unhex(), "000102030405060708090a0b0c".unhex(), "f0f1f2f3f4f5f6f7f8f9".unhex(), 42)
        assertEquals("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", okm.hex())
    }

    @Test fun roundTripKotlin() {
        val id = LinkCrypto.newID()
        val r = LinkCrypto.open(LinkCrypto.seal(body, id, token), token)!!
        assertArrayEquals(id, r.id); assertArrayEquals(body, r.body)
        assertNull(LinkCrypto.open(LinkCrypto.seal(body, id, token), "OUTROCODIGO"))
        assertArrayEquals(body, LinkCrypto.openReply(LinkCrypto.sealReply(body, id, token), id, token))
        assertNull(LinkCrypto.openReply(LinkCrypto.sealReply(body, id, token), LinkCrypto.newID(), token))
    }

    @Test fun kotlinToSwift() {
        assumeTrue("swiftc em falta", swift)
        val id = LinkCrypto.newID()
        val out = run("open", token, LinkCrypto.seal(body, id, token, 1_700_000_000_123).hex()).split(" ")
        assertEquals(id.hex(), out[0]); assertEquals(body.hex(), out[1]); assertEquals("1700000000123", out[2])
        assertEquals(body.hex(), run("openReply", token, id.hex(), LinkCrypto.sealReply(body, id, token).hex()))
        // código em minúsculas dá a mesma chave (o Swift faz uppercased)
        assertEquals(id.hex(), run("open", token, LinkCrypto.seal(body, id, token.lowercase()).hex()).split(" ")[0])
    }

    @Test fun swiftToKotlin() {
        assumeTrue("swiftc em falta", swift)
        val id = LinkCrypto.newID()
        val r = LinkCrypto.open(run("seal", token, id.hex(), body.hex()).unhex(), token)!!
        assertArrayEquals(id, r.id); assertArrayEquals(body, r.body)
        assertArrayEquals(body, LinkCrypto.openReply(run("sealReply", token, id.hex(), body.hex()).unhex(), id, token))
        assertEquals(run("room", token), LinkCrypto.room(token))
    }
}
