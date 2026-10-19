package io.github.c0mm0n.fxclip

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.c0mm0n.fxclip.engine.Engine

/**
 * "Clean link" in the share sheet. The link is cleaned, then sent on: the Telegram packages from
 * rules.json get the preview link and every other app the clean one (EXTRA_REPLACEMENT_EXTRAS).
 * Once fxclip has learnt which apps you re-share to, they are offered first, one tap each.
 */
class ShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        if (text == null || !Engine.containsUrl(text)) {
            Fxclip.toast(this, getString(R.string.no_link))
            finish()
            return
        }
        val engine = Fxclip.engine(this)
        val clean = engine.clean(text)
        Fxclip.record(this, clean.removed)
        History.add(this, clean.text)
        if (clean.removed > 0) Fxclip.toast(this, Fxclip.cleanedMessage(this, clean.removed))

        val targets = if (ShareTargets.remembering(this)) ShareTargets.top(this) else emptyList()
        if (targets.isEmpty()) {
            startActivity(chooser(clean.text, engine))
            finish()
            return
        }
        setContent {
            AlertDialog(
                onDismissRequest = { finish() },
                title = { Text(stringResource(R.string.share_title)) },
                text = {
                    Column {
                        Text(clean.text, style = MaterialTheme.typography.bodySmall)
                        for (target in targets) {
                            TextButton(
                                onClick = { sendTo(target.component, clean.text, engine) },
                                modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                            ) { Text(target.label) }
                        }
                    }
                },
                confirmButton = {
                    TextButton(onClick = {
                        startActivity(chooser(clean.text, engine))
                        finish()
                    }) { Text(stringResource(R.string.share_all_apps)) }
                },
                dismissButton = {
                    TextButton(onClick = {
                        Fxclip.copy(this, clean.text)
                        if (!Fxclip.systemConfirmsCopy) Fxclip.toast(this, getString(R.string.copied))
                        finish()
                    }) { Text(stringResource(R.string.copied)) }
                },
            )
        }
    }

    /** One tap on a remembered app: straight there, with the link that app should receive. */
    private fun sendTo(component: ComponentName, clean: String, engine: Engine) {
        startActivity(
            send(engine.preview(clean, component.packageName))
                .setComponent(component)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        ShareTargets.record(this, component)
        finish()
    }

    private fun send(text: String) = Intent(Intent.ACTION_SEND)
        .setType("text/plain")
        .putExtra(Intent.EXTRA_TEXT, text)
        .also { out -> intent.getStringExtra(Intent.EXTRA_SUBJECT)?.let { out.putExtra(Intent.EXTRA_SUBJECT, it) } }

    private fun chooser(clean: String, engine: Engine): Intent {
        val replacements = Bundle()
        for (pkg in Fxclip.previewPackages(engine)) {
            val preview = engine.preview(clean, pkg)
            if (preview != clean) replacements.putBundle(pkg, Bundle().apply { putString(Intent.EXTRA_TEXT, preview) })
        }
        // The share sheet tells us which app was picked, so the next share can offer it first.
        val told = PendingIntent.getBroadcast(
            this, 0,
            Intent(this, ChosenTargetReceiver::class.java).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        return Intent.createChooser(send(clean), getString(R.string.share_title), told.intentSender)
            .putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS, arrayOf(ComponentName(this, ShareActivity::class.java)))
            .apply { if (!replacements.isEmpty) putExtra(Intent.EXTRA_REPLACEMENT_EXTRAS, replacements) }
    }
}
