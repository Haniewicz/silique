package pl.silique.app

import android.content.Context
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.TextView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.robolectric.Shadows.shadowOf
import pl.silique.app.widgets.*
import javax.crypto.KeyGenerator
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import pl.silique.app.widgets.WidgetRenderer

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], qualifiers = "pl", shadows = [SiliqueLanguageTest.LanguageWidgetManager::class])
class SiliqueLanguageTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()

    @Before fun seed() {
        WidgetRuntime.screenOff = false
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        WidgetRuntime.storeFactory = { SnapshotStore(it) { key } }
        WidgetRuntime.store(context).write(WidgetSnapshot(listOf(
            WidgetNote("note-1", "vault-1", "", "Original preview", "orchid", "Plants", "2026-10-23T10:00:00Z"),
            WidgetNote("note-2", "vault-1", "Bez tytułu", "Original preview", "", "Plants", "2026-10-23T10:00:00Z")
        ), "vault-1"))
    }

    @Test fun allExistingWidgetsAndUntitledRowsRefreshImmediatelyWithoutChangingNoteData() {
        val messenger = Messenger()
        bridge(messenger)
        val manager = shadowOf(android.appwidget.AppWidgetManager.getInstance(context))
        val newId = manager.createWidget(NewNoteWidget::class.java, R.layout.widget_action)
        val searchId = manager.createWidget(SearchWidget::class.java, R.layout.widget_action)
        val journalId = manager.createWidget(JournalWidget::class.java, R.layout.widget_action)
        val notesId = manager.createWidget(NoteListWidget::class.java, R.layout.widget_notes)
        fun label(id: Int, viewId: Int) = manager.getViewFor(id).findViewById<TextView>(viewId).text.toString()
        assertEquals("⌕ Search notes", label(searchId, R.id.widget_action))
        assertEquals("✎ Journal entry", label(journalId, R.id.widget_action))
        assertEquals("Silique · Notes ›", label(notesId, R.id.widget_recent))
        val factory = NotesRemoteViewsService.Factory(context).apply { onCreate() }
        fun title(index: Int) = factory.getViewAt(index)!!.apply(context, FrameLayout(context)).findViewById<TextView>(R.id.widget_title).text.toString()
        assertEquals("Untitled", title(0))
        assertEquals("Bez tytułu", title(1)) // A stored title is data, never translated.
        val original = WidgetRuntime.store(context).read()
        messenger.call("setLanguage", mapOf("languageCode" to "pl"))
        assertEquals("+ Nowa notatka", label(newId, R.id.widget_action))
        assertEquals("⌕ Szukaj notatek", label(searchId, R.id.widget_action))
        assertEquals("✎ Wpis do dziennika", label(journalId, R.id.widget_action))
        assertEquals("Silique · Notatki ›", label(notesId, R.id.widget_recent))
        assertEquals("Brak notatek", label(notesId, R.id.widget_empty))
        assertEquals("Nowa notatka Silique", manager.getViewFor(newId).findViewById<TextView>(R.id.widget_action).contentDescription.toString())
        assertEquals("Bez tytułu", title(0))
        messenger.call("setLanguage", mapOf("languageCode" to "en"))
        assertEquals("No notes", label(notesId, R.id.widget_empty))
        assertEquals("Untitled", title(0))
        assertEquals(original, WidgetRuntime.store(context).read())
        factory.onDestroy()
    }

    @Test fun languageRefreshOfExistingWidgetsNeverOpensKeyOrChangesSnapshotContentAndTargets() {
        val messenger = Messenger()
        bridge(messenger)
        val manager = shadowOf(android.appwidget.AppWidgetManager.getInstance(context))
        val newId = manager.createWidget(NewNoteWidget::class.java, R.layout.widget_action)
        val journalId = manager.createWidget(JournalWidget::class.java, R.layout.widget_action)
        val searchId = manager.createWidget(SearchWidget::class.java, R.layout.widget_action)
        val notesId = manager.createWidget(NoteListWidget::class.java, R.layout.widget_notes)
        val app = shadowOf(context as android.app.Application)
        fun target(id: Int): android.content.Intent {
            manager.getViewFor(id).findViewById<android.view.View>(R.id.widget_action).performClick()
            return app.nextStartedActivity
        }
        val originalTargets = listOf(newId, journalId, searchId).associateWith { target(it) }
        val list = manager.getViewFor(notesId).findViewById<android.widget.ListView>(R.id.widget_notes)
        val content = android.widget.ArrayAdapter(context, android.R.layout.simple_list_item_1, listOf("Original preview"))
        list.adapter = content
        // Presentation refresh must never make a previously masked collection visible.
        list.visibility = android.view.View.GONE
        val store = WidgetRuntime.store(context)
        val encrypted = store.file.readBytes()
        val existingFiles = context.noBackupFilesDir.walkTopDown().map { it.relativeTo(context.noBackupFilesDir).path }.toSet()
        var keyReads = 0
        var storeOpens = 0
        val originalFactory = WidgetRuntime.storeFactory
        WidgetRuntime.storeFactory = {
            storeOpens++
            SnapshotStore(it) { keyReads++; throw IllegalStateException("Keystore unavailable during language change") }
        }
        try {
            assertNull(messenger.call("setLanguage", mapOf("languageCode" to "pl")))
            assertEquals("Language refresh must not read the widget key", 0, keyReads)
            assertEquals("Language refresh must not initialize snapshot storage", 0, storeOpens)
            assertEquals("Language refresh must not ask collection factories to decrypt", 0, (manager as LanguageWidgetManager).dataNotifications)
            assertTrue("Language refresh must not remove the encrypted snapshot", store.file.exists())
            assertArrayEquals(encrypted, store.file.readBytes())
            assertEquals(existingFiles, context.noBackupFilesDir.walkTopDown().map { it.relativeTo(context.noBackupFilesDir).path }.toSet())
            assertNull("Language refresh must not launch Flutter/vault initialization", app.nextStartedActivity)
            assertEquals("+ Nowa notatka", manager.getViewFor(newId).findViewById<TextView>(R.id.widget_action).text.toString())
            assertEquals("✎ Wpis do dziennika", manager.getViewFor(journalId).findViewById<TextView>(R.id.widget_action).text.toString())
            assertEquals("⌕ Szukaj notatek", manager.getViewFor(searchId).findViewById<TextView>(R.id.widget_action).text.toString())
            assertEquals("Silique · Notatki ›", manager.getViewFor(notesId).findViewById<TextView>(R.id.widget_recent).text.toString())
            assertEquals("Brak notatek", manager.getViewFor(notesId).findViewById<TextView>(R.id.widget_empty).text.toString())
            assertEquals("Nowa notatka Silique", manager.getViewFor(newId).findViewById<TextView>(R.id.widget_action).contentDescription.toString())
            assertSame(content, manager.getViewFor(notesId).findViewById<android.widget.ListView>(R.id.widget_notes).adapter)
            assertEquals(android.view.View.GONE, manager.getViewFor(notesId).findViewById<android.view.View>(R.id.widget_notes).visibility)
            originalTargets.forEach { (id, before) ->
                val after = target(id)
                assertTrue("The existing PendingIntent must retain its identity", before.filterEquals(after))
                assertEquals(before.getStringExtra("vaultId"), after.getStringExtra("vaultId"))
                assertEquals(before.getStringExtra("action"), after.getStringExtra("action"))
            }
        } finally { WidgetRuntime.storeFactory = originalFactory }
    }

    @Test fun openSearchLanguageRefreshOnlyRelabelsCurrentRowsWithoutReadingKeyOrResettingQuery() {
        val messenger = Messenger()
        bridge(messenger)
        val controller = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
        val activity = controller.get()
        val query = activity.findViewById<EditText>(R.id.widget_query)
        val results = activity.findViewById<android.widget.ListView>(R.id.widget_results)
        query.setText("orchid")
        query.setSelection(2, 4)
        assertEquals(1, results.adapter.count)
        assertEquals("Untitled", results.adapter.getItem(0))
        val store = WidgetRuntime.store(context)
        val encrypted = store.file.readBytes()
        val presentation = results.adapter
        val originalFactory = WidgetRuntime.storeFactory
        var keyReads = 0
        WidgetRuntime.storeFactory = { SnapshotStore(it) { keyReads++; throw IllegalStateException("No key access for language") } }
        try {
            assertNull(messenger.call("setLanguage", mapOf("languageCode" to "pl")))
            assertEquals("Language must not invoke search data listeners", 0, keyReads)
            assertEquals("Szukaj notatek", query.hint.toString())
            assertEquals("Bez tytułu", results.adapter.getItem(0))
            assertSame("Language refresh preserves the current results adapter", presentation, results.adapter)
            assertEquals("orchid", query.text.toString())
            assertEquals(2, query.selectionStart)
            assertEquals(4, query.selectionEnd)
            assertSame(query, activity.findViewById<EditText>(R.id.widget_query))
            assertNull(shadowOf(activity).nextStartedActivity)
            assertArrayEquals(encrypted, store.file.readBytes())
            assertNull(messenger.call("setLanguage", mapOf("languageCode" to "en")))
            assertEquals("Search notes", query.hint.toString())
            assertEquals("Untitled", results.adapter.getItem(0))
            assertEquals(0, keyReads)
        } finally {
            WidgetRuntime.storeFactory = originalFactory
            controller.pause().stop().destroy()
        }
    }

    // Robolectric's stock manager omits partial updates. Model Android's merge
    // into the last full RemoteViews; all actions/inflation/clicks remain real.
    @org.robolectric.annotation.Implements(android.appwidget.AppWidgetManager::class)
    class LanguageWidgetManager : org.robolectric.shadows.ShadowAppWidgetManager() {
        var dataNotifications = 0
        @org.robolectric.annotation.Implementation
        protected fun partiallyUpdateAppWidget(id: Int, views: android.widget.RemoteViews) {
            val widgets: Map<Int, Any> = org.robolectric.util.ReflectionHelpers.getField(this, "widgetInfos")
            val previous: android.widget.RemoteViews = org.robolectric.util.ReflectionHelpers.getField(widgets.getValue(id), "lastRemoteViews")
            org.robolectric.util.ReflectionHelpers.callInstanceMethod<Void>(previous, "mergeRemoteViews",
                org.robolectric.util.ReflectionHelpers.ClassParameter.from(android.widget.RemoteViews::class.java, views))
            val context: Context = org.robolectric.util.ReflectionHelpers.getField(this, "context")
            views.reapply(context, getViewFor(id))
        }
        @org.robolectric.annotation.Implementation
        protected fun notifyAppWidgetViewDataChanged(id: Int, viewId: Int) { dataNotifications++ }
    }

    private class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }
        fun call(method: String, arguments: Any? = null): Any? {
            val handler = handlers["silique/language"]
            assertNotNull("Language MethodChannel must be registered", handler)
            var reply: ByteBuffer? = null
            handler!!.onMessage(StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, arguments)).apply { flip() }) { reply = it }
            return reply?.let { StandardMethodCodec.INSTANCE.decodeEnvelope(it.apply { flip() }) }
        }
    }

    private fun bridge(messenger: Messenger): Any {
        val type = runCatching { Class.forName("pl.silique.app.SiliqueLanguageBridge") }.getOrNull()
        assertNotNull("A native language bridge must expose the real MethodChannel", type)
        return type!!.getConstructor(Context::class.java, BinaryMessenger::class.java).newInstance(context, messenger)
    }

    @Test fun channelPersistsPolishForNewActivityWithoutRecreatingOpenSearch() {
        val messenger = Messenger()
        bridge(messenger)
        assertEquals("en", messenger.call("getLanguage"))
        val controller = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
        val activity = controller.get()
        val query = activity.findViewById<EditText>(R.id.widget_query)
        try {
            assertNull(messenger.call("setLanguage", mapOf("languageCode" to "pl")))
            assertEquals("pl", messenger.call("getLanguage"))
            assertFalse(activity.isFinishing)
            assertSame(query, activity.findViewById<EditText>(R.id.widget_query))
            assertEquals("Szukaj notatek", query.hint.toString())
            val freshMessenger = Messenger()
            bridge(freshMessenger)
            assertEquals("pl", freshMessenger.call("getLanguage"))
            val fresh = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
            try {
                assertEquals("Szukaj notatek", fresh.get().findViewById<EditText>(R.id.widget_query).hint.toString())
                assertEquals("pl", fresh.get().resources.configuration.locales[0].language)
            } finally { fresh.pause().stop().destroy() }
        } finally { controller.pause().stop().destroy() }
    }

    @Test fun englishIsDefaultEvenOnPolishDeviceForWidgetAndInflatedSearch() {
        val view = WidgetRenderer.newNote(context, 42).apply(context, FrameLayout(context))
        assertEquals("+ New note", view.findViewById<TextView>(R.id.widget_action).text.toString())
        val controller = Robolectric.buildActivity(WidgetSearchActivity::class.java).setup()
        try {
            assertEquals("Search notes", controller.get().findViewById<EditText>(R.id.widget_query).hint.toString())
            assertEquals("en", controller.get().resources.configuration.locales[0].language)
        } finally { controller.pause().stop().destroy() }
    }
}
