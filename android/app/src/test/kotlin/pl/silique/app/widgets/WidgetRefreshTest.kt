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
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import javax.crypto.KeyGenerator

/**
 * The unlock/retry re-render is driven by a bounded AlarmManager poll, because
 * the unlock broadcasts (USER_PRESENT / SCREEN_ON / SCREEN_OFF) are runtime-
 * register only and cannot be declared in the manifest. These tests prove the
 * poll wiring for both reasons a render can land wrong: a locked keyguard and a
 * snapshot that cannot be read right now.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class WidgetRefreshTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private val snapshot = WidgetSnapshot.fromMap(mapOf(
        "schema" to 1, "lastVaultId" to "vault-1", "notes" to listOf(mapOf(
            "id" to "note-1", "vaultId" to "vault-1", "title" to "Garden",
            "preview" to "Flowers", "searchText" to "orchid", "folder" to "Plants",
            "updatedAt" to "2026-10-23T10:00:00Z"
        ))
    ))
    private val pollPrefs get() = context.getSharedPreferences("silique.widgets.refresh", Context.MODE_PRIVATE)

    @Before fun seed() {
        WidgetRuntime.screenOff = false
        WidgetRuntime.storeFactory = { SnapshotStore(it) { key } }
        WidgetRuntime.store(context).clear()
        WidgetRefreshReceiver().cancelAll(context)
    }

    private fun keyguard() = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
    private fun lock(locked: Boolean) = shadowOf(keyguard()).setKeyguardLocked(locked)
    private fun alarm() = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)

    @Test fun lockedRenderArmsBoundedPollThatRepaintsAfterUnlock() {
        WidgetRuntime.store(context).write(snapshot)
        lock(true)

        var redraws = 0
        val listener: () -> Unit = { redraws++ }
        WidgetRuntime.listen(listener)
        try {
            // A render that lands while the keyguard is locked must arm the poll.
            WidgetRefreshReceiver().onRendered(context)
            val scheduled = alarm().peekNextScheduledAlarm()
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

    @Test fun unreadableSnapshotArmsPollAndRetriesUntilItCanBeRead() {
        WidgetRuntime.store(context).write(snapshot)
        WidgetRuntime.storeFactory = { SnapshotStore(it) { throw IllegalStateException("keystore locked") } }

        WidgetRefreshReceiver().onRendered(context)
        val first = alarm().peekNextScheduledAlarm()
        assertNotNull("An unreadable snapshot must arm the retry poll", first)
        assertTrue("The poll budget must be armed", pollPrefs.contains("unlockPollRemaining"))

        // The next tick still cannot read: it must keep polling, not give up.
        first!!.operation!!.send()
        ShadowLooper.shadowMainLooper().idle()
        assertTrue("The poll must keep retrying while the snapshot stays unreadable", pollPrefs.contains("unlockPollRemaining"))

        // The Keystore becomes usable again: the next tick settles the poll.
        WidgetRuntime.storeFactory = { SnapshotStore(it) { key } }
        alarm().peekNextScheduledAlarm()!!.operation!!.send()
        ShadowLooper.shadowMainLooper().idle()
        assertFalse("A readable snapshot must stop the retry poll", pollPrefs.contains("unlockPollRemaining"))
        assertTrue(WidgetRuntime.content(context) is WidgetContent.Ready)
    }

    @Test fun unreadableSnapshotIsReportedAsUnavailableNotAsEmpty() {
        WidgetRuntime.store(context).write(snapshot)
        WidgetRuntime.storeFactory = { SnapshotStore(it) { throw IllegalStateException("keystore locked") } }
        assertTrue(WidgetRuntime.content(context) is WidgetContent.Unavailable)
    }
}
