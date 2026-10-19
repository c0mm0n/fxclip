package io.github.c0mm0n.fxclip

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/** Home-screen button that cleans the link on the clipboard, like the quick-settings tile. */
class CleanWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val tap = PendingIntent.getActivity(
            context, 0,
            Intent(context, CleanClipboardActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.widget_clean).apply {
                setTextViewText(R.id.widget_label, context.getString(R.string.clean_clipboard_label))
                setOnClickPendingIntent(R.id.widget_root, tap)
            }
            manager.updateAppWidget(id, views)
        }
    }

    companion object {
        /** Redraws the widget after a language or label change. */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, CleanWidget::class.java))
            if (ids.isNotEmpty()) CleanWidget().onUpdate(context, manager, ids)
        }
    }
}
