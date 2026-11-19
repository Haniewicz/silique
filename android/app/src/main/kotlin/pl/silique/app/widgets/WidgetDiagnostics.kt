package pl.silique.app.widgets

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Bounded, content-free diagnostics for the launcher widgets.
 *
 * The launcher lives in another process, so a misbehaving widget cannot be
 * debugged from the app UI alone. Every render, snapshot read/write and retry
 * poll appends one short line (timestamp, pid, event, counts, exception class)
 * to a ring file next to the encrypted snapshot. Note titles, bodies, folder
 * names and search queries are never recorded.
 */
object WidgetDiagnostics {
    private const val FILE = "silique-widgets.log"
    private const val MAX_BYTES = 64 * 1024
    private const val KEEP_BYTES = 32 * 1024
    private val lock = Any()

    /** Records one event. Diagnostics must never break a widget, so it swallows every error. */
    fun record(context: Context, event: String, details: String = "") {
        try {
            val line = "${stamp()} pid=${android.os.Process.myPid()} $event${if (details.isEmpty()) "" else " $details"}\n"
            synchronized(lock) {
                val file = file(context)
                val bytes = line.toByteArray(Charsets.UTF_8)
                if (file.exists() && file.length() + bytes.size > MAX_BYTES) trim(file)
                file.appendBytes(bytes)
            }
        } catch (_: Exception) {
        }
    }

    /** Returns the current log for the in-app diagnostics view; empty when never written. */
    fun read(context: Context): String = try {
        synchronized(lock) {
            val file = file(context)
            if (file.exists()) file.readText() else ""
        }
    } catch (_: Exception) {
        ""
    }

    private fun file(context: Context) = File(context.applicationContext.noBackupFilesDir, FILE)

    /** Keeps the newest [KEEP_BYTES] aligned to a line boundary. */
    private fun trim(file: File) {
        val all = file.readBytes()
        if (all.size <= KEEP_BYTES) return
        var from = all.size - KEEP_BYTES
        while (from < all.size && all[from] != '\n'.code.toByte()) from++
        if (from < all.size) from++
        file.writeBytes(all.copyOfRange(from, all.size))
    }

    private fun stamp(): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.ROOT).format(Date())
}
