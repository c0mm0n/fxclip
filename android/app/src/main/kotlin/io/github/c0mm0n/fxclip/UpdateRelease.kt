package io.github.c0mm0n.fxclip

import org.json.JSONObject
import java.net.URI

data class UpdateRelease(val version: String, val url: String, val sha256: String, val size: Long, val notes: String) {
    fun json(): JSONObject = JSONObject().apply {
        put("tag_name", "v$version")
        put("body", notes)
        put("assets", org.json.JSONArray().put(JSONObject().apply {
            put("name", "fxclip-android.apk"); put("browser_download_url", url)
            put("digest", "sha256:$sha256"); put("size", size)
        }))
    }

    companion object {
        private val stable = Regex("^v(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)$")
        private val digest = Regex("^sha256:([0-9a-fA-F]{64})$")

        fun parse(json: JSONObject, installedVersion: String): UpdateRelease? {
            if (json.optBoolean("draft") || json.optBoolean("prerelease")) return null
            val match = stable.matchEntire(json.optString("tag_name")) ?: return null
            val next = match.groupValues.drop(1).map { it.toIntOrNull() ?: return null }
            val current = installedVersion.split('.').map { it.toIntOrNull() ?: return null }
            if (current.size != 3 || next.zip(current).firstOrNull { it.first != it.second }?.let { it.first > it.second } != true) return null
            val version = match.value.removePrefix("v")
            val assets = json.getJSONArray("assets")
            val asset = (0 until assets.length()).map { assets.getJSONObject(it) }
                .firstOrNull { it.optString("name") == "fxclip-android.apk" }
                ?: throw IllegalArgumentException("No Android download")
            val url = asset.getString("browser_download_url")
            val uri = URI(url)
            val local = BuildConfig.DEBUG && uri.scheme == "http" && uri.host == "127.0.0.1"
            require(local || url == "https://github.com/c0mm0n/fxclip/releases/download/v$version/fxclip-android.apk")
            val sha = digest.matchEntire(asset.getString("digest"))?.groupValues?.get(1)?.lowercase()
                ?: throw IllegalArgumentException("Missing SHA-256")
            val size = asset.getLong("size")
            require(size in 1..(256L * 1024 * 1024))
            return UpdateRelease(version, url, sha, size, json.optString("body").take(65536))
        }
    }
}
