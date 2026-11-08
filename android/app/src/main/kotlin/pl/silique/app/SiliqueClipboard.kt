package pl.silique.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.ContentResolver
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/** No clipboard listener or background inspection. Dart calls only for user paste/IME commit. */
class SiliqueClipboard(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "silique.notes/clipboard")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var disposed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (disposed) { result.error("unavailable", "Clipboard closed", null); return@setMethodCallHandler }
            when (call.method) {
                "read" -> {
                    // Android requires foreground access. Capture once on the UI thread,
                    // before provider I/O goes to the bounded worker.
                    val clip = try { manager(context).primaryClip } catch (_: SecurityException) { null }
                    worker.execute { respond(result) { readClip(context.contentResolver, clip) } }
                }
                "readUri" -> {
                    val uri = call.argument<String>("uri")
                    val mime = call.argument<String>("mimeType")
                    worker.execute { respond(result) {
                        require(uri != null && mime != null) { "Missing content identity" }
                        mapOf("media" to listOf(readUri(context.contentResolver, Uri.parse(uri), mime)))
                    } }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun respond(result: MethodChannel.Result, read: () -> Map<String, Any?>) {
        try {
            val value = read()
            main.post { if (!disposed) result.success(value) }
        } catch (_: Exception) {
            main.post { if (!disposed) result.error("unreadable", "Clipboard image is unavailable or unsupported", null) }
        }
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }

    companion object {
        private const val MAX_BYTES = 10 * 1024 * 1024
        private const val MAX_PIXELS = 16L * 1024 * 1024
        private val MIME_TYPES = setOf("image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp")
        private fun manager(context: Context) = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

        fun readClipboard(context: Context): Map<String, Any?> = readClip(context.contentResolver, manager(context).primaryClip)

        private fun readClip(resolver: ContentResolver, clip: ClipData?): Map<String, Any?> {
            if (clip == null) return emptyMap()
            val media = mutableListOf<Map<String, Any>>()
            val text = mutableListOf<String>()
            var unsupported = clip.itemCount > 4
            var total = 0
            for (index in 0 until minOf(clip.itemCount, 4)) {
                val item = clip.getItemAt(index)
                val uri = item.uri
                if (uri != null) {
                    try {
                        val image = readUri(resolver, uri)
                        total += (image["bytes"] as ByteArray).size
                        require(total <= MAX_BYTES) { "Clipboard batch too large" }
                        media.add(image)
                    } catch (_: Exception) { unsupported = true }
                } else if (item.intent != null) {
                    unsupported = true
                } else {
                    item.text?.toString()?.let {
                        if (it.length <= 1024 * 1024) text.add(it) else unsupported = true
                    }
                }
            }
            // An unreadable URI must not be coerced to a path/URL text representation.
            return mapOf("media" to media, "text" to if (media.isEmpty() && !unsupported) text.joinToString("\n").ifEmpty { null } else null, "hasUnsupportedMedia" to unsupported)
        }

        fun readUri(resolver: ContentResolver, uri: Uri, expectedMime: String? = null): Map<String, Any> {
            require(uri.scheme == "content") { "Only content URIs are accepted" }
            val mime = resolver.getType(uri)?.lowercase()
            require(mime in MIME_TYPES && (expectedMime == null || expectedMime == mime)) { "Unsupported image MIME" }
            val bytes = resolver.openInputStream(uri)?.use { input ->
                val output = ByteArrayOutputStream()
                val chunk = ByteArray(16 * 1024)
                while (true) {
                    if (Thread.currentThread().isInterrupted) throw InterruptedException()
                    val count = input.read(chunk)
                    if (count < 0) break
                    require(output.size() + count <= MAX_BYTES) { "Image too large" }
                    output.write(chunk, 0, count)
                }
                output.toByteArray()
            } ?: throw IllegalArgumentException("Unreadable content")
            require(bytes.isNotEmpty()) { "Empty image" }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            require(bounds.outMimeType == mime && bounds.outWidth > 0 && bounds.outHeight > 0 && bounds.outWidth.toLong() * bounds.outHeight <= MAX_PIXELS) { "Invalid image MIME or dimensions" }
            return mapOf("mimeType" to mime!!, "bytes" to bytes)
        }
    }
}
