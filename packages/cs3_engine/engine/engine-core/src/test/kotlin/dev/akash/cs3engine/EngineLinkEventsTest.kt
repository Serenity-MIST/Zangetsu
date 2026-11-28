package dev.akash.cs3engine

import android.content.Context
import com.fasterxml.jackson.databind.JsonNode
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.newSubtitleFile
import com.lagradost.cloudstream3.plugins.Plugin
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.lagradost.cloudstream3.utils.newExtractorLink
import dev.akash.cs3engine.host.HostHooks
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.File
import java.util.Collections
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The live link events a tagged loadLinks sends, so the app can start playing on the first link. */
class EngineLinkEventsTest {
    /** Plugin classes come from the test's own class path. */
    private object TestLoader : PluginLoader {
        override fun prepare(file: File) = PreparedPlugin(EngineLinkEventsTest::class.java.classLoader)
    }

    private val sent = Collections.synchronizedList(mutableListOf<JsonNode>())
    private var before: (String) -> Unit = {}

    @BeforeTest
    fun listen() {
        before = HostHooks.event
        HostHooks.event = { sent.add(Json.mapper.readTree(it)) }
    }

    @AfterTest
    fun restore() {
        HostHooks.event = before
        LinksApi.waitAfterFirst = false
    }

    private fun cs3(): File {
        val file = File.createTempFile("engine-links", ".cs3").apply { deleteOnExit() }
        ZipOutputStream(file.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("manifest.json"))
            zip.write("""{"name":"Links","pluginClassName":"${LinksPlugin::class.java.name}","version":1}""".toByteArray())
            zip.closeEntry()
        }
        return file
    }

    private fun params(vararg pairs: Pair<String, Any?>): JsonNode = Json.mapper.valueToTree(mapOf(*pairs))

    @Suppress("UNCHECKED_CAST")
    private suspend fun Engine.answer(method: String, vararg pairs: Pair<String, Any?>) =
        execute(method, params(*pairs)) as Map<String, Any?>

    private fun events(type: String) = synchronized(sent) { sent.filter { it["event"].asText() == type } }

    @Test
    fun `hello says the engine sends link events`() = runBlocking {
        val engine = Engine(TestLoader, { Context() }, "test")
        assertEquals(true, engine.answer("hello")["linkEvents"])
    }

    @Test
    fun `a tagged links call sends each link and subtitle as found, then linksDone, and answers as before`() = runBlocking {
        val engine = Engine(TestLoader, { Context() }, "test")
        val file = cs3()
        engine.answer("loadPlugin", "path" to file.path)
        try {
            val answer = engine.answer("loadLinks", "provider" to "Test links", "data" to "ep", "tag" to "t1")
            @Suppress("UNCHECKED_CAST")
            val links = answer["links"] as List<Map<String, Any?>>
            assertEquals(listOf("https://a.example/1.m3u8", "https://a.example/2.mp4"), links.map { it["url"] })
            // The answer still drops a repeated subtitle address; the events report every one as it came.
            @Suppress("UNCHECKED_CAST")
            assertEquals(1, (answer["subtitles"] as List<Any?>).size)
            assertEquals(true, answer["completed"])

            val linkEvents = events("link")
            assertEquals(listOf("t1", "t1"), linkEvents.map { it["tag"].asText() })
            assertEquals(links.map { it["url"] }, linkEvents.map { it["link"]["url"].asText() })
            assertEquals("M3U8", linkEvents[0]["link"]["type"].asText())
            assertEquals(2, events("subtitle").size)
            val done = events("linksDone").single()
            assertEquals("t1", done["tag"].asText())
            assertEquals(true, done["completed"].asBoolean())
            assertEquals(2, done["count"].asInt())
            // linksDone comes after every link event.
            val order = synchronized(sent) { sent.map { it["event"].asText() } }
            assertTrue(order.lastIndexOf("link") < order.indexOf("linksDone"))
        } finally {
            engine.answer("unloadPlugin", "path" to file.path)
        }
        Unit
    }

    @Test
    fun `an untagged links call sends no link events`() = runBlocking {
        val engine = Engine(TestLoader, { Context() }, "test")
        val file = cs3()
        engine.answer("loadPlugin", "path" to file.path)
        try {
            val answer = engine.answer("loadLinks", "provider" to "Test links", "data" to "ep")
            @Suppress("UNCHECKED_CAST")
            assertEquals(2, (answer["links"] as List<Any?>).size)
            assertTrue(events("link").isEmpty())
            assertTrue(events("subtitle").isEmpty())
            assertTrue(events("linksDone").isEmpty())
        } finally {
            engine.answer("unloadPlugin", "path" to file.path)
        }
        Unit
    }

    @Test
    fun `cancelLinks stops a tagged call, which answers with the links found so far`() = runBlocking {
        LinksApi.waitAfterFirst = true
        val engine = Engine(TestLoader, { Context() }, "test")
        val file = cs3()
        engine.answer("loadPlugin", "path" to file.path)
        try {
            val call = async { engine.answer("loadLinks", "provider" to "Test links", "data" to "ep", "tag" to "t2", "timeoutMs" to 60_000) }
            withTimeout(10_000) { while (events("link").isEmpty()) delay(20) }
            assertEquals(true, engine.execute("cancelLinks", params("tag" to "t2")))
            val answer = withTimeout(10_000) { call.await() }
            @Suppress("UNCHECKED_CAST")
            assertEquals(listOf("https://a.example/1.m3u8"), (answer["links"] as List<Map<String, Any?>>).map { it["url"] })
            assertEquals(false, answer["completed"])
            assertEquals(null, answer["error"])
            assertFalse(events("linksDone").single()["completed"].asBoolean())
            // A finished or unknown tag is not an error.
            assertEquals(false, engine.execute("cancelLinks", params("tag" to "t2")))
        } finally {
            engine.answer("unloadPlugin", "path" to file.path)
        }
        Unit
    }

    @Test
    fun `a cancelLinks that arrives before its loadLinks still stops that call when it starts`() = runBlocking {
        LinksApi.waitAfterFirst = true
        val engine = Engine(TestLoader, { Context() }, "test")
        val file = cs3()
        engine.answer("loadPlugin", "path" to file.path)
        try {
            // No call has this tag yet, so the engine says so, but it keeps the request.
            assertEquals(false, engine.execute("cancelLinks", params("tag" to "t3")))
            // The plugin would wait 60 s for its second link; the kept request stops it at once instead.
            val answer = withTimeout(10_000) {
                engine.answer("loadLinks", "provider" to "Test links", "data" to "ep", "tag" to "t3", "timeoutMs" to 60_000)
            }
            assertEquals(false, answer["completed"])
            assertEquals(null, answer["error"])
            assertFalse(events("linksDone").single()["completed"].asBoolean())
        } finally {
            engine.answer("unloadPlugin", "path" to file.path)
        }
        Unit
    }
}

/** A plugin with one provider whose links come one by one, as extractors find them. */
class LinksPlugin : Plugin() {
    override fun load(context: Context) {
        registerMainAPI(LinksApi())
    }
}

class LinksApi : MainAPI() {
    override var name = "Test links"

    override suspend fun loadLinks(
        data: String,
        isCasting: Boolean,
        subtitleCallback: (SubtitleFile) -> Unit,
        callback: (ExtractorLink) -> Unit,
    ): Boolean {
        callback(newExtractorLink("Test", "First", "https://a.example/1.m3u8", com.lagradost.cloudstream3.utils.ExtractorLinkType.M3U8))
        subtitleCallback(newSubtitleFile("English", "https://a.example/en.vtt"))
        // A slow mirror: the app stops the call here in the cancel test.
        if (waitAfterFirst) awaitCancellation()
        subtitleCallback(newSubtitleFile("English", "https://a.example/en.vtt"))
        callback(newExtractorLink("Test", "Second", "https://a.example/2.mp4"))
        return true
    }

    companion object {
        @JvmStatic
        @Volatile
        var waitAfterFirst = false
    }
}
