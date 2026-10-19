package io.github.c0mm0n.fxclip

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.widget.Toast
import io.github.c0mm0n.fxclip.engine.Engine
import io.github.c0mm0n.fxclip.engine.Rules
import io.github.c0mm0n.fxclip.engine.UserSettings
import java.io.File

/** Shared pieces of the share target, the text menu, the tile and the settings screen. */
object Fxclip {
    val builtIn: Rules by lazy { Rules.builtIn() }

    fun engine(context: Context): Engine = Engine(builtIn.applying(SettingsStore(context).load().settings))

    /** Android packages that get preview links (Telegram and its variants), from rules.json. */
    fun previewPackages(engine: Engine): List<String> =
        engine.rules.apps.flatMap { it.android.orEmpty() }.distinct()

    fun cleanedMessage(context: Context, removed: Int): String =
        if (removed == 0) context.getString(R.string.nothing_to_clean)
        else context.resources.getQuantityString(R.plurals.cleaned, removed, removed)

    fun toast(context: Context, text: String) =
        Toast.makeText(context.applicationContext, text, Toast.LENGTH_SHORT).show()

    /**
     * The clipboard text worth cleaning, or null. Same policy as the desktop apps: files and
     * images are refused, rich text only when it is one bare URL, sensitive clips are left alone.
     */
    fun readableLink(clip: ClipData?): String? {
        if (clip == null || clip.itemCount != 1) return null
        val description = clip.description
        if (description.extras?.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE) == true) return null
        val item = clip.getItemAt(0)
        if (item.uri != null || item.intent != null) return null
        val text = item.text?.toString() ?: return null
        val rich = item.htmlText != null || description.hasMimeType(ClipDescription.MIMETYPE_TEXT_HTML)
        if (rich && !Engine.isBareUrl(text)) return null
        return text.takeIf { Engine.containsUrl(it) }
    }

    /** The only thing ever stored besides the settings: how many trackers were removed. */
    fun record(context: Context, removed: Int) {
        if (removed <= 0) return
        val prefs = prefs(context)
        prefs.edit().putLong(REMOVED, prefs.getLong(REMOVED, 0) + removed).apply()
    }

    fun removedTotal(context: Context): Long = prefs(context).getLong(REMOVED, 0)

    fun autoCleanOnOpen(context: Context): Boolean = prefs(context).getBoolean(AUTO_CLEAN, true)

    fun setAutoCleanOnOpen(context: Context, on: Boolean) = prefs(context).edit().putBoolean(AUTO_CLEAN, on).apply()

    private fun prefs(context: Context) = context.getSharedPreferences("fxclip", Context.MODE_PRIVATE)
    private const val REMOVED = "trackersRemoved"
    private const val AUTO_CLEAN = "autoCleanOnOpen"

    /** Android 13+ shows its own "Copied" confirmation. */
    val systemConfirmsCopy: Boolean get() = Build.VERSION.SDK_INT >= 33

    /**
     * Cleans the clipboard link in place and returns the message to show. Only works while
     * one of our windows has focus (Android 10+).
     */
    fun cleanClipboard(context: Context): String {
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        val text = readableLink(clipboard.primaryClip) ?: return context.getString(R.string.clipboard_empty)
        val clean = engine(context).clean(text)
        if (clean.text == text) return cleanedMessage(context, 0)
        copy(context, clean.text)
        record(context, clean.removed)
        History.add(context, clean.text)
        return cleanedMessage(context, clean.removed)
    }

    fun copy(context: Context, text: String) {
        context.getSystemService(ClipboardManager::class.java)
            .setPrimaryClip(ClipData.newPlainText(context.getString(R.string.app_name), text))
    }
}

/** settings.json in the app's private files, the same format as on the other platforms. */
class SettingsStore(context: Context) {
    private val dir = context.filesDir
    private val file = File(dir, "settings.json")
    private val prefs = context.getSharedPreferences("fxclip", Context.MODE_PRIVATE)

    class Loaded(val settings: UserSettings, val recovered: Boolean)

    /** An unreadable file is kept as settings.unreadable.json and reported once, never silently replaced. */
    fun load(): Loaded {
        if (!file.exists()) return Loaded(UserSettings(), prefs.getBoolean(UNREADABLE, false))
        return try {
            Loaded(UserSettings.parse(file.readText()), prefs.getBoolean(UNREADABLE, false))
        } catch (_: Exception) {
            file.renameTo(File(dir, "settings.unreadable.json"))
            prefs.edit().putBoolean(UNREADABLE, true).apply()
            Loaded(UserSettings(), true)
        }
    }

    fun save(settings: UserSettings) {
        val tmp = File(dir, "settings.json.tmp")
        tmp.writeText(settings.toJson())
        tmp.renameTo(file)
    }

    fun dismissUnreadable() = prefs.edit().putBoolean(UNREADABLE, false).apply()

    private companion object {
        const val UNREADABLE = "unreadableNotice"
    }
}
