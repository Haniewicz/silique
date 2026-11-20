package pl.silique.app.widgets

import android.content.Context
import android.os.PowerManager
import androidx.test.core.app.ApplicationProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import pl.silique.app.SiliqueWidgets
import java.nio.ByteBuffer
import javax.crypto.KeyGenerator

/**
 * A rejected publish must leave the last good snapshot on disk: clearing it made
 * the launcher show "no notes" until the app published different content.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class WidgetPublishTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private val payload = mapOf(
        "schema" to 1, "lastVaultId" to "vault-1", "notes" to listOf(mapOf(
            "id" to "note-1", "vaultId" to "vault-1", "title" to "Kept",
            "preview" to "p", "searchText" to "s", "folder" to "f",
            "updatedAt" to "2026-10-23T10:00:00Z"
        ))
    )

    private class NoopMessenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }

    private class CaptureResult : MethodChannel.Result {
        var value: Any? = null
        var failure: String? = null
        var unsupported = false
        override fun success(result: Any?) { value = result }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) { failure = errorCode }
        override fun notImplemented() { unsupported = true }
    }

    private fun SiliqueWidgets.call(method: String, arguments: Any?): CaptureResult =
        CaptureResult().also { handle(method, arguments, it) }

    @Before fun seed() {
        shadowOf(context.getSystemService(Context.POWER_SERVICE) as PowerManager).setIsInteractive(true)
        WidgetRuntime.storeFactory = { SnapshotStore(it) { key } }
        WidgetRuntime.store(context).clear()
    }

    @Test fun rejectedPublishKeepsTheLastGoodSnapshot() {
        val widgets = SiliqueWidgets(context, NoopMessenger())
        val accepted = widgets.call("publishSnapshot", payload)
        assertNull("A valid payload must succeed", accepted.failure)
        assertFalse(accepted.unsupported)
        assertEquals(1, WidgetRuntime.store(context).read().notes.size)

        // A malformed payload (wrong schema) must be rejected without dropping the good copy.
        val rejected = widgets.call(
            "publishSnapshot", mapOf("schema" to 2, "notes" to emptyList<Any>())
        )
        assertEquals("snapshot_rejected", rejected.failure)
        assertTrue(
            "The last good snapshot must survive a rejected publish",
            WidgetRuntime.store(context).file.exists()
        )
        assertEquals(1, WidgetRuntime.store(context).read().notes.size)

        val diagnostics = widgets.call("widgetDiagnostics", null)
        assertTrue(
            "A rejected publish must be visible in the widget diagnostics",
            (diagnostics.value as String).contains("publish_rejected")
        )
    }

    @Test fun explicitClearStillDropsTheIndex() {
        val widgets = SiliqueWidgets(context, NoopMessenger())
        assertNull(widgets.call("publishSnapshot", payload).failure)
        assertNull(widgets.call("clearSnapshot", null).failure)
        assertFalse(WidgetRuntime.store(context).file.exists())
        assertTrue(WidgetRuntime.store(context).read().notes.isEmpty())
    }
}
