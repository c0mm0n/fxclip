package io.github.c0mm0n.fxclip

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

/** Shown once on the first launch, and again from the settings screen. */
object Tutorial {
    fun seen(context: Context) = prefs(context).getBoolean(SEEN, false)

    fun markSeen(context: Context) = prefs(context).edit().putBoolean(SEEN, true).apply()

    private fun prefs(context: Context) = context.getSharedPreferences("fxclip", Context.MODE_PRIVATE)
    private const val SEEN = "tutorialSeen"
}

private data class Page(val title: Int, val body: Int, val art: Int)

private val pages = listOf(
    Page(R.string.tour_1_title, R.string.tour_1_body, R.drawable.tour_clean),
    Page(R.string.tour_2_title, R.string.tour_2_body, R.drawable.tour_share),
    Page(R.string.tour_3_title, R.string.tour_3_body, R.drawable.tour_select),
    Page(R.string.tour_4_title, R.string.tour_4_body, R.drawable.tour_tile),
)

/**
 * Cards the user swipes through, with the dots as the only progress sign. The button that ends
 * the tour appears on the last card; [onDone] closes it for good.
 */
@Composable
fun TutorialDialog(onDone: () -> Unit) {
    val state = rememberPagerState(pageCount = { pages.size })
    val last = state.currentPage == pages.lastIndex

    AlertDialog(
        onDismissRequest = onDone,
        title = { Text(stringResource(pages[state.currentPage].title)) },
        text = {
            Column {
                // Fixed height so a shorter card does not make the dialog jump while swiping.
                HorizontalPager(state = state, modifier = Modifier.heightIn(min = 260.dp)) { page ->
                    Column(
                        Modifier.fillMaxWidth(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Icon(
                            painter = painterResource(pages[page].art),
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(120.dp).padding(bottom = 12.dp),
                        )
                        Text(stringResource(pages[page].body))
                    }
                }
                Row(
                    Modifier.fillMaxWidth().padding(top = 16.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    pages.indices.forEach { i ->
                        Surface(
                            shape = CircleShape,
                            color = if (i == state.currentPage) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                MaterialTheme.colorScheme.outlineVariant
                            },
                            modifier = Modifier.padding(horizontal = 3.dp).size(8.dp),
                        ) {}
                    }
                }
            }
        },
        confirmButton = {
            // Only on the last card: swiping is the way through the others.
            Box(Modifier.heightIn(min = 40.dp), contentAlignment = Alignment.Center) {
                if (last) Button(onClick = onDone) { Text(stringResource(R.string.tour_done)) }
            }
        },
        dismissButton = {
            if (!last) TextButton(onClick = onDone) { Text(stringResource(R.string.tour_skip)) }
        },
    )
}
