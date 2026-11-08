package pl.silique.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.util.Base64
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowContentResolver
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SiliqueClipboardTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val clipboard get() = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    class Images : ContentProvider() {
        var reads = 0
        var mime = "image/png"
        var denied = false
        var bytes = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII=", Base64.DEFAULT)
        override fun onCreate() = true
        override fun getType(uri: Uri) = mime
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
            reads++
            if (denied) throw SecurityException("revoked")
            val file = File(context!!.cacheDir, "clipboard-test.png")
            file.writeBytes(bytes)
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        }
    }
    private fun provider(): Images = Images().also {
        it.attachInfo(context, android.content.pm.ProviderInfo().apply { authority = "paste.test" })
        ShadowContentResolver.registerProviderInternal("paste.test", it)
    }

    @Test fun contentUriImageIsReadOnlyOnExplicitSnapshot() {
        val provider = provider()
        clipboard.setPrimaryClip(ClipData.newUri(context.contentResolver, "Image", Uri.parse("content://paste.test/image")))
        assertEquals(0, provider.reads)
        val snapshot = SiliqueClipboard.readClipboard(context)
        val media = snapshot["media"] as List<*>
        assertEquals(1, media.size)
        assertArrayEquals(provider.bytes, (media.single() as Map<*, *>)["bytes"] as ByteArray)
        assertEquals(1, provider.reads)
        assertNull(snapshot["text"])
    }

    @Test fun plainTextRemainsTextButFileUrisNeverBecomeText() {
        clipboard.setPrimaryClip(ClipData.newPlainText("Text", "plain"))
        assertEquals("plain", SiliqueClipboard.readClipboard(context)["text"])
        clipboard.setPrimaryClip(ClipData.newRawUri("File", Uri.parse("file:///private/image.png")))
        val snapshot = SiliqueClipboard.readClipboard(context)
        assertEquals(true, snapshot["hasUnsupportedMedia"])
        assertNull(snapshot["text"])
    }

    @Test fun deniedAndMismatchedMediaAreRejectedWithoutUriFallback() {
        val provider = provider()
        val uri = Uri.parse("content://paste.test/image")
        provider.denied = true
        clipboard.setPrimaryClip(ClipData.newUri(context.contentResolver, "Image", uri))
        assertEquals(true, SiliqueClipboard.readClipboard(context)["hasUnsupportedMedia"])
        provider.denied = false
        provider.mime = "image/jpeg"
        assertThrows(IllegalArgumentException::class.java) { SiliqueClipboard.readUri(context.contentResolver, uri, "image/jpeg") }
    }

    @Test fun imeUriEnforcesMimeByteAndDimensionLimits() {
        val provider = provider()
        val uri = Uri.parse("content://paste.test/image")
        assertEquals("image/png", SiliqueClipboard.readUri(context.contentResolver, uri, "image/png")["mimeType"])
        assertThrows(IllegalArgumentException::class.java) { SiliqueClipboard.readUri(context.contentResolver, uri, "image/jpeg") }
        assertThrows(IllegalArgumentException::class.java) { SiliqueClipboard.readUri(context.contentResolver, Uri.parse("https://example.com/image.png"), "image/png") }
        provider.bytes = ByteArray(10 * 1024 * 1024 + 1)
        assertThrows(IllegalArgumentException::class.java) { SiliqueClipboard.readUri(context.contentResolver, uri, "image/png") }
    }
}
