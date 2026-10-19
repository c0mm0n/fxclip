package io.github.c0mm0n.fxclip

import android.app.Activity
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import io.github.c0mm0n.fxclip.engine.Engine

/**
 * "Clean link" and "Preview link" in the text selection menu. In an editable field the selection
 * is replaced; read-only text is copied. "Clean link" also gives the preview link when the field
 * belongs to Telegram; "Preview link" (an alias of this activity) always does.
 */
class ProcessTextActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        if (text == null || !Engine.containsUrl(text)) {
            Fxclip.toast(this, getString(R.string.no_link))
            setResult(RESULT_CANCELED)
            finish()
            return
        }
        val engine = Fxclip.engine(this)
        val clean = engine.clean(text)
        Fxclip.record(this, clean.removed)
        val forcePreview = intent.component?.className?.endsWith(".ProcessTextPreview") == true
        if (intent.getBooleanExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, false)) {
            val out = if (forcePreview) engine.previewAll(clean.text) else clean.text
            Fxclip.copy(this, out)
            History.add(this, out)
            if (!Fxclip.systemConfirmsCopy) Fxclip.toast(this, getString(R.string.copied))
            setResult(RESULT_CANCELED)
        } else {
            // callingPackage is the app whose text field asked (startActivityForResult).
            val out = if (forcePreview) engine.previewAll(clean.text) else engine.preview(clean.text, callingPackage ?: "")
            History.add(this, out)
            setResult(RESULT_OK, Intent().putExtra(Intent.EXTRA_PROCESS_TEXT, out))
            if (out == text) Fxclip.toast(this, getString(R.string.nothing_to_clean))
            else if (clean.removed > 0) Fxclip.toast(this, Fxclip.cleanedMessage(this, clean.removed))
        }
        finish()
    }
}

/**
 * Cleans the link on the clipboard. Android lets only the focused app read the clipboard,
 * so this invisible window reads it once it has focus, then closes.
 */
class CleanClipboardActivity : Activity() {
    private var done = false

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        Fxclip.toast(this, Fxclip.cleanClipboard(this))
        finish()
    }
}

/**
 * Whether the quick-settings tile is on the panel. Android has no way to ask, so the tile
 * itself reports it: the settings screen then offers to add it or to take it away.
 */
object Tiles {
    fun added(context: Context) = prefs(context).getBoolean(ADDED, false)

    fun setAdded(context: Context, added: Boolean) = prefs(context).edit().putBoolean(ADDED, added).apply()

    /**
     * Switches the tile service on or off. Off takes the tile off the panel and out of the
     * tile list, which is the only way an app can remove its own tile.
     */
    fun setAvailable(context: Context, available: Boolean) {
        context.packageManager.setComponentEnabledSetting(
            ComponentName(context, CleanTileService::class.java),
            if (available) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP,
        )
    }

    private fun prefs(context: Context) = context.getSharedPreferences("fxclip", Context.MODE_PRIVATE)
    private const val ADDED = "tileAdded"
}

/** Quick settings tile: opens CleanClipboardActivity for a moment. */
class CleanTileService : TileService() {
    override fun onTileAdded() {
        super.onTileAdded()
        Tiles.setAdded(this, true)
    }

    override fun onTileRemoved() {
        super.onTileRemoved()
        Tiles.setAdded(this, false)
    }

    override fun onStartListening() {
        Tiles.setAdded(this, true)
        qsTile?.apply {
            state = Tile.STATE_INACTIVE
            updateTile()
        }
    }

    override fun onClick() {
        if (isLocked) unlockAndRun { launch() } else launch()
    }

    private fun launch() {
        val intent = Intent(this, CleanClipboardActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
