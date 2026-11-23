package pl.silique.app.widgets

import android.appwidget.AppWidgetManager
import android.content.Context
import android.os.Bundle
import android.os.PowerManager
import android.view.View
import android.widget.RemoteViews
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowAppWidgetManager
import org.robolectric.util.ReflectionHelpers
import pl.silique.app.R
import pl.silique.app.WidgetSearchActivity
import javax.crypto.KeyGenerator

/**
 * The three action widgets collapse to a single glyph ("+", "⌕", "✎") when the
 * launcher squeezes them to one slot (minWidth < COMPACT_BELOW_DP), while the
 * default two-slot form keeps the full label. The resize path must take the
 * width from the new options bundle, not from a stale manager read.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], shadows = [WidgetCompactTest.WidgetOptionsManager::class])
class WidgetCompactTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()
    private val manager get() = AppWidgetManager.getInstance(context)
    private val shadowManager get() = shadowOf(manager)

    @Before fun seed() {
        shadowOf(context.getSystemService(Context.POWER_SERVICE) as PowerManager).setIsInteractive(true)
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        WidgetRuntime.storeFactory = { SnapshotStore(it) { key } }
        WidgetRuntime.store(context).write(WidgetSnapshot(emptyList(), "vault-1"))
    }

    private fun layoutIdOf(views: RemoteViews): Int = views.layoutId
    private fun textOf(views: RemoteViews): String =
        views.apply(context, android.widget.FrameLayout(context)).findViewById<TextView>(R.id.widget_action).text.toString()
    private fun textOfWidget(id: Int): String =
        shadowManager.getViewFor(id).findViewById<TextView>(R.id.widget_action).text.toString()
    private fun layoutIdOfWidget(id: Int): Int {
        val widgets: Map<Int, Any> = ReflectionHelpers.getField(shadowManager, "widgetInfos")
        val lastRemoteViews: RemoteViews = ReflectionHelpers.getField(widgets.getValue(id), "lastRemoteViews")
        return layoutIdOf(lastRemoteViews)
    }

    @Test fun oneCellWidthRendersOnlyTheGlyphInTheCompactLayout() {
        val cases = listOf(
            Triple(WidgetRenderer.newNote(context, 1, 60), context.getString(R.string.widget_new_note_compact), context.getString(R.string.widget_new_note)),
            Triple(WidgetRenderer.search(context, 2, 60), context.getString(R.string.widget_search_compact), context.getString(R.string.widget_search_action)),
            Triple(WidgetRenderer.journal(context, 3, 60), context.getString(R.string.widget_journal_compact), context.getString(R.string.widget_journal_action))
        )
        for ((views, glyph, fullLabel) in cases) {
            assertEquals(R.layout.widget_action_compact, layoutIdOf(views))
            assertEquals(glyph, textOf(views))
            assertNotEquals(fullLabel, textOf(views))
        }
    }

    @Test fun absentOptionsKeepTheFullTwoSlotLabelAndLayout() {
        val cases = listOf(
            WidgetRenderer.newNote(context, 1) to context.getString(R.string.widget_new_note),
            WidgetRenderer.newNote(context, 1, 0) to context.getString(R.string.widget_new_note),
            WidgetRenderer.search(context, 2) to context.getString(R.string.widget_search_action),
            WidgetRenderer.journal(context, 3) to context.getString(R.string.widget_journal_action)
        )
        for ((views, fullLabel) in cases) {
            assertEquals(R.layout.widget_action, layoutIdOf(views))
            assertEquals(fullLabel, textOf(views))
        }
    }

    @Test fun resizeToOneCellThenBackRestoresTheFullLabel() {
        val id = shadowManager.createWidget(NewNoteWidget::class.java, R.layout.widget_action)
        assertEquals("+ New note", textOfWidget(id))
        assertEquals(R.layout.widget_action, layoutIdOfWidget(id))

        manager.updateAppWidgetOptions(id, Bundle().apply { putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 60) })
        assertEquals("+", textOfWidget(id))
        assertEquals(R.layout.widget_action_compact, layoutIdOfWidget(id))

        manager.updateAppWidgetOptions(id, Bundle().apply { putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 110) })
        assertEquals("+ New note", textOfWidget(id))
        assertEquals(R.layout.widget_action, layoutIdOfWidget(id))
    }

    @Test fun compactGlyphStillLaunchesTheSameScreenAsTheFullLabel() {
        val app = shadowOf(context as android.app.Application)
        val newId = shadowManager.createWidget(NewNoteWidget::class.java, R.layout.widget_action)
        manager.updateAppWidgetOptions(newId, Bundle().apply { putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 60) })
        shadowManager.getViewFor(newId).findViewById<View>(R.id.widget_action).performClick()
        val newNoteStarted = app.nextStartedActivity
        assertEquals("pl.silique.app.WidgetActionActivity", newNoteStarted.component!!.className)
        assertEquals("vault-1", newNoteStarted.getStringExtra("vaultId"))

        val searchId = shadowManager.createWidget(SearchWidget::class.java, R.layout.widget_action)
        manager.updateAppWidgetOptions(searchId, Bundle().apply { putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 60) })
        shadowManager.getViewFor(searchId).findViewById<View>(R.id.widget_action).performClick()
        assertEquals(WidgetSearchActivity::class.java.name, app.nextStartedActivity.component!!.className)

        val journalId = shadowManager.createWidget(JournalWidget::class.java, R.layout.widget_action)
        manager.updateAppWidgetOptions(journalId, Bundle().apply { putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 60) })
        shadowManager.getViewFor(journalId).findViewById<View>(R.id.widget_action).performClick()
        val journalStarted = app.nextStartedActivity
        assertEquals("pl.silique.app.WidgetActionActivity", journalStarted.component!!.className)
        assertEquals("vault-1", journalStarted.getStringExtra("vaultId"))
    }

    @Test fun compactWidgetAfterLanguageChangeGetsGlyphAndZeroKeyReads() {
        val id = shadowManager.createWidget(NewNoteWidget::class.java, R.layout.widget_action)
        manager.updateAppWidgetOptions(id, Bundle().apply { putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 60) })
        var keyReads = 0
        val originalFactory = WidgetRuntime.storeFactory
        WidgetRuntime.storeFactory = {
            SnapshotStore(it) { keyReads++; throw IllegalStateException("Keystore unavailable during language change") }
        }
        try {
            pl.silique.app.SiliqueLanguage.set(context, "pl")
            assertEquals("Language refresh must not read the widget key", 0, keyReads)
            val views = (shadowManager as WidgetOptionsManager).partialUpdates.last()
            assertEquals(R.layout.widget_action_compact, views.layoutId)
            val label = views.apply(context, android.widget.FrameLayout(context)).findViewById<TextView>(R.id.widget_action)
            assertEquals(context.getString(R.string.widget_new_note_compact), label.text.toString())
            assertEquals(pl.silique.app.SiliqueLanguage.text(context, R.string.widget_new_note_description), label.contentDescription.toString())
        } finally { WidgetRuntime.storeFactory = originalFactory }
    }

    /**
     * Models the launcher resize: the callback is delivered while the manager
     * still reports the previous width (the race the provider must survive by
     * using the new options bundle), then the stored value catches up.
     */
    @Implements(AppWidgetManager::class)
    class WidgetOptionsManager : ShadowAppWidgetManager() {
        private val stored = HashMap<Int, Bundle>()
        val partialUpdates = mutableListOf<RemoteViews>()

        @Implementation
        protected override fun getAppWidgetOptions(id: Int): Bundle = stored[id]?.let { Bundle(it) } ?: Bundle()

        @Implementation
        protected override fun updateAppWidgetOptions(id: Int, newOptions: Bundle) {
            val context: Context = ReflectionHelpers.getField(this, "context")
            val realManager: AppWidgetManager = ReflectionHelpers.getField(this, "realAppWidgetManager")
            getAppWidgetProviderFor(id)?.onAppWidgetOptionsChanged(context, realManager, id, Bundle(newOptions))
            stored[id] = Bundle(newOptions)
        }

        @Implementation
        protected fun partiallyUpdateAppWidget(id: Int, views: RemoteViews) {
            partialUpdates.add(views)
        }
    }
}
