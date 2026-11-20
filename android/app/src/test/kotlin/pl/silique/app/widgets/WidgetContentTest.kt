package pl.silique.app.widgets

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.app.KeyguardManager
import android.os.PowerManager
import android.view.View
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import pl.silique.app.R
import javax.crypto.KeyGenerator

/**
 * The launcher must never be told "no notes" for a state that is only masked or
 * temporarily unreadable; these tests pin the three distinct list states.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class WidgetContentTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private val snapshot = WidgetSnapshot.fromMap(mapOf(
        "schema" to 1, "lastVaultId" to "vault-1", "notes" to listOf(mapOf(
            "id" to "note-1", "vaultId" to "vault-1", "title" to "Garden",
            "preview" to "Flowers", "searchText" to "orchid", "folder" to "Plants",
            "updatedAt" to "2026-10-23T10:00:00Z"
        ))
    ))

    @Before fun seed() {
        shadowOf(context.getSystemService(Context.POWER_SERVICE) as PowerManager).setIsInteractive(true)
        WidgetRuntime.storeFactory = { SnapshotStore(it) { key } }
        WidgetRuntime.store(context).clear()
        shadowOf(context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setKeyguardLocked(false)
    }

    private fun rendered(render: android.widget.RemoteViews): View =
        render.apply(context, android.widget.FrameLayout(context))

    @Test fun lockedStateHidesTheListAndTheEmptyHint() {
        WidgetRuntime.store(context).write(snapshot)
        shadowOf(context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setKeyguardLocked(true)
        val view = rendered(WidgetRenderer.list(context, 1))
        assertEquals(View.GONE, view.findViewById<View>(R.id.widget_notes).visibility)
        assertEquals(View.GONE, view.findViewById<View>(R.id.widget_empty).visibility)
        assertEquals(
            context.getString(R.string.widget_notes_locked),
            view.findViewById<android.widget.TextView>(R.id.widget_recent).text.toString()
        )
    }

    @Test fun unreadableStateShowsTheUnavailableHintInsteadOfNoNotes() {
        WidgetRuntime.store(context).write(snapshot)
        WidgetRuntime.storeFactory = { SnapshotStore(it) { throw IllegalStateException("keystore locked") } }
        val view = rendered(WidgetRenderer.list(context, 1))
        assertEquals(View.GONE, view.findViewById<View>(R.id.widget_notes).visibility)
        val empty = view.findViewById<View>(R.id.widget_empty)
        assertEquals(View.VISIBLE, empty.visibility)
        assertEquals(
            context.getString(R.string.widget_notes_unavailable),
            (empty as android.widget.TextView).text.toString()
        )
        val factory = NotesRemoteViewsService.Factory(context)
        factory.onDataSetChanged()
        assertEquals("An unreadable index must not look like an empty one", 0, factory.getCount())
        factory.onDestroy()
    }

    @Test fun genuinelyEmptySnapshotKeepsTheOrdinaryEmptyState() {
        WidgetRuntime.store(context).write(WidgetSnapshot(emptyList(), null))
        val render = WidgetRenderer.list(context, 1)
        val view = rendered(render)
        assertEquals("A ready state must show the collection", 0, setVisibilityOf(render, R.id.widget_notes))
        assertEquals(
            context.getString(R.string.widget_notes_empty),
            (view.findViewById<View>(R.id.widget_empty) as android.widget.TextView).text.toString()
        )
    }

    @Test fun readySnapshotRendersRowsAndSurvivesFactoryRebinds() {
        WidgetRuntime.store(context).write(snapshot)
        val render = WidgetRenderer.list(context, 1)
        rendered(render)
        assertEquals("A ready state must show the collection", 0, setVisibilityOf(render, R.id.widget_notes))
        val factory = NotesRemoteViewsService.Factory(context)
        factory.onCreate()
        assertEquals(1, factory.getCount())
        assertNotNull(factory.getViewAt(0))
        factory.onDestroy()
    }

    @Test fun aMaskedWidgetHealsOnceTheScreenIsInteractiveAgain() {
        WidgetRuntime.store(context).write(snapshot)
        shadowOf(context.getSystemService(Context.POWER_SERVICE) as PowerManager).setIsInteractive(false)
        assertTrue(WidgetRuntime.content(context) is WidgetContent.Locked)
        // No unlock broadcast reaches us (the process may have missed it): the
        // next render must read the live screen state instead of a remembered flag.
        shadowOf(context.getSystemService(Context.POWER_SERVICE) as PowerManager).setIsInteractive(true)
        assertFalse(WidgetRuntime.locked(context))
        assertTrue(WidgetRuntime.content(context) is WidgetContent.Ready)
        val view = rendered(WidgetRenderer.list(context, 1))
        assertEquals(
            context.getString(R.string.widget_notes_header),
            view.findViewById<android.widget.TextView>(R.id.widget_recent).text.toString()
        )
    }

    @Test fun everyListRenderIsRecordedInDiagnostics() {
        WidgetRuntime.store(context).write(snapshot)
        WidgetRenderer.list(context, 7)
        val log = WidgetDiagnostics.read(context)
        assertTrue(log.contains("render widget=7 type=list state=notes=1"))
        assertTrue("Diagnostics must say which live signal masked the render", log.contains("lock="))
        assertFalse("Diagnostics must never contain note text", log.contains("Garden"))
        assertFalse("Diagnostics must never contain note text", log.contains("orchid"))
    }

    /**
     * The applied visibility cannot be asserted directly: a collection without a
     * bound adapter is legitimately hidden by Android's empty-view mechanism in a
     * host test. The intent recorded in the RemoteViews is what the launcher gets.
     */
    private fun setVisibilityOf(render: android.widget.RemoteViews, target: Int): Int? {
        val actions = org.robolectric.util.ReflectionHelpers.getField<List<*>>(render, "mActions")
        for (action in actions) {
            var type: Class<*>? = action!!.javaClass
            var viewId: Int? = null
            var method: String? = null
            var value: Any? = null
            while (type != null) {
                for (field in type.declaredFields) {
                    field.isAccessible = true
                    val raw = runCatching { field.get(action) }.getOrNull()
                    when (field.name) {
                        "viewId", "mViewId" -> if (raw is Int) viewId = raw
                        "methodName" -> method = raw as? String
                        "value" -> value = raw
                    }
                }
                type = type.superclass
            }
            if (viewId == target && method == "setVisibility") return value as? Int
        }
        return null
    }
}
