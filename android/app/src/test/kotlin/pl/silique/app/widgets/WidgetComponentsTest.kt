package pl.silique.app.widgets

import android.app.Activity
import android.app.KeyguardManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.view.WindowManager
import android.widget.EditText
import android.widget.ListView
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import pl.silique.app.R
import pl.silique.app.WidgetSearchActivity
import javax.crypto.KeyGenerator

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class WidgetComponentsTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()
    @Before fun seed() {
        WidgetRuntime.screenOff = false
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        WidgetRuntime.storeFactory = { SnapshotStore(it) { key } }
        WidgetRuntime.store(context).write(WidgetSnapshot.fromMap(mapOf(
            "schema" to 1, "lastVaultId" to "vault-1", "notes" to listOf(mapOf(
                "id" to "note-1", "vaultId" to "vault-1", "title" to "Garden",
                "preview" to "Flowers", "searchText" to "orchid", "folder" to "Plants",
                "updatedAt" to "2026-10-23T10:00:00Z"
            ))
        )))
    }

    @Test fun vaultDeletionFiltersPersistedSnapshotAndRevokesOpenSearchAndStaleRows() {
        val first = WidgetRuntime.store(context).read().notes.single()
        val keep = first.copy(id = "keep-note", vaultId = "keep-vault", title = "Keep")
        WidgetRuntime.publish(context, WidgetSnapshot(listOf(first, keep), "vault-1"))
        val factory = NotesRemoteViewsService.Factory(context)
        factory.onCreate()
        val controller = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
        val query = controller.get().findViewById<EditText>(R.id.widget_query)
        query.setText("orchid")
        WidgetRuntime::class.java.getMethod("removeVault", Context::class.java, String::class.java)
            .invoke(WidgetRuntime, context, "vault-1")
        val readback = WidgetRuntime.store(context).read()
        assertEquals(listOf(keep), readback.notes)
        assertEquals("keep-vault", readback.lastVaultId)
        assertEquals("", query.text.toString())
        assertNull(factory.getViewAt(0))
        WidgetRuntime::class.java.getMethod("removeVault", Context::class.java, String::class.java)
            .invoke(WidgetRuntime, context, "keep-vault")
        assertTrue(WidgetRuntime.store(context).read().notes.isEmpty())
        controller.pause().stop().destroy()
        factory.onDestroy()
    }

    @Test fun launcherSurfacesUseTheApplicationPalette() {
        val parent = android.widget.FrameLayout(context)
        val list = WidgetRenderer.list(context, 42).apply(context, parent)
        val header = list.findViewById<android.widget.TextView>(R.id.widget_recent)
        assertEquals("Widget header must use the app surface colour", 0xFFEEEFFF.toInt(), header.currentTextColor)
        val surface = list.findViewById<android.view.View>(R.id.widget_surface)
        val background = surface.background as android.graphics.drawable.GradientDrawable
        assertEquals("Widget panel must use the app canvas colour", 0xFF131925.toInt(), background.color!!.defaultColor)
        val factory = NotesRemoteViewsService.Factory(context)
        factory.onDataSetChanged()
        val row = factory.getViewAt(0)!!.apply(context, parent)
        assertEquals(0xFFEEEFFF.toInt(), row.findViewById<android.widget.TextView>(R.id.widget_title).currentTextColor)
        assertEquals(0xFFA5AEC8.toInt(), row.findViewById<android.widget.TextView>(R.id.widget_preview).currentTextColor)
    }

    @Test fun threeSeparateProvidersHaveMetadataAndPrivateComponents() {
        val pm = context.packageManager
        for (type in listOf(NoteListWidget::class.java, NewNoteWidget::class.java, SearchWidget::class.java)) {
            val info = pm.getReceiverInfo(ComponentName(context, type), PackageManager.GET_META_DATA)
            assertFalse(info.exported)
            assertNotEquals(0, info.metaData.getInt(AppWidgetManager.META_DATA_APPWIDGET_PROVIDER))
        }
        assertFalse(pm.getActivityInfo(ComponentName(context, WidgetSearchActivity::class.java), 0).exported)
        assertFalse(pm.getServiceInfo(ComponentName(context, NotesRemoteViewsService::class.java), 0).exported)
    }

    @Test fun widgetLayoutsInflateWithActionTargetsAndRealCollection() {
        val receivers = context.packageManager.queryBroadcastReceivers(
            android.content.Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).setPackage(context.packageName),
            PackageManager.GET_META_DATA
        )
        val journal = receivers.find { it.activityInfo.name == "pl.silique.app.widgets.JournalWidget" }
        assertNotNull("Journal entry must be available in the launcher picker", journal)
        assertFalse(journal!!.activityInfo.exported)
        assertNotEquals(0, journal.activityInfo.metaData.getInt(AppWidgetManager.META_DATA_APPWIDGET_PROVIDER))
        val parent = android.widget.FrameLayout(context)
        val list = WidgetRenderer.list(context, 42).apply(context, parent)
        assertNotNull(list.findViewById<ListView>(R.id.widget_notes))
        assertNotNull(list.findViewById<android.view.View>(R.id.widget_recent))
        val create = WidgetRenderer.newNote(context, 42).apply(context, parent)
        create.findViewById<android.view.View>(R.id.widget_action).performClick()
        assertEquals("pl.silique.app.WidgetActionActivity", shadowOf(context as android.app.Application).nextStartedActivity.component!!.className)
        val search = WidgetRenderer.search(context, 42).apply(context, parent)
        search.findViewById<android.view.View>(R.id.widget_action).performClick()
        assertEquals(WidgetSearchActivity::class.java.name, shadowOf(context as android.app.Application).nextStartedActivity.component!!.className)
    }

    @Test fun listRowsCarryValidatedIdentityAndOpenTheChosenNoteDirectly() {
        fun actions(view: android.widget.RemoteViews): List<Any> =
            org.robolectric.util.ReflectionHelpers.getField(view, "mActions")
        val list = WidgetRenderer.list(context, 42)
        val launchers = actions(list).flatMap { action ->
            action.javaClass.declaredFields.filter { it.type == android.app.PendingIntent::class.java }.mapNotNull {
                it.isAccessible = true
                it.get(action) as? android.app.PendingIntent
            }
        }
        assertTrue("A row must open its chosen note, not reopen the search picker",
            launchers.any { shadowOf(it).savedIntent.component!!.className == "pl.silique.app.WidgetActionActivity" })
        val factory = NotesRemoteViewsService.Factory(context)
        factory.onCreate()
        val row = factory.getViewAt(0)!!
        val identities = actions(row).flatMap { action ->
            action.javaClass.declaredFields.filter { it.type == android.content.Intent::class.java }.mapNotNull {
                it.isAccessible = true
                it.get(action) as? android.content.Intent
            }
        }
        assertTrue(identities.any { it.getStringExtra("noteId") == "note-1" && it.getStringExtra("vaultId") == "vault-1" })
        factory.onDestroy()
    }

    @Test fun collectionFillInOpensOnlyCurrentEligibleNoteAndRepeatedTapsHaveFreshRequests() {
        val pending = WidgetIntents.collectionPending(context, 77)
        val launches = (0..1).map {
            pending.send(context, 0, android.content.Intent().putExtra("vaultId", "vault-1").putExtra("noteId", "note-1"))
            val incoming = shadowOf(context as android.app.Application).nextStartedActivity
            assertEquals("pl.silique.app.WidgetActionActivity", incoming.component!!.className)
            val controller = Robolectric.buildActivity(pl.silique.app.WidgetActionActivity::class.java, incoming).setup()
            val launch = shadowOf(controller.get()).nextStartedActivity
            assertEquals("pl.silique.app.MainActivity", launch.component!!.className)
            assertEquals("note-1", launch.getStringExtra("noteId"))
            controller.pause().stop().destroy()
            launch
        }
        assertNotEquals(launches[0].data, launches[1].data)
        WidgetRuntime.clear(context)
        pending.send(context, 0, android.content.Intent().putExtra("vaultId", "vault-1").putExtra("noteId", "note-1"))
        val incoming = shadowOf(context as android.app.Application).nextStartedActivity
        val controller = Robolectric.buildActivity(pl.silique.app.WidgetActionActivity::class.java, incoming).setup()
        assertNull(shadowOf(controller.get()).nextStartedActivity)
        controller.pause().stop().destroy()
    }

    @Test fun journalImmutablePendingLaunchesJournalAndCanBeTappedTwice() {
        val pending = WidgetIntents.journalPending(context, "vault-1", 78)
        assertTrue(shadowOf(pending).flags and android.app.PendingIntent.FLAG_IMMUTABLE != 0)
        val launches = (0..1).map {
            pending.send()
            val incoming = shadowOf(context as android.app.Application).nextStartedActivity
            val controller = Robolectric.buildActivity(pl.silique.app.WidgetActionActivity::class.java, incoming).setup()
            val launch = shadowOf(controller.get()).nextStartedActivity
            assertEquals("journal", launch.getStringExtra("action"))
            assertEquals("vault-1", launch.getStringExtra("vaultId"))
            controller.pause().stop().destroy()
            launch
        }
        assertNotEquals(launches[0].data, launches[1].data)
    }

    @Test fun searchNeverShowsTheExistingEditorBehindItsBackdrop() {
        val controller = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
        val activity = controller.get()
        val theme = activity.obtainStyledAttributes(intArrayOf(
            android.R.attr.windowIsTranslucent,
            android.R.attr.windowIsFloating,
            android.R.attr.backgroundDimEnabled,
            android.R.attr.windowBackground
        ))
        try {
            assertFalse("Search must cover any previously open note", theme.getBoolean(0, true))
            assertFalse(theme.getBoolean(1, true))
            assertFalse(theme.getBoolean(2, true))
            val background = theme.getDrawable(3) as android.graphics.drawable.ColorDrawable
            assertEquals(0xFF131925.toInt(), background.color)
        } finally { theme.recycle() }
        assertEquals(WindowManager.LayoutParams.MATCH_PARENT, activity.window.attributes.width)
        assertEquals(WindowManager.LayoutParams.MATCH_PARENT, activity.window.attributes.height)
        val backdropId = activity.resources.getIdentifier("widget_search_backdrop", "id", activity.packageName)
        val cardId = activity.resources.getIdentifier("widget_search_card", "id", activity.packageName)
        assertNotEquals(0, backdropId)
        assertNotEquals(0, cardId)
        val backdrop = activity.findViewById<android.widget.FrameLayout>(backdropId)
        val card = activity.findViewById<android.view.View>(cardId)
        assertEquals(android.view.Gravity.CENTER, (card.layoutParams as android.widget.FrameLayout.LayoutParams).gravity)
        assertEquals(0xFF131925.toInt(), (card.background as android.graphics.drawable.ColorDrawable).color)
        backdrop.performClick()
        assertTrue(activity.isFinishing)
        controller.pause().stop().destroy()
    }

    @Test fun searchQueryRemainsVisibleInShortImeWindow() {
        val controller = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
        val backdrop = controller.get().findViewById<android.widget.FrameLayout>(R.id.widget_search_backdrop)
        val query = controller.get().findViewById<EditText>(R.id.widget_query)
        val width = android.view.View.MeasureSpec.makeMeasureSpec(320, android.view.View.MeasureSpec.EXACTLY)
        val height = android.view.View.MeasureSpec.makeMeasureSpec(200, android.view.View.MeasureSpec.EXACTLY)
        backdrop.measure(width, height)
        backdrop.layout(0, 0, 320, 200)
        val card = controller.get().findViewById<android.view.View>(R.id.widget_search_card)
        assertEquals("Card must shrink with IME window", android.view.ViewGroup.LayoutParams.MATCH_PARENT, card.layoutParams.height)
        val results = controller.get().findViewById<ListView>(R.id.widget_results)
        val resultsParams = results.layoutParams as android.widget.LinearLayout.LayoutParams
        assertEquals("Results must yield space to the query", 0, resultsParams.height)
        assertEquals(1f, resultsParams.weight)
        assertTrue("Search card must fit the resized viewport", card.height <= 200)
        val top = query.top + (query.parent as android.view.View).top
        assertTrue("Search must not be clipped above the resized window", top >= 0)
        assertTrue("Query must remain entirely visible with the keyboard", top + query.height <= 200)
        controller.pause().stop().destroy()
    }

    @Test fun searchAutofocusesQueryAndRequestsKeyboardOnOpen() {
        val controller = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
        val activity = controller.get()
        val query = activity.findViewById<EditText>(R.id.widget_query)
        assertTrue("Search query should receive initial focus", query.hasFocus())
        val softInputMode = activity.window.attributes.softInputMode
        assertEquals(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE,
            softInputMode and WindowManager.LayoutParams.SOFT_INPUT_MASK_STATE)
        assertEquals(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE,
            softInputMode and WindowManager.LayoutParams.SOFT_INPUT_MASK_ADJUST)
        controller.pause().stop().destroy()
    }

    @Test fun searchIsNativeSecureEditableAndDoesNotLaunchFlutterUntilResultClick() {
        val controller = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
        val activity = controller.get()
        assertEquals(Activity::class.java, WidgetSearchActivity::class.java.superclass)
        assertTrue(activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
        assertNull(shadowOf(activity).nextStartedActivity)
        val query = activity.findViewById<EditText>(R.id.widget_query)
        val results = activity.findViewById<ListView>(R.id.widget_results)
        assertEquals(1, results.adapter.count)
        query.setText("missing")
        assertEquals(0, results.adapter.count)
        query.setText("ORCHID")
        assertEquals(1, results.adapter.count)
        assertNull(shadowOf(activity).nextStartedActivity)
        results.performItemClick(results.adapter.getView(0, null, results), 0, 0)
        val launched = shadowOf(activity).nextStartedActivity
        assertEquals("pl.silique.app.MainActivity", launched.component!!.className)
        assertEquals("note-1", launched.getStringExtra("noteId"))
        assertTrue(activity.isFinishing)
        controller.pause().stop().destroy()
    }

    @Test fun clearImmediatelyRemovesOpenNativeSearchResults() {
        val controller = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
        val activity = controller.get()
        WidgetRuntime.clear(context)
        assertEquals(0, activity.findViewById<ListView>(R.id.widget_results).adapter.count)
        assertNull(shadowOf(activity).nextStartedActivity)
        controller.pause().stop().destroy()
    }

    @Test fun screenOffMasksOpenSearchBeforeKeyguardHasLocked() {
        val controller = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
        val activity = controller.get()
        assertEquals(1, activity.findViewById<ListView>(R.id.widget_results).adapter.count)
        context.sendBroadcast(android.content.Intent(android.content.Intent.ACTION_SCREEN_OFF))
        org.robolectric.shadows.ShadowLooper.shadowMainLooper().idle()
        assertEquals(0, activity.findViewById<ListView>(R.id.widget_results).adapter.count)
        controller.pause().stop().destroy()
    }

    @Test fun revokeClearsTypedQueryAndPreventsStaleResultClick() {
        val controller = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
        val activity = controller.get()
        val query = activity.findViewById<EditText>(R.id.widget_query)
        query.setText("ORCHID")
        val results = activity.findViewById<ListView>(R.id.widget_results)
        val staleView = results.adapter.getView(0, null, results)
        WidgetRuntime.clear(context)
        assertEquals("", query.text.toString())
        results.performItemClick(staleView, 0, 0)
        assertNull(shadowOf(activity).nextStartedActivity)
        controller.pause().stop().destroy()
    }

    @Test fun collectionFactoryDropsRevokedRowsImmediately() {
        val factory = NotesRemoteViewsService.Factory(context)
        factory.onCreate()
        assertEquals(1, factory.getCount())
        assertNotNull(factory.getViewAt(0))
        WidgetRuntime.clear(context)
        assertEquals(0, factory.getCount())
        assertNull(factory.getViewAt(0))
        factory.onDestroy()
    }

    @Test fun launcherRejectsMalformedNewNoteVaultRatherThanRepairingIt() {
        val intent = shadowOf(WidgetIntents.newPending(context, "../vault", 9)).savedIntent
        val controller = Robolectric.buildActivity(pl.silique.app.WidgetActionActivity::class.java, intent).setup()
        assertNull(shadowOf(controller.get()).nextStartedActivity)
        controller.pause().stop().destroy()
    }

    @Test fun newNotePreservesLockedVaultIdentityInsteadOfRedirectingToAnotherVault() {
        WidgetRuntime.clear(context)
        val incoming = shadowOf(WidgetIntents.newPending(context, "vault-1", 79)).savedIntent
        val controller = Robolectric.buildActivity(pl.silique.app.WidgetActionActivity::class.java, incoming).setup()
        val launch = shadowOf(controller.get()).nextStartedActivity
        assertEquals("vault-1", launch.getStringExtra("vaultId"))
        controller.pause().stop().destroy()
    }

    @Test fun reusableLauncherMakesDistinctActionsPerTapAndEmptySnapshotUsesDefaultVault() {
        WidgetRuntime.clear(context)
        val intent = shadowOf(WidgetIntents.newPending(context, null, 9)).savedIntent
        val launches = (0..1).map {
            val controller = Robolectric.buildActivity(pl.silique.app.WidgetActionActivity::class.java, intent).setup()
            val launch = shadowOf(controller.get()).nextStartedActivity
            assertEquals("pl.silique.app.MainActivity", launch.component!!.className)
            assertEquals("newNote", launch.getStringExtra("action"))
            assertNull(launch.getStringExtra("vaultId"))
            controller.pause().stop().destroy()
            launch
        }
        val queue = WidgetActionQueue()
        assertTrue(queue.accept(launches[0]))
        assertTrue(queue.accept(launches[1]))
        assertNotEquals(queue.take()!!["requestId"], queue.take()!!["requestId"])
    }

    @Test fun resumingBehindKeyguardRevokesExistingQueryAsWellAsResults() {
        val controller = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
        val activity = controller.get()
        val query = activity.findViewById<EditText>(R.id.widget_query)
        query.setText("ORCHID")
        controller.pause()
        shadowOf(context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setKeyguardLocked(true)
        controller.resume()
        assertEquals("", query.text.toString())
        assertEquals(0, activity.findViewById<ListView>(R.id.widget_results).adapter.count)
        assertNull(shadowOf(activity).nextStartedActivity)
        controller.pause().stop().destroy()
    }

    @Test fun deviceLockedNativeSearchNeverShowsCachedTitles() {
        shadowOf(context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setKeyguardLocked(true)
        val controller = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
        assertEquals(0, controller.get().findViewById<ListView>(R.id.widget_results).adapter.count)
        assertNull(shadowOf(controller.get()).nextStartedActivity)
        controller.pause().stop().destroy()
        shadowOf(context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setKeyguardLocked(false)
    }
}