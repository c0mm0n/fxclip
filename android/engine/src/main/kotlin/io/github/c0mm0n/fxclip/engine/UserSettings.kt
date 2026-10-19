package io.github.c0mm0n.fxclip.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

data class PreviewSetting(val enabled: Boolean, val apps: List<String>)

/**
 * What the user changed on top of the built-in rules, stored as settings.json (same format as
 * the Mac, Windows and Linux apps). Anything absent falls back to its default.
 */
data class UserSettings(
    val version: Int = 1,
    val trackersEverywhere: Boolean = true,
    val disabledSites: Set<String> = emptySet(),
    val neverClean: List<SkipHost> = emptyList(),
    val previews: Map<String, PreviewSetting> = emptyMap(),
    val addedApps: List<AppRule> = emptyList(),
    /**
     * Rules the user wrote in the app itself, on top of the built-ins: tracker parameters removed
     * everywhere, and extra preview mirrors. Only the Android app edits these so far; the other
     * platforms ignore keys they don't know, so the file stays readable everywhere.
     */
    val addedTrackers: ParamSet = ParamSet(emptyList(), emptyList()),
    val addedPreviews: List<PreviewRule> = emptyList(),
) {
    fun toJson(): String = pretty.encodeToString(JsonElement.serializer(), buildJsonObject {
        put("version", version)
        put("trackersEverywhere", trackersEverywhere)
        put("disabledSites", strings(disabledSites.sorted()))
        put("neverClean", buildJsonArray {
            neverClean.forEach { h -> add(buildJsonObject { put("host", h.host); put("subdomains", h.subdomains) }) }
        })
        put("previews", buildJsonObject {
            previews.toSortedMap().forEach { (id, p) ->
                put(id, buildJsonObject { put("enabled", p.enabled); put("apps", strings(p.apps)) })
            }
        })
        put("addedApps", buildJsonArray {
            addedApps.forEach { a ->
                add(buildJsonObject {
                    put("id", a.id)
                    put("name", a.name)
                    put("bundleIDs", strings(a.bundleIDs))
                    a.linux?.let { put("linux", strings(it)) }
                    a.windows?.let { put("windows", strings(it)) }
                    a.android?.let { put("android", strings(it)) }
                })
            }
        })
        put("addedTrackers", buildJsonObject {
            put("params", strings(addedTrackers.params))
            put("prefixes", strings(addedTrackers.prefixes))
        })
        put("addedPreviews", buildJsonArray {
            addedPreviews.forEach { p ->
                add(buildJsonObject {
                    put("id", p.id)
                    put("name", p.name)
                    put("from", strings(p.from))
                    put("to", p.to)
                    put("apps", strings(p.apps))
                })
            }
        })
    })

    companion object {
        private val pretty = Json { prettyPrint = true }

        private fun strings(list: Iterable<String>) = JsonArray(list.map { JsonPrimitive(it) })

        /** Missing and null top-level keys keep their default; malformed nested values fail. */
        fun parse(json: String): UserSettings {
            val root: JsonObject = try {
                Json.parseToJsonElement(json)
            } catch (e: IllegalArgumentException) {
                fail(e.message ?: "Invalid JSON")
            }.obj()
            val d = UserSettings()
            return UserSettings(
                version = root.opt("version")?.int() ?: d.version,
                trackersEverywhere = root.opt("trackersEverywhere")?.bool() ?: d.trackersEverywhere,
                disabledSites = root.opt("disabledSites")?.strings()?.toSet() ?: d.disabledSites,
                neverClean = root.opt("neverClean")?.arr()?.map { parseSkipHost(it) } ?: d.neverClean,
                previews = root.opt("previews")?.obj()?.mapValues { (_, v) ->
                    val p = v.obj()
                    PreviewSetting(p.req("enabled").bool(), p.req("apps").strings())
                } ?: d.previews,
                addedApps = root.opt("addedApps")?.arr()?.map { parseApp(it) } ?: d.addedApps,
                addedTrackers = root.opt("addedTrackers")?.obj()?.let {
                    ParamSet(it.req("params").strings(), it.req("prefixes").strings())
                } ?: d.addedTrackers,
                addedPreviews = root.opt("addedPreviews")?.arr()?.map { parsePreview(it) } ?: d.addedPreviews,
            )
        }
    }
}
