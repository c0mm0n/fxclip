package io.github.c0mm0n.fxclip

import org.junit.Assert.assertEquals
import org.junit.Test

class HistoryTest {
    @Test
    fun multilineShareRemainsOneEntryAndKeepsItsExactText() {
        val text = "  Review title\nhttps://example.com/article\nSecond line\t\"quoted\" 🦓  "
        assertEquals(listOf(text), History.decodeEntries(History.encodeEntries(listOf(text))))
    }

    @Test
    fun entriesKeepTheirOrderAcrossSavingAndLoading() {
        val entries = listOf("https://x.com/new", "Title\nhttps://example.com/old")
        assertEquals(entries, History.decodeEntries(History.encodeEntries(entries)))
        assertEquals(emptyList<String>(), History.decodeEntries(History.encodeEntries(emptyList())))
    }
}
