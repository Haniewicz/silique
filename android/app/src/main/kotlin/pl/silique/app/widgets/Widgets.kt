package pl.silique.app.widgets

import android.app.KeyguardManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import pl.silique.app.R

/** What the launcher can currently show: a real list, the locked mask, or an unreadable index. */
sealed class WidgetContent {
    object Locked : WidgetContent()
    class Ready(val notes: List<WidgetNote>, val lastVaultId: String?) : WidgetContent()
    object Unavailable : WidgetContent()
}

object WidgetRuntime {
    var storeFactory: (Context) -> SnapshotStore = { SnapshotStore(it) }
    val actions = WidgetActionQueue()
    private val listeners = mutableSetOf<() -> Unit>()
    private val languageListeners = mutableSetOf<() -> Unit>()
    var revocationVersion = 0L
        private set
    fun store(context: Context) = storeFactory(context.applicationContext)

    /**
     * Masked when the keyguard is showing or the screen is not interactive.
     *
     * The screen state is read from the system every time instead of being
     * remembered from ACTION_SCREEN_OFF: a remembered flag goes stale when the
     * process is frozen in the background and misses ACTION_USER_PRESENT, which
     * used to keep the launcher masked for the rest of that process's lifetime.
     */
    fun locked(context: Context): Boolean =
        reason(context) != null

    /** Which live signal masks the launcher right now, for diagnostics. */
    fun reason(context: Context): String? {
        if ((context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked) return "keyguard"
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return if (power.isInteractive) null else "screen_off"
    }
    /**
     * One read per render. A genuinely empty index ([SnapshotRead.Missing]) stays
     * distinct from an index that cannot be read right now ([SnapshotRead.Unavailable]),
     * so the launcher never paints "no notes" for a transient Keystore or I/O failure.
     */
    fun content(context: Context): WidgetContent {
        if (locked(context)) return WidgetContent.Locked
        return when (val outcome = store(context).readOutcome()) {
            is SnapshotRead.Ok -> WidgetContent.Ready(outcome.snapshot.notes, outcome.snapshot.lastVaultId)
            SnapshotRead.Missing -> WidgetContent.Ready(emptyList(), null)
            is SnapshotRead.Unavailable -> WidgetContent.Unavailable
            SnapshotRead.Corrupt -> WidgetContent.Unavailable
        }
    }
    fun snapshot(context: Context): WidgetSnapshot = when (val content = content(context)) {
        is WidgetContent.Ready -> WidgetSnapshot(content.notes, content.lastVaultId)
        else -> WidgetSnapshot()
    }
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
                manager.partiallyUpdateAppWidget(id, WidgetRenderer.labels(context, type, id))
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
        // A render that lands locked or unreadable must not stay wrong until the
        // app is next opened: arm the bounded retry poll after every render.
        WidgetRefreshReceiver().onRendered(context)
    }
}

object WidgetRenderer {
    /** One launcher slot is roughly 40–80 dp; two slots are 110+ dp. */
    private const val COMPACT_BELOW_DP = 100

    /** Compact only for a positive width below two slots; 0/absent means full (back-compat). */
    private fun isCompact(base: Context, id: Int, minWidthDp: Int?): Boolean {
        val width = minWidthDp ?: AppWidgetManager.getInstance(base)
            .getAppWidgetOptions(id)
            .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
        return width > 0 && width < COMPACT_BELOW_DP
    }

    private fun actionView(context: Context, compact: Boolean, label: Int, description: Int, pending: PendingIntent): RemoteViews =
        RemoteViews(context.packageName, if (compact) R.layout.widget_action_compact else R.layout.widget_action).apply {
            setTextViewText(R.id.widget_action, context.getString(label))
            setContentDescription(R.id.widget_action, context.getString(description))
            setOnClickPendingIntent(R.id.widget_action, pending)
        }

    fun labels(base: Context, type: Class<*>, id: Int): RemoteViews {
        val context = pl.silique.app.SiliqueLanguage.context(base)
        if (type == NoteListWidget::class.java) {
            return RemoteViews(context.packageName, R.layout.widget_notes).apply {
                setTextViewText(R.id.widget_recent, context.getString(if (WidgetRuntime.locked(context)) R.string.widget_notes_locked else R.string.widget_notes_header))
                setTextViewText(R.id.widget_empty, context.getString(R.string.widget_notes_empty))
                setContentDescription(R.id.widget_surface, context.getString(R.string.widget_notes_description))
            }
        }
        val compact = isCompact(base, id, null)
        val (label, description) = when (type) {
            NewNoteWidget::class.java -> (if (compact) R.string.widget_new_note_compact else R.string.widget_new_note) to R.string.widget_new_note_description
            JournalWidget::class.java -> (if (compact) R.string.widget_journal_compact else R.string.widget_journal_action) to R.string.widget_journal_description
            SearchWidget::class.java -> (if (compact) R.string.widget_search_compact else R.string.widget_search_action) to R.string.widget_search_description
            else -> error("Unknown widget provider")
        }
        return RemoteViews(context.packageName, if (compact) R.layout.widget_action_compact else R.layout.widget_action).apply {
            setTextViewText(R.id.widget_action, context.getString(label))
            setContentDescription(R.id.widget_action, context.getString(description))
        }
    }
    fun list(base: Context, id: Int): RemoteViews {
        val context = pl.silique.app.SiliqueLanguage.context(base)
        val content = WidgetRuntime.content(base)
        WidgetDiagnostics.record(base, "render",
            "widget=${id} type=list state=${stateName(content)} lock=${WidgetRuntime.reason(base) ?: "none"}")
        return RemoteViews(context.packageName, R.layout.widget_notes).apply {
            // RemoteViews is inflated by the launcher's (possibly different) locale.
            // Override every localized XML value before handing it to that host.
            setTextViewText(R.id.widget_recent, context.getString(if (content is WidgetContent.Locked) R.string.widget_notes_locked else R.string.widget_notes_header))
            setContentDescription(R.id.widget_surface, context.getString(R.string.widget_notes_description))
            setOnClickPendingIntent(R.id.widget_recent, WidgetIntents.searchPending(context, id))
            when (content) {
                is WidgetContent.Ready -> {
                    setViewVisibility(R.id.widget_notes, View.VISIBLE)
                    setTextViewText(R.id.widget_empty, context.getString(R.string.widget_notes_empty))
                    setRemoteAdapter(R.id.widget_notes, Intent(context, NotesRemoteViewsService::class.java).apply {
                        putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                        data = Uri.parse("silique-widget://collection/$id")
                    })
                    setEmptyView(R.id.widget_notes, R.id.widget_empty)
                    setPendingIntentTemplate(R.id.widget_notes, WidgetIntents.collectionPending(context, id))
                }
                WidgetContent.Locked -> {
                    // Never show an empty-list hint for a state that is only masked.
                    setViewVisibility(R.id.widget_notes, View.GONE)
                    setTextViewText(R.id.widget_empty, "")
                    setViewVisibility(R.id.widget_empty, View.GONE)
                }
                WidgetContent.Unavailable -> {
                    setViewVisibility(R.id.widget_notes, View.GONE)
                    setTextViewText(R.id.widget_empty, context.getString(R.string.widget_notes_unavailable))
                    setViewVisibility(R.id.widget_empty, View.VISIBLE)
                }
            }
        }
    }
    private fun stateName(content: WidgetContent): String = when (content) {
        is WidgetContent.Ready -> "notes=${content.notes.size}"
        WidgetContent.Locked -> "locked"
        WidgetContent.Unavailable -> "unavailable"
    }
    fun newNote(base: Context, id: Int): RemoteViews = newNote(base, id, null)

    fun newNote(base: Context, id: Int, minWidthDp: Int?): RemoteViews {
        val context = pl.silique.app.SiliqueLanguage.context(base)
        // Decrypt once; the compact variant reuses the same vault target and intent.
        val lastVaultId = (WidgetRuntime.content(base) as? WidgetContent.Ready)?.lastVaultId
        val compact = isCompact(base, id, minWidthDp)
        return actionView(
            context, compact,
            if (compact) R.string.widget_new_note_compact else R.string.widget_new_note,
            R.string.widget_new_note_description,
            WidgetIntents.newPending(context, lastVaultId, id)
        )
    }

    fun search(base: Context, id: Int): RemoteViews = search(base, id, null)

    fun search(base: Context, id: Int, minWidthDp: Int?): RemoteViews {
        val context = pl.silique.app.SiliqueLanguage.context(base)
        val compact = isCompact(base, id, minWidthDp)
        return actionView(
            context, compact,
            if (compact) R.string.widget_search_compact else R.string.widget_search_action,
            R.string.widget_search_description,
            WidgetIntents.searchPending(context, id)
        )
    }

    fun journal(base: Context, id: Int): RemoteViews = journal(base, id, null)

    fun journal(base: Context, id: Int, minWidthDp: Int?): RemoteViews {
        val context = pl.silique.app.SiliqueLanguage.context(base)
        val lastVaultId = (WidgetRuntime.content(base) as? WidgetContent.Ready)?.lastVaultId
        val compact = isCompact(base, id, minWidthDp)
        return actionView(
            context, compact,
            if (compact) R.string.widget_journal_compact else R.string.widget_journal_action,
            R.string.widget_journal_description,
            WidgetIntents.journalPending(context, lastVaultId, id)
        )
    }
}

class NoteListWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { manager.updateAppWidget(it, WidgetRenderer.list(context, it)) }; WidgetRefreshReceiver().onRendered(context) }
}
class NewNoteWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { manager.updateAppWidget(it, WidgetRenderer.newNote(context, it)) }; WidgetRefreshReceiver().onRendered(context) }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, newOptions: Bundle) {
        manager.updateAppWidget(id, WidgetRenderer.newNote(context, id, newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)))
        WidgetRefreshReceiver().onRendered(context)
    }
}
class SearchWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { manager.updateAppWidget(it, WidgetRenderer.search(context, it)) }; WidgetRefreshReceiver().onRendered(context) }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, newOptions: Bundle) {
        manager.updateAppWidget(id, WidgetRenderer.search(context, id, newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)))
        WidgetRefreshReceiver().onRendered(context)
    }
}
class JournalWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { manager.updateAppWidget(it, WidgetRenderer.journal(context, it)) }; WidgetRefreshReceiver().onRendered(context) }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, newOptions: Bundle) {
        manager.updateAppWidget(id, WidgetRenderer.journal(context, id, newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)))
        WidgetRefreshReceiver().onRendered(context)
    }
}
class NotesRemoteViewsService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = Factory(applicationContext)
    class Factory(private val context: Context) : RemoteViewsFactory {
        private var notes: List<WidgetNote> = emptyList()
        override fun onCreate() { onDataSetChanged() }
        override fun onDataSetChanged() { notes = readyNotes() }
        override fun onDestroy() { notes = emptyList() }
        override fun getCount() = readyNotes().size
        private fun readyNotes() =
            (WidgetRuntime.content(context) as? WidgetContent.Ready)?.notes ?: emptyList()
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
