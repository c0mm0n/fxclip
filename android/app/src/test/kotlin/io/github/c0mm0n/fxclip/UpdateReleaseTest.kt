package io.github.c0mm0n.fxclip

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class UpdateReleaseTest {
    private fun release(tag: String = "v0.7.0") = JSONObject().apply {
        put("tag_name", tag); put("draft", false); put("prerelease", false); put("body", "Release notes")
        put("assets", JSONArray().put(JSONObject().apply {
            put("name", "fxclip-android.apk")
            put("browser_download_url", "https://github.com/c0mm0n/fxclip/releases/download/$tag/fxclip-android.apk")
            put("size", 12345); put("digest", "sha256:" + "a".repeat(64))
        }))
    }
    private fun asset(json: JSONObject) = json.getJSONArray("assets").getJSONObject(0)
    private fun rejected(json: JSONObject) {
        try { UpdateRelease.parse(json, "0.6.0"); fail("Unverified metadata was accepted") }
        catch (_: IllegalArgumentException) { }
        catch (_: org.json.JSONException) { }
    }

    @Test fun newerStableReleaseKeepsImmutableUrlDigestAndNotes() {
        val next = UpdateRelease.parse(release(), "0.6.0")!!
        assertEquals("0.7.0", next.version); assertEquals("a".repeat(64), next.sha256)
        assertEquals(12345L, next.size); assertEquals("Release notes", next.notes)
        assertEquals(next, UpdateRelease.parse(next.json(), "0.6.0"))
    }
    @Test fun draftsPrereleasesAndNonStableTagsAreIgnored() {
        assertNull(UpdateRelease.parse(release().put("draft", true), "0.6.0"))
        assertNull(UpdateRelease.parse(release().put("prerelease", true), "0.6.0"))
        for (tag in listOf("v0.7.0-beta", "nightly", "v01.2.3", "v99999999999999999.0.0")) assertNull(UpdateRelease.parse(release(tag), "0.6.0"))
    }
    @Test fun olderAndEqualVersionsAreNeverOffered() {
        for (tag in listOf("v0.6.0", "v0.5.99", "v0.0.1")) assertNull(UpdateRelease.parse(release(tag), "0.6.0"))
        assertNotNull(UpdateRelease.parse(release("v0.10.0"), "0.9.0"))
        assertNull(UpdateRelease.parse(release(), "development"))
    }
    @Test fun aVerifiedSavedUpdateStopsBeingOfferedAfterInstallation() {
        val saved = UpdateRelease.parse(release(), "0.6.0")!!.json()
        assertNull(UpdateRelease.parse(saved, "0.7.0"))
    }
    @Test fun missingOrMalformedDigestsAreRejected() {
        for (value in listOf("", "a".repeat(64), "sha1:" + "a".repeat(40), "sha256:" + "z".repeat(64))) {
            val json = release(); asset(json).put("digest", value); rejected(json)
        }
    }
    @Test fun wrongAssetUrlsAndNamesAreRejected() {
        for (url in listOf("http://github.com/c0mm0n/fxclip/releases/download/v0.7.0/fxclip-android.apk", "https://other.example/fxclip-android.apk", "https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-android.apk", "https://github.com/other/fxclip/releases/download/v0.7.0/fxclip-android.apk")) {
            val json = release(); asset(json).put("browser_download_url", url); rejected(json)
        }
        val json = release(); asset(json).put("name", "other.apk"); rejected(json)
    }
    @Test fun unsafeSizesAreRejected() {
        for (size in listOf(0L, -1L, 256L * 1024 * 1024 + 1)) {
            val json = release(); asset(json).put("size", size); rejected(json)
        }
    }
    @Test fun unpublishedFixturesAllowOnlyLoopbackHttp() {
        val local = release(); asset(local).put("browser_download_url", "http://127.0.0.1:48637/fxclip-android.apk")
        if (BuildConfig.DEBUG) assertNotNull(UpdateRelease.parse(local, "0.6.0")) else rejected(local)
        asset(local).put("browser_download_url", "http://example.com/fxclip-android.apk")
        try { UpdateRelease.parse(local, "0.6.0"); fail("External cleartext allowed") }
        catch (_: IllegalArgumentException) { }
    }
}
