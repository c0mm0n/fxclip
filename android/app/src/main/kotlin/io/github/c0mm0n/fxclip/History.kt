package io.github.c0mm0n.fxclip

import android.content.Context

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

    // A link never contains whitespace (see the engine's URL pattern), so one per line is enough.
    fun entries(context: Context): List<String> =
        prefs(context).getString(LINKS, null)?.lineSequence()?.filter { it.isNotBlank() }?.toList() ?: emptyList()

    /** Newest first, no duplicates, capped at [MAX]. */
    fun add(context: Context, link: String) {
        if (!enabled(context) || link.isBlank()) return
        val kept = (listOf(link.trim()) + entries(context).filter { it != link.trim() }).take(MAX)
        prefs(context).edit().putString(LINKS, kept.joinToString("\n")).apply()
    }

    fun clear(context: Context) = prefs(context).edit().remove(LINKS).apply()

    private fun prefs(context: Context) = context.getSharedPreferences("fxclip", Context.MODE_PRIVATE)
    private const val ON = "historyEnabled"
    private const val LINKS = "history"
}
