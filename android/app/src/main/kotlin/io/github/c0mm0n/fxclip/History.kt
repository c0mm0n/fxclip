package io.github.c0mm0n.fxclip

import android.content.Context
import org.json.JSONArray

/**
 * The last cleaned links, for copying one again. Off by default and never on without the user
 * switching it on: the desktop apps store nothing but the counter, and this is the one place
 * where Android keeps link text, so the setting says so and emptying it is one tap.
 */
object History {
    const val MAX = 20

    fun enabled(context: Context) = prefs(context).getBoolean(ON, false)

    fun setEnabled(context: Context, on: Boolean) {
        prefs(context).edit().putBoolean(ON, on).apply()
        if (!on) clear(context)
    }

    fun entries(context: Context): List<String> {
        val saved = prefs(context)
        val json = saved.getString(JSON_LINKS, null)
        if (json != null) return decodeEntries(json)
        // Keep older histories readable; the next addition migrates them to JSON.
        return saved.getString(LINKS, null)?.lineSequence()?.filter { it.isNotBlank() }?.take(MAX)?.toList() ?: emptyList()
    }

    internal fun encodeEntries(entries: List<String>): String = JSONArray(entries).toString()

    internal fun decodeEntries(json: String): List<String> {
        val array = JSONArray(json)
        return List(minOf(array.length(), MAX)) { array.getString(it) }
    }

    /** Newest first, no duplicates, capped at [MAX]. */
    fun add(context: Context, link: String) {
        if (!enabled(context) || link.isBlank()) return
        val kept = (listOf(link) + entries(context).filter { it != link }).take(MAX)
        prefs(context).edit().putString(JSON_LINKS, encodeEntries(kept)).remove(LINKS).apply()
    }

    fun clear(context: Context) = prefs(context).edit().remove(LINKS).remove(JSON_LINKS).apply()

    private fun prefs(context: Context) = context.getSharedPreferences("fxclip", Context.MODE_PRIVATE)
    private const val ON = "historyEnabled"
    private const val LINKS = "history"
    private const val JSON_LINKS = "historyEntries"
}
