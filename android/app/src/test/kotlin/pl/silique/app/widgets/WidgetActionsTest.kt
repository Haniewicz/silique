package pl.silique.app.widgets

import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class WidgetActionsTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()

    @Test fun journalLaunchIsAcceptedAsAnIndependentAction() {
        val queue = WidgetActionQueue()
        val intent = WidgetIntents.newIntent(context, "vault-1").putExtra("action", "journal")
        assertTrue(queue.accept(intent))
        assertEquals("journal", queue.take()!!["action"])
    }

    @Test fun coldLaunchQueuesUntilDartConsumesExactlyOnce() {
        val queue = WidgetActionQueue()
        assertTrue(queue.accept(WidgetIntents.noteIntent(context, "vault-1", "note-1")))
        val action = queue.take()!!
        assertEquals("openNote", action["action"])
        assertEquals("vault-1", action["vaultId"])
        assertEquals("note-1", action["noteId"])
        assertFalse((action["requestId"] as String).isBlank())
        assertNull(queue.take())
    }

    @Test fun warmLaunchNotifiesButDoesNotLoseQueuedAction() {
        val queue = WidgetActionQueue()
        var notifications = 0
        queue.onAvailable = { notifications++ }
        queue.accept(WidgetIntents.newIntent(context, null))
        queue.accept(WidgetIntents.noteIntent(context, "vault-1", "note-1"))
        assertEquals(2, notifications)
        assertEquals("newNote", queue.take()!!["action"])
        assertEquals("openNote", queue.take()!!["action"])
        assertNull(queue.take())
    }

    @Test fun reusedIntentDoesNotReplayButSeparateTapsHaveUniqueRequestIds() {
        val queue = WidgetActionQueue()
        val intent = WidgetIntents.newIntent(context, null)
        assertTrue(queue.accept(intent))
        assertFalse(queue.accept(intent))
        val first = queue.take()!!["requestId"]
        assertTrue(queue.accept(WidgetIntents.newIntent(context, null)))
        assertNotEquals(first, queue.take()!!["requestId"])
    }

    @Test fun malformedOrForeignActionsCannotBeQueued() {
        val queue = WidgetActionQueue()
        assertFalse(queue.accept(Intent(Intent.ACTION_VIEW)))
        assertFalse(queue.accept(WidgetIntents.noteIntent(context, "vault-1", "note-1").putExtra("noteId", " note-1")))
        assertFalse(queue.accept(WidgetIntents.noteIntent(context, "vault-1", "note-1").putExtra("vaultId", "../vault")))
        assertNull(queue.take())
    }

    @Test fun pendingIntentsAreImmutableDistinctExplicitAndContainNoNoteText() {
        val first = WidgetIntents.notePending(context, "vault-1", "note-1", 7)
        val second = WidgetIntents.notePending(context, "vault-1", "note-2", 7)
        assertNotEquals(first, second)
        val captured = shadowOf(first).savedIntent
        assertEquals("pl.silique.app.WidgetActionActivity", captured.component!!.className)
        assertEquals(setOf("action", "vaultId", "noteId"), captured.extras!!.keySet())
        assertTrue(shadowOf(first).flags and android.app.PendingIntent.FLAG_IMMUTABLE != 0)
        val search = shadowOf(WidgetIntents.searchPending(context, 7)).savedIntent
        assertEquals("pl.silique.app.WidgetSearchActivity", search.component!!.className)
    }
}
