package io.github.c0mm0n.fxclip

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.DrawableRes
import androidx.annotation.RequiresApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon as M3Icon
import androidx.compose.material3.InputChip
import androidx.compose.material3.InputChipDefaults
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import io.github.c0mm0n.fxclip.engine.Engine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.lifecycle.ViewModelProvider
import io.github.c0mm0n.fxclip.engine.PreviewRule
import io.github.c0mm0n.fxclip.engine.PreviewSetting
import io.github.c0mm0n.fxclip.engine.canonicalPreviewHost
import io.github.c0mm0n.fxclip.engine.SkipHost
import io.github.c0mm0n.fxclip.engine.UserSettings

/** Settings: the same choices as the desktop apps, laid out the way Android does settings. */
class MainActivity : ComponentActivity() {
    private val updates by lazy { ViewModelProvider(this)[AppUpdater::class.java] }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val store = SettingsStore(this)
        val loaded = store.load()
        setContent { FxclipTheme { SettingsScreen(store, loaded, resumes.intValue, updates) } }
    }

    /** Bumped on every return, so the tile button matches what the panel now holds. */
    private val resumes = mutableIntStateOf(0)

    override fun onResume() {
        super.onResume()
        resumes.intValue++
        updates.onOpen()
    }

    private var cleanedThisOpen = false

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        cleanedThisOpen = false
    }

    override fun onStop() {
        super.onStop()
        cleanedThisOpen = false
    }

    /** "Clean the clipboard when fxclip opens": the clipboard is readable once the window has focus. */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || cleanedThisOpen || !Fxclip.autoCleanOnOpen(this)) return
        cleanedThisOpen = true
        val before = Fxclip.removedTotal(this)
        val message = Fxclip.cleanClipboard(this)
        if (Fxclip.removedTotal(this) != before) {
            resumes.intValue++
            Fxclip.toast(this, message)
        }
    }
}

@Composable
private fun FxclipTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val dark = isSystemInDarkTheme()
    val scheme = when {
        // Material You: the colours of the user's wallpaper, when the system offers them.
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

@OptIn(ExperimentalMaterial3Api::class, androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
private fun SettingsScreen(store: SettingsStore, loaded: SettingsStore.Loaded, resumes: Int, updates: AppUpdater) {
    var settings by remember { mutableStateOf(loaded.settings) }
    var unreadable by remember { mutableStateOf(loaded.recovered) }
    fun update(s: UserSettings) {
        settings = s
        store.save(s)
    }
    val rules = Fxclip.builtIn
    val context = LocalContext.current
    var tour by remember { mutableStateOf(!Tutorial.seen(context)) }
    val appBar = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val listState = rememberLazyListState()
    val navigationScope = rememberCoroutineScope()

    if (tour) {
        TutorialDialog {
            Tutorial.markSeen(context)
            tour = false
        }
    }

    Scaffold(
        modifier = Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }.nestedScroll(appBar.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = { Text(stringResource(R.string.app_name)) },
                actions = {
                    TextButton(modifier = Modifier.testTag("fxclip-updates-nav"), onClick = { navigationScope.launch {
                        listState.animateScrollToItem(if (unreadable) 8 else 7)
                        appBar.state.heightOffset = appBar.state.heightOffsetLimit
                    } }) {
                        Text(stringResource(R.string.update_title))
                    }
                },
                scrollBehavior = appBar,
            )
        },
    ) { padding ->
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().imePadding(),
            contentPadding = PaddingValues(
                start = 16.dp, end = 16.dp,
                top = padding.calculateTopPadding(),
                bottom = padding.calculateBottomPadding() + 24.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item { Hero(resumes) }
            if (unreadable) item {
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
                    shape = RoundedCornerShape(20.dp),
                ) {
                    Column(Modifier.padding(20.dp)) {
                        Text(stringResource(R.string.unreadable))
                        TextButton(onClick = { store.dismissUnreadable(); unreadable = false }) { Text("OK") }
                    }
                }
            }
            item { HowTo(resumes) { tour = true } }
            item {
                SettingsCard(stringResource(R.string.trackers_title), R.drawable.ic_trackers) {
                    SwitchItem(stringResource(R.string.everywhere), settings.trackersEverywhere) {
                        update(settings.copy(trackersEverywhere = it))
                    }
                    Divider()
                    for (site in rules.trackers.sites) {
                        SwitchItem(site.name, site.id !in settings.disabledSites) { on ->
                            update(
                                settings.copy(
                                    disabledSites = if (on) settings.disabledSites - site.id else settings.disabledSites + site.id,
                                ),
                            )
                        }
                    }
                }
            }
            item {
                SettingsCard(stringResource(R.string.previews_title), R.drawable.ic_preview) {
                    for (p in rules.previews) {
                        PreviewItem(p, settings.previews[p.id] ?: PreviewSetting(settings.previewDefaultsEnabled, p.apps)) { setting ->
                            update(settings.copy(previews = settings.previews + (p.id to setting)))
                        }
                    }
                    Note(stringResource(R.string.preview_privacy))
                }
            }
            item { MyRules(settings, ::update) }
            item { NeverClean(settings) { update(settings.copy(neverClean = it)) } }
            item { ClipboardOptions() }
            item { Updates(updates) }
            item { LinkHistory() }
            item { SettingsFile(store, settings, ::update) }
            item { TryLink(settings) }
            item { Privacy() }
        }
    }
}

@Composable
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
private fun Updates(updates: AppUpdater) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var downloadQuestion by remember { mutableStateOf(false) }
    var installQuestion by remember { mutableStateOf(false) }
    var permissionQuestion by remember { mutableStateOf(false) }
    var notes by remember { mutableStateOf(false) }
    val dialogModifier = Modifier.semantics { testTagsAsResourceId = true }
    val installer = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { updates.installerClosed() }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        if (context.packageManager.canRequestPackageInstalls()) updates.permissionGranted() else updates.permissionNeeded()
    }
    SettingsCard(stringResource(R.string.update_title), R.drawable.ic_file) {
        Note(stringResource(R.string.update_version, BuildConfig.VERSION_NAME))
        Note(updates.status)
        Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
            OutlinedButton(onClick = updates::check, enabled = !updates.busy, modifier = Modifier.testTag("fxclip-update-check")) { Text(stringResource(R.string.update_check)) }
        }
        if (updates.release != null) {
            if (!updates.release!!.notes.isBlank()) TextButton(onClick = { notes = true }, modifier = Modifier.padding(horizontal = 16.dp)) {
                Text(stringResource(R.string.update_notes))
            }
            if (updates.downloading) LinearProgressIndicator(progress = { updates.progress / 100f }, modifier = Modifier.fillMaxWidth().padding(16.dp))
            Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
                if (updates.ready) FilledTonalButton(enabled = !updates.busy, modifier = Modifier.testTag("fxclip-update-install"), onClick = {
                    if (context.packageManager.canRequestPackageInstalls()) installQuestion = true else permissionQuestion = true
                }) { Text(stringResource(R.string.update_install)) }
                else FilledTonalButton(enabled = !updates.busy, modifier = Modifier.testTag("fxclip-update-download"), onClick = { downloadQuestion = true }) { Text(stringResource(R.string.update_download)) }
            }
            if (updates.downloading) TextButton(onClick = updates::cancelDownload, modifier = Modifier.padding(horizontal = 16.dp).testTag("fxclip-update-cancel")) {
                Text(stringResource(R.string.update_cancel))
            }
        }
        SwitchItem(stringResource(R.string.update_automatic), updates.automatic, Modifier.testTag("fxclip-update-auto"), updates::setAutomaticChecks)
        Note(stringResource(R.string.update_privacy))
    }
    if (downloadQuestion && updates.release != null) AlertDialog(
        modifier = dialogModifier,
        onDismissRequest = { downloadQuestion = false },
        title = { Text(stringResource(R.string.update_download)) },
        text = { Text(stringResource(R.string.update_download_question, updates.release!!.version)) },
        confirmButton = { TextButton(modifier = Modifier.testTag("fxclip-update-download-confirm"), onClick = { downloadQuestion = false; updates.download() }) { Text(stringResource(R.string.update_download)) } },
        dismissButton = { TextButton(modifier = Modifier.testTag("fxclip-update-download-decline"), onClick = { downloadQuestion = false }) { Text(stringResource(R.string.update_cancel)) } },
    )
    if (installQuestion) AlertDialog(
        modifier = dialogModifier,
        onDismissRequest = { installQuestion = false },
        title = { Text(stringResource(R.string.update_install)) },
        text = { Text(stringResource(R.string.update_install_question)) },
        confirmButton = { TextButton(modifier = Modifier.testTag("fxclip-update-install-confirm"), onClick = {
            installQuestion = false
            scope.launch {
                try { updates.installationIntent()?.let { installer.launch(it) } }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { updates.cannotOpenInstaller() }
            }
        }) { Text(stringResource(R.string.update_install)) } },
        dismissButton = { TextButton(modifier = Modifier.testTag("fxclip-update-install-decline"), onClick = { installQuestion = false }) { Text(stringResource(R.string.update_cancel)) } },
    )
    if (permissionQuestion) AlertDialog(
        modifier = dialogModifier,
        onDismissRequest = { permissionQuestion = false },
        title = { Text(stringResource(R.string.update_unknown_title)) },
        text = { Text(stringResource(R.string.update_unknown_note)) },
        confirmButton = { TextButton(modifier = Modifier.testTag("fxclip-update-permission-open"), onClick = {
            permissionQuestion = false; updates.permissionNeeded()
            try { permission.launch(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + context.packageName))) }
            catch (_: Exception) { updates.cannotOpenInstaller() }
        }) { Text(stringResource(R.string.update_open_settings)) } },
        dismissButton = { TextButton(modifier = Modifier.testTag("fxclip-update-permission-decline"), onClick = { permissionQuestion = false }) { Text(stringResource(R.string.update_cancel)) } },
    )
    if (notes && updates.release != null) AlertDialog(
        modifier = dialogModifier,
        onDismissRequest = { notes = false },
        title = { Text(stringResource(R.string.update_notes)) },
        text = { Column(Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) { Text(updates.release!!.notes) } },
        confirmButton = { TextButton(onClick = { notes = false }) { Text("OK") } },
    )
}

/** What fxclip has done so far, in the colours of the theme. */
@Composable
private fun Hero(resumes: Int) {
    val context = LocalContext.current
    val removed = remember(resumes) { Fxclip.removedTotal(context) }
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
        shape = RoundedCornerShape(28.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(24.dp)) {
            Text(
                stringResource(R.string.tagline),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
            )
            Text(
                removed.toString(),
                style = MaterialTheme.typography.displaySmall,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier.padding(top = 12.dp),
            )
            Text(
                stringResource(R.string.counter_label),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
            )
        }
    }
}

@Composable
private fun HowTo(resumes: Int, showTour: () -> Unit) {
    SettingsCard(stringResource(R.string.how_title), R.drawable.ic_share) {
        Line(R.drawable.ic_share, R.string.how_share_title, R.string.how_share)
        Line(R.drawable.ic_select, R.string.how_select_title, R.string.how_select)
        Line(R.drawable.ic_clipboard, R.string.how_tile_title, R.string.how_tile)
        Line(R.drawable.ic_widget, R.string.how_widget_title, R.string.how_widget)
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (Build.VERSION.SDK_INT >= 33) TileButton(resumes)
            OutlinedButton(onClick = showTour) { Text(stringResource(R.string.tour_again)) }
        }
    }
}

@Composable
private fun Line(@DrawableRes icon: Int, title: Int, body: Int) {
    ListItem(
        headlineContent = { Text(stringResource(title)) },
        supportingContent = { Text(stringResource(body)) },
        leadingContent = { IconTile(icon) },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    )
}

/** The rounded, tinted square every row's icon sits in. */
@Composable
private fun IconTile(@DrawableRes icon: Int) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.secondaryContainer,
        modifier = Modifier.size(40.dp),
    ) {
        Box(contentAlignment = Alignment.Center) {
            M3Icon(
                painter = painterResource(icon),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSecondaryContainer,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

/** A titled card: the shape Android settings screens use for a group of rows. */
@Composable
private fun SettingsCard(title: String, @DrawableRes icon: Int, content: @Composable () -> Unit) {
    Column {
        Row(
            Modifier.padding(start = 8.dp, bottom = 8.dp, top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            M3Icon(
                painter = painterResource(icon),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp),
            )
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
        Card(
            shape = RoundedCornerShape(24.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(vertical = 4.dp)) { content() }
        }
    }
}

@Composable
private fun SwitchItem(label: String, checked: Boolean, modifier: Modifier = Modifier, onChange: (Boolean) -> Unit) {
    ListItem(
        headlineContent = { Text(label) },
        trailingContent = { Switch(checked = checked, onCheckedChange = onChange, modifier = modifier) },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    )
}

@Composable
private fun PreviewItem(rule: PreviewRule, setting: PreviewSetting, onChange: (PreviewSetting) -> Unit) {
    val target = setting.targetHost?.let(::canonicalPreviewHost) ?: rule.to
    var editing by remember(rule.id) { mutableStateOf(false) }
    var domain by remember(rule.id) { mutableStateOf("") }
    var invalid by remember(rule.id) { mutableStateOf(false) }
    ListItem(
        headlineContent = { Text(rule.name) },
        supportingContent = {
            Column {
                Text(stringResource(R.string.preview_row, rule.from.first(), target))
                TextButton(onClick = { domain = target; invalid = false; editing = true }) {
                    Text(stringResource(R.string.preview_edit))
                }
            }
        },
        trailingContent = { Switch(checked = setting.enabled, onCheckedChange = { onChange(setting.copy(enabled = it)) }) },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    )
    if (editing) AlertDialog(
        onDismissRequest = { editing = false },
        title = { Text(stringResource(R.string.preview_domain_title, rule.name)) },
        text = {
            OutlinedTextField(
                value = domain, onValueChange = { domain = it; invalid = false },
                label = { Text(stringResource(R.string.preview_domain)) },
                singleLine = true, isError = invalid,
                supportingText = {
                    Text(if (invalid) stringResource(R.string.preview_invalid) else stringResource(R.string.preview_default, rule.to))
                },
            )
        },
        confirmButton = {
            TextButton(onClick = {
                val raw = domain.trim(' ', '\t', '\r', '\n', '\u000B', '\u000C')
                val host = canonicalPreviewHost(raw)
                if (raw.isNotEmpty() && host == null) invalid = true
                else { onChange(setting.copy(targetHost = host)); editing = false }
            }) { Text(stringResource(R.string.preview_save)) }
        },
        dismissButton = {
            Row {
                TextButton(onClick = { onChange(setting.copy(targetHost = null)); editing = false }) {
                    Text(stringResource(R.string.preview_use_default))
                }
                TextButton(onClick = { editing = false }) { Text(stringResource(R.string.update_cancel)) }
            }
        },
    )
}

@Composable
private fun Divider() = HorizontalDivider(Modifier.padding(horizontal = 16.dp))

@Composable
private fun Note(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

/** A removable value: the modern way to show a short list the user built. */
@Composable
private fun Chip(label: String, onRemove: () -> Unit) {
    InputChip(
        selected = false,
        onClick = onRemove,
        label = { Text(label) },
        trailingIcon = {
            M3Icon(
                painter = painterResource(R.drawable.ic_close),
                contentDescription = stringResource(R.string.rules_remove),
                modifier = Modifier.size(InputChipDefaults.AvatarSize),
            )
        },
    )
}

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun ChipRow(content: @Composable () -> Unit) {
    FlowRow(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) { content() }
}

/**
 * Rules the user writes here, so a new tracker or a new mirror needs no new build.
 * A parameter ending in "_" is taken as a prefix, the way the built-in list spells utm_.
 */
@Composable
private fun MyRules(settings: UserSettings, update: (UserSettings) -> Unit) {
    var param by remember { mutableStateOf("") }
    var from by remember { mutableStateOf("") }
    var to by remember { mutableStateOf("") }
    val added = settings.addedTrackers
    val prefixNote = stringResource(R.string.rules_prefix)

    SettingsCard(stringResource(R.string.rules_title), R.drawable.ic_rules) {
        Note(stringResource(R.string.rules_params))
        if (added.params.isNotEmpty() || added.prefixes.isNotEmpty()) {
            ChipRow {
                added.params.forEach { name ->
                    Chip(name) { update(settings.copy(addedTrackers = added.copy(params = added.params - name))) }
                }
                added.prefixes.forEach { prefix ->
                    Chip("$prefix ($prefixNote)") {
                        update(settings.copy(addedTrackers = added.copy(prefixes = added.prefixes - prefix)))
                    }
                }
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = param, onValueChange = { param = it }, singleLine = true,
                placeholder = { Text(stringResource(R.string.rules_params_hint)) },
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.weight(1f),
            )
            FilledTonalButton(
                onClick = {
                    val name = param.trim().removePrefix("?").removePrefix("&").substringBefore('=')
                    if (name.isNotEmpty()) {
                        update(
                            settings.copy(
                                addedTrackers = if (name.endsWith("_")) {
                                    added.copy(prefixes = (added.prefixes + name.lowercase()).distinct())
                                } else {
                                    added.copy(params = (added.params + name).distinct())
                                },
                            ),
                        )
                    }
                    param = ""
                },
                modifier = Modifier.padding(start = 8.dp),
            ) { Text(stringResource(R.string.rules_add)) }
        }

        Divider()
        Note(stringResource(R.string.rules_previews))
        if (settings.addedPreviews.isNotEmpty()) {
            ChipRow {
                settings.addedPreviews.forEach { rule ->
                    Chip(rule.from.first() + " → " + rule.to) {
                        update(settings.copy(addedPreviews = settings.addedPreviews - rule))
                    }
                }
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = from, onValueChange = { from = it }, singleLine = true,
                label = { Text(stringResource(R.string.rules_preview_from)) },
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.weight(1f),
            )
            OutlinedTextField(
                value = to, onValueChange = { to = it }, singleLine = true,
                label = { Text(stringResource(R.string.rules_preview_to)) },
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.weight(1f).padding(start = 8.dp),
            )
        }
        Row(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                stringResource(R.string.rules_preview_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f),
            )
            FilledTonalButton(onClick = {
                val site = hostOf(from)
                val mirror = hostOf(to)
                if (site.isNotEmpty() && mirror.isNotEmpty()) {
                    // Telegram by default, like the built-in mirrors; "www." is matched too.
                    val rule = PreviewRule(
                        id = "user-" + site, name = site,
                        from = listOf(site, "www." + site), to = mirror,
                        apps = Fxclip.builtIn.previews.firstOrNull()?.apps ?: listOf("telegram"),
                    )
                    update(settings.copy(addedPreviews = settings.addedPreviews.filterNot { it.id == rule.id } + rule))
                    from = ""
                    to = ""
                }
            }) { Text(stringResource(R.string.rules_add)) }
        }
    }
}

/** Accepts a pasted link as well as a bare host. */
private fun hostOf(input: String): String {
    val text = input.trim()
    return SkipHost.canonical(Engine.host(text) ?: text.substringBefore('/'))
}

@Composable
private fun NeverClean(settings: UserSettings, onChange: (List<SkipHost>) -> Unit) {
    var input by remember { mutableStateOf("") }
    SettingsCard(stringResource(R.string.never_title), R.drawable.ic_shield) {
        if (settings.neverClean.isNotEmpty()) {
            ChipRow {
                settings.neverClean.forEach { h ->
                    Chip(h.host) { onChange(settings.neverClean - h) }
                }
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = input, onValueChange = { input = it }, singleLine = true,
                placeholder = { Text(stringResource(R.string.never_hint)) },
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.weight(1f),
            )
            FilledTonalButton(
                onClick = {
                    val host = hostOf(input)
                    if (host.isNotEmpty() && settings.neverClean.none { SkipHost.canonical(it.host) == host }) {
                        onChange(settings.neverClean + SkipHost(host, subdomains = true))
                    }
                    input = ""
                },
                modifier = Modifier.padding(start = 8.dp),
            ) { Text(stringResource(R.string.never_add)) }
        }
        Note(stringResource(R.string.never_subdomains))
    }
}

@Composable
private fun ClipboardOptions() {
    val context = LocalContext.current
    var autoClean by remember { mutableStateOf(Fxclip.autoCleanOnOpen(context)) }
    var remembering by remember { mutableStateOf(ShareTargets.remembering(context)) }
    // Asking the package manager is slow, so it happens once per change, never per frame.
    val hasTargets by produceState(false, remembering) {
        value = remembering && withContext(Dispatchers.IO) { ShareTargets.top(context).isNotEmpty() }
    }

    SettingsCard(stringResource(R.string.clean_clipboard_label), R.drawable.ic_clipboard) {
        SwitchItem(stringResource(R.string.auto_clean), autoClean) {
            autoClean = it
            Fxclip.setAutoCleanOnOpen(context, it)
        }
        Divider()
        SwitchItem(stringResource(R.string.share_targets_switch), remembering) {
            remembering = it
            ShareTargets.setRemembering(context, it)
        }
        if (hasTargets) {
            Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
                OutlinedButton(onClick = { ShareTargets.forget(context); remembering = true }) {
                    Text(stringResource(R.string.share_targets_forget))
                }
            }
        }
    }
}

/** The last cleaned links, each one tap away from the clipboard again. */
@Composable
private fun LinkHistory() {
    val context = LocalContext.current
    var on by remember { mutableStateOf(History.enabled(context)) }
    var entries by remember { mutableStateOf(History.entries(context)) }

    SettingsCard(stringResource(R.string.history_title), R.drawable.ic_history) {
        SwitchItem(stringResource(R.string.history_switch), on) {
            on = it
            History.setEnabled(context, it)
            entries = History.entries(context)
        }
        Note(stringResource(R.string.history_note))
        if (on) {
            Divider()
            if (entries.isEmpty()) {
                Note(stringResource(R.string.history_empty))
            } else {
                for (link in entries) {
                    ListItem(
                        headlineContent = {
                            Text(link, style = MaterialTheme.typography.bodyMedium, maxLines = 2)
                        },
                        trailingContent = {
                            M3Icon(
                                painter = painterResource(R.drawable.ic_copy),
                                contentDescription = stringResource(R.string.copied),
                                tint = MaterialTheme.colorScheme.primary,
                            )
                        },
                        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                        modifier = Modifier.clickable {
                            Fxclip.copy(context, link)
                            if (!Fxclip.systemConfirmsCopy) Fxclip.toast(context, context.getString(R.string.copied))
                        },
                    )
                }
                Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
                    OutlinedButton(onClick = { History.clear(context); entries = emptyList() }) {
                        Text(stringResource(R.string.history_clear))
                    }
                }
            }
        }
    }
}

/** Import and export of the settings.json shared with the Mac, Windows and Linux apps. */
@Composable
private fun SettingsFile(store: SettingsStore, settings: UserSettings, update: (UserSettings) -> Unit) {
    val context = LocalContext.current
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri != null) {
            runCatching {
                context.contentResolver.openOutputStream(uri)!!.use { it.write(settings.toJson().toByteArray()) }
            }.onSuccess { Fxclip.toast(context, context.getString(R.string.file_exported)) }
                .onFailure { Fxclip.toast(context, context.getString(R.string.file_failed)) }
        }
    }
    val import = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            runCatching {
                val text = context.contentResolver.openInputStream(uri)!!.use { it.readBytes().decodeToString() }
                UserSettings.parse(text)
            }.onSuccess {
                update(it)
                store.dismissUnreadable()
                Fxclip.toast(context, context.getString(R.string.file_imported))
            }.onFailure { Fxclip.toast(context, context.getString(R.string.file_failed)) }
        }
    }

    SettingsCard(stringResource(R.string.file_title), R.drawable.ic_file) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FilledTonalButton(onClick = { export.launch("settings.json") }) {
                Text(stringResource(R.string.file_export))
            }
            OutlinedButton(onClick = { import.launch(arrayOf("application/json", "text/plain")) }) {
                Text(stringResource(R.string.file_import))
            }
        }
        Note(stringResource(R.string.file_note))
    }
}

@Composable
private fun TryLink(settings: UserSettings) {
    var input by remember { mutableStateOf("") }
    val engine = remember(settings) { Engine(Fxclip.builtIn.applying(settings)) }

    SettingsCard(stringResource(R.string.try_title), R.drawable.ic_try) {
        OutlinedTextField(
            value = input, onValueChange = { input = it },
            placeholder = { Text(stringResource(R.string.try_hint)) },
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        )
        if (Engine.containsUrl(input)) {
            val clean = engine.clean(input).text
            val telegram = engine.preview(clean, "org.telegram.messenger")
            Result(stringResource(R.string.try_clean, clean))
            if (telegram != clean) Result(stringResource(R.string.try_telegram, telegram))
        }
    }
}

@Composable
private fun Result(text: String) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHighest,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        Text(
            text,
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            modifier = Modifier.padding(12.dp),
        )
    }
}

@Composable
private fun Privacy() {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        M3Icon(
            painter = painterResource(R.drawable.ic_shield),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
        Text(
            stringResource(R.string.privacy),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 8.dp),
        )
    }
}

/**
 * Adds the tile, or takes it away once it is there. Android asks the user to add it and tells
 * us the answer. There is no API to take a tile back, so removing switches the tile service off:
 * Android then drops it from the panel, and the button offers to add it again.
 */
@Composable
@RequiresApi(33)
private fun TileButton(resumes: Int) {
    val context = LocalContext.current
    var added by remember(resumes) { mutableStateOf(Tiles.added(context)) }
    val tile = ComponentName(context, CleanTileService::class.java)

    Button(onClick = {
        if (added) {
            Tiles.setAvailable(context, false)
            Tiles.setAdded(context, false)
            added = false
            Fxclip.toast(context, context.getString(R.string.tile_removed))
        } else {
            Tiles.setAvailable(context, true)
            context.getSystemService(StatusBarManager::class.java).requestAddTileService(
                tile,
                context.getString(R.string.tile_label),
                Icon.createWithResource(context, R.drawable.ic_tile),
                context.mainExecutor,
            ) { result ->
                val onPanel = result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ||
                    result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED
                if (onPanel) {
                    Tiles.setAdded(context, true)
                    added = true
                }
            }
        }
    }) { Text(stringResource(if (added) R.string.remove_tile else R.string.add_tile)) }
}
