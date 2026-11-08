package pl.silique.app.widgets

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import pl.silique.app.MainActivity
import pl.silique.app.WidgetActionActivity
import pl.silique.app.WidgetSearchActivity
import java.util.UUID

object WidgetIntents {
    const val ACTION = "pl.silique.app.WIDGET_ACTION"
    private fun actionIntent(context: Context, action: String, vault: String?, note: String?, target: Class<*>): Intent = Intent(context, target).apply {
        this.action = ACTION
        data = Uri.Builder().scheme("silique-widget").authority("action").appendPath(UUID.randomUUID().toString()).build()
        putExtra("action", action)
        if (vault != null) putExtra("vaultId", vault)
        if (note != null) putExtra("noteId", note)
    }
    fun noteIntent(context: Context, vault: String, note: String) = actionIntent(context, "openNote", vault, note, MainActivity::class.java)
    fun newIntent(context: Context, vault: String?) = actionIntent(context, "newNote", vault, null, MainActivity::class.java)
    fun journalIntent(context: Context, vault: String?) = actionIntent(context, "journal", vault, null, MainActivity::class.java)
    fun notePending(context: Context, vault: String, note: String, widgetId: Int): PendingIntent = PendingIntent.getActivity(context, widgetId,
        actionIntent(context, "openNote", vault, note, WidgetActionActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    fun newPending(context: Context, vault: String?, widgetId: Int): PendingIntent = PendingIntent.getActivity(context, widgetId,
        actionIntent(context, "newNote", vault, null, WidgetActionActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    fun searchPending(context: Context, widgetId: Int): PendingIntent = PendingIntent.getActivity(context, widgetId,
        Intent(context, WidgetSearchActivity::class.java).setData(Uri.parse("silique-widget://search/$widgetId")), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    fun journalPending(context: Context, vault: String?, widgetId: Int): PendingIntent = PendingIntent.getActivity(context, widgetId,
        actionIntent(context, "journal", vault, null, WidgetActionActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    // Android collection rows require fill-in extras. Only this explicit private
    // template is mutable; the trampoline revalidates both IDs against the live
    // eligible snapshot before opening Flutter. All standalone taps are immutable.
    fun collectionPending(context: Context, widgetId: Int): PendingIntent = PendingIntent.getActivity(context, widgetId,
        Intent(context, WidgetActionActivity::class.java).apply {
            action = ACTION
            data = Uri.parse("silique-widget://collection-action/$widgetId")
            putExtra("action", "openNote")
        }, PendingIntent.FLAG_UPDATE_CURRENT or if (android.os.Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
}

class WidgetActionQueue {
    private val pending = java.util.ArrayDeque<Map<String, Any>>()
    private val seen = mutableSetOf<String>()
    var onAvailable: (() -> Unit)? = null
    @Synchronized fun accept(intent: Intent?): Boolean {
        if (intent?.action != WidgetIntents.ACTION) return false
        val request = intent.data ?: return false
        if (request.scheme != "silique-widget" || request.authority != "action" || request.pathSegments.size != 1) return false
        val id = request.lastPathSegment ?: return false
        if (!validWidgetId(id) || id in seen) return false
        val action = intent.getStringExtra("action") ?: return false
        val vault = intent.getStringExtra("vaultId")
        val note = intent.getStringExtra("noteId")
        if (vault != null && !validWidgetId(vault)) return false
        if (action == "openNote") { if (!validWidgetId(vault) || !validWidgetId(note)) return false }
        else if (action !in listOf("newNote", "journal") || note != null) return false
        val value = mutableMapOf<String, Any>("action" to action, "requestId" to id)
        if (vault != null) value["vaultId"] = vault
        if (note != null) value["noteId"] = note
        seen.add(id); pending.add(value); onAvailable?.invoke()
        return true
    }
    @Synchronized fun take(): Map<String, Any>? = pending.pollFirst()
    @Synchronized fun removeVault(id: String) { pending.removeAll { it["vaultId"] == id } }
}
