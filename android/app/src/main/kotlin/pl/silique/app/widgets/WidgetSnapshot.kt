package pl.silique.app.widgets

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.util.Locale

internal fun validWidgetId(value: String?) = value != null && value.matches(Regex("[A-Za-z0-9_-]{1,200}"))

data class WidgetNote(val id: String, val vaultId: String, val title: String, val preview: String,
    val searchText: String, val folder: String, val updatedAt: String)

data class WidgetSnapshot(val notes: List<WidgetNote> = emptyList(), val lastVaultId: String? = null) {
    fun search(query: String): List<WidgetNote> {
        val terms = query.lowercase(Locale.ROOT).split(Regex("\\s+")).filter { it.isNotEmpty() }
        return notes.filter { note ->
            val text = "${note.title}\n${note.searchText}\n${note.folder}".lowercase(Locale.ROOT)
            terms.all { text.contains(it) }
        }
    }
    fun encode(): ByteArray = ByteArrayOutputStream().also { bytes ->
        DataOutputStream(bytes).use { out ->
            out.writeInt(1)
            fun text(value: String) { val raw = value.toByteArray(Charsets.UTF_8); out.writeInt(raw.size); out.write(raw) }
            text(lastVaultId ?: "")
            out.writeInt(notes.size)
            notes.forEach { n -> listOf(n.id, n.vaultId, n.title, n.preview, n.searchText, n.folder, n.updatedAt).forEach { text(it) } }
        }
    }.toByteArray()
    companion object {
        fun fromMap(map: Map<*, *>): WidgetSnapshot {
            require(map["schema"] == 1)
            val last = map["lastVaultId"]
            require(last == null || last is String && validWidgetId(last))
            val rows = map["notes"] as? List<*> ?: throw IllegalArgumentException("Invalid widget snapshot")
            require(rows.size <= 10000)
            val notes = rows.map { raw ->
                val row = raw as? Map<*, *> ?: throw IllegalArgumentException("Invalid widget row")
                for (flag in listOf("hidden", "deleted", "passwordProtected")) require(row[flag] == null || row[flag] == false)
                fun text(key: String) = row[key] as? String ?: throw IllegalArgumentException("Invalid widget field")
                val id = text("id"); val vault = text("vaultId")
                require(validWidgetId(id) && validWidgetId(vault))
                WidgetNote(id, vault, text("title").take(500), text("preview").take(240), text("searchText"), text("folder").take(500), text("updatedAt"))
            }
            require(notes.map { it.id }.toSet().size == notes.size)
            return WidgetSnapshot(notes, last)
        }
        fun decode(bytes: ByteArray): WidgetSnapshot = DataInputStream(ByteArrayInputStream(bytes)).use { input ->
            require(input.readInt() == 1)
            fun text(): String { val length = input.readInt(); require(length in 0..(16 * 1024 * 1024) && length <= input.available()); return ByteArray(length).also { input.readFully(it) }.toString(Charsets.UTF_8) }
            val last = text().ifEmpty { null }
            val count = input.readInt(); require(count in 0..10000)
            val rows = (0 until count).map { listOf("id", "vaultId", "title", "preview", "searchText", "folder", "updatedAt").associateWith { text() } }
            require(input.available() == 0)
            fromMap(mapOf("schema" to 1, "lastVaultId" to last, "notes" to rows))
        }
    }
}
