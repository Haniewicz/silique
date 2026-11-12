package pl.silique.app.widgets

import android.app.KeyguardManager
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import pl.silique.app.R

object WidgetRuntime {
    var storeFactory: (Context) -> SnapshotStore = { SnapshotStore(it) }
    val actions = WidgetActionQueue()
    private val listeners = mutableSetOf<() -> Unit>()
    private val languageListeners = mutableSetOf<() -> Unit>()
    var screenOff = false
    var revocationVersion = 0L
        private set
    fun store(context: Context) = storeFactory(context.applicationContext)
    fun locked(context: Context) = screenOff || (context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked
    fun snapshot(context: Context) = if (locked(context)) WidgetSnapshot() else store(context).read()
    fun listen(listener: () -> Unit) { listeners.add(listener) }
    fun unlisten(listener: () -> Unit) { listeners.remove(listener) }
    fun listenLanguage(listener: () -> Unit) { languageListeners.add(listener) }
    fun unlistenLanguage(listener: () -> Unit) { languageListeners.remove(listener) }
    fun publish(context: Context, snapshot: WidgetSnapshot) { store(context).write(snapshot); changed(context) }
    fun clear(context: Context) { store(context).clear(); changed(context) }
    fun removeVault(context: Context, id: String) {
        store(context).removeVault(id)
        actions.removeVault(id)
        revocationVersion++
        changed(context)
    }
    fun languageChanged(context: Context) {
        languageListeners.toList().forEach { it() }
        val manager = AppWidgetManager.getInstance(context)
        for (type in listOf(NoteListWidget::class.java, NewNoteWidget::class.java, JournalWidget::class.java, SearchWidget::class.java)) {
            manager.getAppWidgetIds(ComponentName(context, type)).forEach { id ->
                // Merge labels only: keep content, masking, adapters and existing vault targets.
                // Never notify collection data/listeners here: both may decrypt snapshots.
                manager.partiallyUpdateAppWidget(id, WidgetRenderer.labels(context, type))
            }
        }
    }
    fun changed(context: Context) {
        listeners.toList().forEach { it() }
        val manager = AppWidgetManager.getInstance(context)
        for (type in listOf(NoteListWidget::class.java, NewNoteWidget::class.java, JournalWidget::class.java, SearchWidget::class.java)) {
            manager.getAppWidgetIds(ComponentName(context, type)).forEach { id ->
                val view = when (type) {
                    NoteListWidget::class.java -> WidgetRenderer.list(context, id)
                    NewNoteWidget::class.java -> WidgetRenderer.newNote(context, id)
                    JournalWidget::class.java -> WidgetRenderer.journal(context, id)
                    else -> WidgetRenderer.search(context, id)
                }
                manager.updateAppWidget(id, view)
                if (type == NoteListWidget::class.java) manager.notifyAppWidgetViewDataChanged(id, R.id.widget_notes)
            }
        }
    }
}

object WidgetRenderer {
    fun labels(base: Context, type: Class<*>): RemoteViews {
        val context = pl.silique.app.SiliqueLanguage.context(base)
        if (type == NoteListWidget::class.java) {
            return RemoteViews(context.packageName, R.layout.widget_notes).apply {
                setTextViewText(R.id.widget_recent, context.getString(if (WidgetRuntime.locked(context)) R.string.widget_notes_locked else R.string.widget_notes_header))
                setTextViewText(R.id.widget_empty, context.getString(R.string.widget_notes_empty))
                setContentDescription(R.id.widget_surface, context.getString(R.string.widget_notes_description))
            }
        }
        val (label, description) = when (type) {
            NewNoteWidget::class.java -> R.string.widget_new_note to R.string.widget_new_note_description
            JournalWidget::class.java -> R.string.widget_journal_action to R.string.widget_journal_description
            SearchWidget::class.java -> R.string.widget_search_action to R.string.widget_search_description
            else -> error("Unknown widget provider")
        }
        return RemoteViews(context.packageName, R.layout.widget_action).apply {
            setTextViewText(R.id.widget_action, context.getString(label))
            setContentDescription(R.id.widget_action, context.getString(description))
        }
    }
    fun list(base: Context, id: Int): RemoteViews {
        val context = pl.silique.app.SiliqueLanguage.context(base)
        return RemoteViews(context.packageName, R.layout.widget_notes).apply {
            val locked = WidgetRuntime.locked(context)
            setTextViewText(R.id.widget_recent, context.getString(if (locked) R.string.widget_notes_locked else R.string.widget_notes_header))
            // RemoteViews is inflated by the launcher's (possibly different) locale.
            // Override every localized XML value before handing it to that host.
            setTextViewText(R.id.widget_empty, context.getString(R.string.widget_notes_empty))
            setContentDescription(R.id.widget_surface, context.getString(R.string.widget_notes_description))
            setViewVisibility(R.id.widget_notes, if (locked) View.GONE else View.VISIBLE)
            setRemoteAdapter(R.id.widget_notes, Intent(context, NotesRemoteViewsService::class.java).apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                data = Uri.parse("silique-widget://collection/$id")
            })
            setEmptyView(R.id.widget_notes, R.id.widget_empty)
            setOnClickPendingIntent(R.id.widget_recent, WidgetIntents.searchPending(context, id))
            setPendingIntentTemplate(R.id.widget_notes, WidgetIntents.collectionPending(context, id))
        }
    }
    fun newNote(base: Context, id: Int): RemoteViews {
        val context = pl.silique.app.SiliqueLanguage.context(base)
        return RemoteViews(context.packageName, R.layout.widget_action).apply {
            setTextViewText(R.id.widget_action, context.getString(R.string.widget_new_note))
            setContentDescription(R.id.widget_action, context.getString(R.string.widget_new_note_description))
            setOnClickPendingIntent(R.id.widget_action, WidgetIntents.newPending(context, WidgetRuntime.snapshot(context).lastVaultId, id))
        }
    }
    fun search(base: Context, id: Int): RemoteViews {
        val context = pl.silique.app.SiliqueLanguage.context(base)
        return RemoteViews(context.packageName, R.layout.widget_action).apply {
            setTextViewText(R.id.widget_action, context.getString(R.string.widget_search_action))
            setContentDescription(R.id.widget_action, context.getString(R.string.widget_search_description))
            setOnClickPendingIntent(R.id.widget_action, WidgetIntents.searchPending(context, id))
        }
    }
    fun journal(base: Context, id: Int): RemoteViews {
        val context = pl.silique.app.SiliqueLanguage.context(base)
        return RemoteViews(context.packageName, R.layout.widget_action).apply {
            setTextViewText(R.id.widget_action, context.getString(R.string.widget_journal_action))
            setContentDescription(R.id.widget_action, context.getString(R.string.widget_journal_description))
            setOnClickPendingIntent(R.id.widget_action, WidgetIntents.journalPending(context, WidgetRuntime.snapshot(context).lastVaultId, id))
        }
    }
}

class NoteListWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { manager.updateAppWidget(it, WidgetRenderer.list(context, it)) }; WidgetRefreshReceiver().onRendered(context) }
}
class NewNoteWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { manager.updateAppWidget(it, WidgetRenderer.newNote(context, it)) }; WidgetRefreshReceiver().onRendered(context) }
}
class SearchWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { manager.updateAppWidget(it, WidgetRenderer.search(context, it)) }; WidgetRefreshReceiver().onRendered(context) }
}
class JournalWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { manager.updateAppWidget(it, WidgetRenderer.journal(context, it)) }; WidgetRefreshReceiver().onRendered(context) }
}
class NotesRemoteViewsService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = Factory(applicationContext)
    class Factory(private val context: Context) : RemoteViewsFactory {
        private var notes: List<WidgetNote> = emptyList()
        override fun onCreate() { onDataSetChanged() }
        override fun onDataSetChanged() { notes = WidgetRuntime.snapshot(context).notes }
        override fun onDestroy() { notes = emptyList() }
        override fun getCount() = WidgetRuntime.snapshot(context).notes.size
        override fun getViewAt(position: Int): RemoteViews? {
            if (WidgetRuntime.locked(context)) return null
            // Re-read to prevent an invalidated factory retaining a revoked row.
            val fresh = WidgetRuntime.snapshot(context).notes
            val note = notes.getOrNull(position)?.let { old -> fresh.find { it.id == old.id && it.vaultId == old.vaultId } } ?: return null
            return RemoteViews(context.packageName, R.layout.widget_row).apply {
                setTextViewText(R.id.widget_title, note.title.ifEmpty { pl.silique.app.SiliqueLanguage.text(context, R.string.widget_untitled) })
                setTextViewText(R.id.widget_preview, note.preview)
                setOnClickFillInIntent(R.id.widget_row, Intent().apply {
                    putExtra("vaultId", note.vaultId)
                    putExtra("noteId", note.id)
                })
            }
        }
        override fun getLoadingView(): RemoteViews? = null
        override fun getViewTypeCount() = 1
        override fun getItemId(position: Int) = position.toLong()
        override fun hasStableIds() = false
    }
}
