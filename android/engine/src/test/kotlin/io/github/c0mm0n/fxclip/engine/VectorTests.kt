package io.github.c0mm0n.fxclip.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class VectorTests {
    private fun shared(name: String): JsonElement {
        val dir = System.getProperty("fxclip.shared") ?: error("Run through Gradle: fxclip.shared is not set")
        return Json.parseToJsonElement(File(dir, name).readText())
    }

    private val telegramIds = listOf("Telegram.exe", "org.telegram.messenger", "org.telegram.messenger.web")

    @Test
    fun sharedVectors() {
        val engine = Engine(Rules.builtIn())
        val vectors = shared("vectors.json").jsonObject["vectors"]!!.jsonArray
        assertTrue(vectors.isNotEmpty())
        for (v in vectors) {
            val o = v.jsonObject
            val input = o["input"]!!.jsonPrimitive.content
            val clean = o["clean"]!!.jsonPrimitive.content
            val telegram = o["telegram"]!!.jsonPrimitive.content
            val result = engine.clean(input)
            assertEquals(clean, result.text, input)
            for (id in telegramIds) assertEquals(telegram, engine.preview(result.text, id), "$input in $id")
            assertEquals(clean, engine.preview(result.text, "com.whatsapp"), input)
        }
    }

    @Test
    fun sharedSettingsVectors() {
        var count = 0
        for (group in shared("settings_vectors.json").jsonObject["groups"]!!.jsonArray) {
            val g = group.jsonObject
            val name = g["name"]!!.jsonPrimitive.content
            val settings = UserSettings.parse(g["settings"].toString())
            val engine = Engine(Rules.builtIn().applying(settings))
            val roundTrip = Engine(Rules.builtIn().applying(UserSettings.parse(settings.toJson())))
            for (c in g["cases"]!!.jsonArray) {
                val o = c.jsonObject
                val input = o["input"]!!.jsonPrimitive.content
                val app = o["app"].takeUnless { it == null || it is JsonNull }?.jsonPrimitive?.content
                val expected = o["output"]!!.jsonPrimitive.content
                val clean = engine.clean(input).text
                assertEquals(expected, if (app == null) clean else engine.preview(clean, app), "$name: $input in $app")
                assertEquals(clean, roundTrip.clean(input).text, "$name round trip: $input")
                count++
            }
        }
        assertTrue(count > 0)
    }

    @Test
    fun rawBytesAndCounts() {
        val engine = Engine(Rules.builtIn())
        listOf(
            Triple("https://example.com/?q=a+b%2Bc==&utm_source=x#Keep%20This", "https://example.com/?q=a+b%2Bc==#Keep%20This", 1),
            Triple("https://example.com/?utm_%FF=x&fbclid=a", "https://example.com/", 2),
            Triple("https://amazon.com/dp/A/ref=x?tag=z", "https://amazon.com/dp/A", 2),
            Triple("https://amazon.com/dp/A/ref=x?#f", "https://amazon.com/dp/A?#f", 1),
        ).forEach { (input, expected, removed) ->
            assertEquals(CleanResult(expected, removed), engine.clean(input), input)
        }
    }

    @Test
    fun bareUrl() {
        assertTrue(Engine.isBareUrl("  https://x.com/a  "))
        assertFalse(Engine.isBareUrl("A https://x.com/a"))
        assertFalse(Engine.isBareUrl("https://x.com/a https://x.com/b"))
    }

    @Test
    fun malformedNestedSettingsAreRejected() {
        listOf(
            """{"disabledSites":[null]}""",
            """{"addedApps":[{"id":"a","name":"A","bundleIDs":[null]}]}""",
            """{"previews":{"x":{"enabled":true,"apps":[null]}}}""",
            """{"neverClean":[{"host":"example.com"}]}""",
            """{"previews":{"x":{}}}""",
            """[1]""",
            """{not json""",
        ).forEach { json -> assertFailsWith<SettingsFormatException>(json) { UserSettings.parse(json) } }
    }

    @Test
    fun missingAndNullSettingsUseDefaults() {
        val s = UserSettings.parse("""{"trackersEverywhere":null,"previews":{"x":{"enabled":false,"apps":[]}}}""")
        assertTrue(s.trackersEverywhere)
        assertFalse(s.previews.getValue("x").enabled)
        assertEquals(UserSettings(), UserSettings.parse("{}"))
    }

    @Test
    fun everyLinkInATextIsCleaned() {
        val engine = Engine(Rules.builtIn())
        val result = engine.clean("a https://x.com/a?s=1 b (https://example.com/?utm_source=x). https://x.com/b?t=2")
        assertEquals("a https://x.com/a b (https://example.com/). https://x.com/b", result.text)
        assertEquals(3, result.removed)
        assertEquals(
            "a https://fxtwitter.com/a b (https://example.com/). https://fxtwitter.com/b",
            engine.preview(result.text, "org.telegram.messenger"),
        )
    }

    @Test
    fun userWrittenRulesApply() {
        val settings = UserSettings(
            addedTrackers = ParamSet(listOf("myref"), listOf("track_")),
            addedPreviews = listOf(PreviewRule("mastodon", "Mastodon", listOf("example.social"), "preview.example", listOf("telegram"))),
        )
        val engine = Engine(Rules.builtIn().applying(settings))
        assertEquals("https://site.test/a", engine.clean("https://site.test/a?myref=1&track_id=2").text)
        assertEquals(
            "https://preview.example/@a",
            engine.preview("https://example.social/@a", "org.telegram.messenger"),
        )
        // A written rule survives being saved and read back, and is still off in other apps.
        val roundTrip = Engine(Rules.builtIn().applying(UserSettings.parse(settings.toJson())))
        assertEquals("https://site.test/a", roundTrip.clean("https://site.test/a?myref=1&track_id=2").text)
        assertEquals("https://example.social/@a", roundTrip.preview("https://example.social/@a", "com.whatsapp"))
    }

    @Test
    fun userTrackersStillApplyWithTheBuiltInListOff() {
        val engine = Engine(
            Rules.builtIn().applying(
                UserSettings(trackersEverywhere = false, addedTrackers = ParamSet(listOf("myref"), emptyList())),
            ),
        )
        assertEquals("https://site.test/a?utm_source=x", engine.clean("https://site.test/a?utm_source=x&myref=1").text)
    }

    @Test
    fun androidTelegramPackagesComeFromRules() {
        val telegram = Rules.builtIn().apps.first { it.id == "telegram" }
        assertTrue("org.telegram.messenger" in telegram.android.orEmpty())
    }
}
