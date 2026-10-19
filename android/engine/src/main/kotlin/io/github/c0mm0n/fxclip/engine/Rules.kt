package io.github.c0mm0n.fxclip.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import java.net.IDN

data class ParamSet(val params: List<String>, val prefixes: List<String>)

/** Parameters removed only on these hosts and their subdomains. */
data class Site(val id: String, val name: String, val hosts: List<String>, val params: List<String>, val stripRefPath: Boolean?)

/** Embed-friendly mirror: links whose host is exactly one of `from` get host `to`, only in the listed apps. */
data class PreviewRule(val id: String, val name: String, val from: List<String>, val to: String, val apps: List<String>)

/** One user-facing app, with its identifier on every platform. */
data class AppRule(
    val id: String,
    val name: String,
    val bundleIDs: List<String>,
    val linux: List<String>? = null,
    val windows: List<String>? = null,
    val android: List<String>? = null,
) {
    /** macOS bundle IDs exactly; Linux app_id, Windows exe and Android package ignoring case. */
    fun matches(identifier: String): Boolean = identifier in bundleIDs ||
        (linux.orEmpty() + windows.orEmpty() + android.orEmpty()).any { it.equals(identifier, ignoreCase = true) }
}

data class Trackers(val everywhere: ParamSet, val sites: List<Site>)

data class SkipHost(val host: String, val subdomains: Boolean) {
    fun covers(h: String): Boolean {
        val a = canonical(h)
        val b = canonical(host)
        return a == b || (subdomains && a.endsWith(".$b"))
    }

    companion object {
        /** Lowercased, without the DNS root dot, IDNs in their ASCII form. */
        fun canonical(host: String): String {
            val c = host.lowercase().trimEnd('.')
            return try {
                IDN.toASCII(c).lowercase()
            } catch (_: IllegalArgumentException) {
                c
            }
        }
    }
}

data class Rules(
    val version: Int,
    val trackers: Trackers,
    val previews: List<PreviewRule>,
    val apps: List<AppRule>,
    val neverClean: List<SkipHost>? = null,
) {
    /** The rules actually in force: built-ins with the user's choices applied. */
    fun applying(user: UserSettings): Rules = copy(
        trackers = Trackers(
            // The user's own parameters are removed everywhere, even with the built-in list off.
            ParamSet(
                (if (user.trackersEverywhere) trackers.everywhere.params else emptyList()) + user.addedTrackers.params,
                (if (user.trackersEverywhere) trackers.everywhere.prefixes else emptyList()) + user.addedTrackers.prefixes,
            ),
            trackers.sites.filter { it.id !in user.disabledSites },
        ),
        neverClean = user.neverClean,
        apps = apps + user.addedApps.filter { added -> apps.none { it.id == added.id } },
        previews = previews.mapNotNull { p ->
            val s = user.previews[p.id] ?: return@mapNotNull p
            if (s.enabled) p.copy(apps = s.apps) else null
        } + user.addedPreviews.filter { added -> previews.none { it.id == added.id } },
    )

    companion object {
        /** Shared/rules.json, packaged as a resource by the build. */
        fun builtIn(): Rules {
            val stream = Rules::class.java.getResourceAsStream("/fxclip/rules.json")
                ?: error("rules.json missing from the engine resources")
            return parse(stream.bufferedReader().use { it.readText() })
        }

        fun parse(json: String): Rules {
            val o = Json.parseToJsonElement(json).obj()
            val t = o.req("trackers").obj()
            val e = t.req("everywhere").obj()
            return Rules(
                version = o.req("version").int(),
                trackers = Trackers(
                    ParamSet(e.req("params").strings(), e.req("prefixes").strings()),
                    t.req("sites").arr().map {
                        val s = it.obj()
                        Site(s.req("id").str(), s.req("name").str(), s.req("hosts").strings(), s.req("params").strings(), s.opt("stripRefPath")?.bool())
                    },
                ),
                previews = o.req("previews").arr().map { parsePreview(it) },
                apps = o.req("apps").arr().map { parseApp(it) },
                neverClean = o.opt("neverClean")?.arr()?.map { parseSkipHost(it) },
            )
        }
    }
}

// JSON helpers: strict like Swift's Codable (a missing or mistyped required field fails the decode).

class SettingsFormatException(message: String) : IllegalArgumentException(message)

internal fun fail(message: String): Nothing = throw SettingsFormatException(message)

internal fun JsonElement.obj(): JsonObject = this as? JsonObject ?: fail("Expected an object")
internal fun JsonElement.arr(): JsonArray = this as? JsonArray ?: fail("Expected an array")
internal fun JsonElement.str(): String =
    (this as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fail("Expected a string")
internal fun JsonElement.bool(): Boolean =
    (this as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: fail("Expected a boolean")
internal fun JsonElement.int(): Int =
    (this as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: fail("Expected an integer")
internal fun JsonElement.strings(): List<String> = arr().map { it.str() }

/** Present and not null, or the decode fails. */
internal fun JsonObject.req(key: String): JsonElement = opt(key) ?: fail("Missing $key")

/** Absent and null both mean "use the default" (Swift decodeIfPresent). */
internal fun JsonObject.opt(key: String): JsonElement? = this[key]?.takeIf { it !is JsonNull }

internal fun parseApp(e: JsonElement): AppRule {
    val a = e.obj()
    return AppRule(
        a.req("id").str(), a.req("name").str(), a.req("bundleIDs").strings(),
        a.opt("linux")?.strings(), a.opt("windows")?.strings(), a.opt("android")?.strings(),
    )
}

internal fun parsePreview(e: JsonElement): PreviewRule {
    val p = e.obj()
    return PreviewRule(p.req("id").str(), p.req("name").str(), p.req("from").strings(), p.req("to").str(), p.req("apps").strings())
}

internal fun parseSkipHost(e: JsonElement): SkipHost {
    val h = e.obj()
    return SkipHost(h.req("host").str(), h.req("subdomains").bool())
}
