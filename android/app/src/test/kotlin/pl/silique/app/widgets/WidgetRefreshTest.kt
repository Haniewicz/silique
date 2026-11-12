package pl.silique.app.widgets

import android.app.AlarmManager
import android.app.KeyguardManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowLooper
import javax.crypto.KeyGenerator

/**
 * The unlock re-render is driven by a bounded AlarmManager poll, because the
 * unlock broadcasts (USER_PRESENT / SCREEN_ON / SCREEN_OFF) are runtime-register
 * only and cannot be declared in the manifest. This test proves the poll wiring:
 * a render that lands while the keyguard is locked arms the poll, and the next
 * poll after unlock repaints from the now-readable snapshot.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class WidgetRefreshTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()
    private val snapshot get() = WidgetSnapshot.fromMap(mapOf(
        "schema" to 1, "lastVaultId" to "vault-1", "notes" to listOf(mapOf(
            "id" to "note-1", "vaultId" to "vault-1", "title" to "Garden",
            "preview" to "Flowers", "searchText" to "orchid", "folder" to "Plants",
            "updatedAt" to "2026-10-23T10:00:00Z"
        ))
    ))

    @Before fun seed() {
        WidgetRuntime.screenOff = false
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        WidgetRuntime.storeFactory = { SnapshotStore(it) { key } }
        WidgetRefreshReceiver().cancelAll(context)
    }

    private fun keyguard() = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
    private fun lock(locked: Boolean) = shadowOf(keyguard()).setKeyguardLocked(locked)

    @Test fun lockedRenderArmsBoundedPollThatRepaintsAfterUnlock() {
        WidgetRuntime.publish(context, snapshot)
        lock(true)

        var redraws = 0
        val listener: () -> Unit = { redraws++ }
        WidgetRuntime.listen(listener)
        try {
            // A render that lands while the keyguard is locked must arm the poll.
            WidgetRefreshReceiver().onRendered(context)
            val alarm = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
            val scheduled = alarm.peekNextScheduledAlarm()
            assertNotNull("A locked render must schedule the unlock poll", scheduled)

            // The user unlocks; the next poll must re-render from the now-readable store.
            lock(false)
            scheduled!!.operation!!.send()
            ShadowLooper.shadowMainLooper().idle()
            assertEquals("The unlock poll must repaint the widget", 1, redraws)
            val factory = NotesRemoteViewsService.Factory(context)
            factory.onDataSetChanged()
            assertEquals(1, factory.getCount())
            factory.onDestroy()
        } finally {
            WidgetRuntime.unlisten(listener)
        }
    }
}