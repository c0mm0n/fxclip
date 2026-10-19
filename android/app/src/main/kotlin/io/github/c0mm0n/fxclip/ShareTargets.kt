package io.github.c0mm0n.fxclip

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager

/**
 * The apps the user re-shares to most often. The share sheet reports what was picked
 * (EXTRA_CHOSEN_COMPONENT_INTENT_SENDER), so the next share can offer the top ones straight away
 * instead of the full chooser. Only a tally of package names, no link text.
 */
object ShareTargets {
    data class Target(val component: ComponentName, val label: String, val uses: Int)

    /** The most used targets that are still installed, best first. */
    fun top(context: Context, limit: Int = 3): List<Target> {
        val packages = context.packageManager
        return counts(context).entries
            .mapNotNull { (flat, uses) ->
                val component = ComponentName.unflattenFromString(flat) ?: return@mapNotNull null
                val label = try {
                    packages.getActivityInfo(component, 0).loadLabel(packages).toString()
                } catch (_: PackageManager.NameNotFoundException) {
                    return@mapNotNull null // Uninstalled since.
                }
                Target(component, label, uses)
            }
            .sortedByDescending { it.uses }
            .take(limit)
    }

    fun record(context: Context, component: ComponentName) {
        if (component.packageName == context.packageName) return
        val flat = component.flattenToString()
        val counts = counts(context).toMutableMap()
        counts[flat] = (counts[flat] ?: 0) + 1
        prefs(context).edit().putStringSet(USES, counts.map { "${it.value}|${it.key}" }.toSet()).apply()
    }

    fun forget(context: Context) = prefs(context).edit().remove(USES).apply()

    fun remembering(context: Context) = prefs(context).getBoolean(ON, true)

    fun setRemembering(context: Context, on: Boolean) {
        prefs(context).edit().putBoolean(ON, on).apply()
        if (!on) forget(context)
    }

    private fun counts(context: Context): Map<String, Int> =
        prefs(context).getStringSet(USES, emptySet()).orEmpty().mapNotNull { entry ->
            val uses = entry.substringBefore('|').toIntOrNull() ?: return@mapNotNull null
            entry.substringAfter('|') to uses
        }.toMap()

    private fun prefs(context: Context) = context.getSharedPreferences("fxclip", Context.MODE_PRIVATE)
    private const val USES = "shareTargetUses"
    private const val ON = "rememberShareTargets"
}

/** Told by the share sheet which app the user picked. */
class ChosenTargetReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!ShareTargets.remembering(context)) return
        val chosen = if (android.os.Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_CHOSEN_COMPONENT, ComponentName::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<ComponentName>(Intent.EXTRA_CHOSEN_COMPONENT)
        } ?: return
        ShareTargets.record(context, chosen)
    }
}
