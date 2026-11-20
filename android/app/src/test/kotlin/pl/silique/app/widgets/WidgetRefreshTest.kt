package pl.silique.app.widgets

import android.app.AlarmManager
import android.app.KeyguardManager
import android.content.Context
import android.os.PowerManager
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
 * The unlock/retry re-render is driven by a bounded check-back, because the
 * unlock broadcasts (USER_PRESENT / SCREEN_ON / SCREEN_OFF) are runtime-register
 * only and cannot be declared in the manifest. A check that finds the state still
 * pending must be cheap and must never give up before the next realistic unlock:
 * a phone locked overnight has to repaint in the morning, not at lunch.
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
        shadowOf(context.getSystemService(Context.POWER_SERVICE) as PowerManager).setIsInteractive(true)
        WidgetRuntime.storeFactory = { SnapshotStore(it) { key } }
        WidgetRuntime.store(context).clear()
        WidgetRefreshReceiver().cancelAll(context)
        shadowOf(context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setKeyguardLocked(false)
    }

    private fun keyguard() = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
    private fun lock(locked: Boolean) = shadowOf(keyguard()).setKeyguardLocked(locked)
    private fun alarm() = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)

    @Test fun lockedRenderArmsPollAndTheFirstSettledCheckRepaints() {
        WidgetRuntime.store(context).write(snapshot)
        lock(true)
        var redraws = 0
        val listener: () -> Unit = { redraws++ }
        WidgetRuntime.listen(listener)
        try {
            WidgetRefreshReceiver().onRendered(context)
            val scheduled = alarm().peekNextScheduledAlarm()
            assertNotNull("A locked render must schedule the check-back", scheduled)

            lock(false)
            scheduled!!.operation!!.send()
            ShadowLooper.shadowMainLooper().idle()
            assertEquals("The settled check must repaint the widget", 1, redraws)
            assertFalse("A settled state must stop checking back", pollPrefs.contains("pollStage"))
            val factory = NotesRemoteViewsService.Factory(context)
            factory.onDataSetChanged()
            assertEquals(1, factory.getCount())
            factory.onDestroy()
        } finally {
            WidgetRuntime.unlisten(listener)
        }
    }

    @Test fun aPendingCheckDoesNotRenderAndKeepsChecking() {
        WidgetRuntime.store(context).write(snapshot)
        WidgetRuntime.storeFactory = { SnapshotStore(it) { throw IllegalStateException("keystore locked") } }
        var redraws = 0
        val listener: () -> Unit = { redraws++ }
        WidgetRuntime.listen(listener)
        try {
            WidgetRefreshReceiver().onRendered(context)
            assertEquals("Arming must not repaint", 0, redraws)
            val first = alarm().peekNextScheduledAlarm()
            assertNotNull("An unreadable snapshot must arm the check-back", first)
            first!!.operation!!.send()
            ShadowLooper.shadowMainLooper().idle()
            assertEquals("A pending check must not render the masked state again", 0, redraws)
            assertTrue("A pending check must keep checking", pollPrefs.contains("pollStage"))
            assertEquals(29, pollPrefs.getInt("pollFastRemaining", -1))

            // The Keystore becomes usable: the next check settles and repaints.
            WidgetRuntime.storeFactory = { SnapshotStore(it) { key } }
            alarm().peekNextScheduledAlarm()!!.operation!!.send()
            ShadowLooper.shadowMainLooper().idle()
            assertEquals(1, redraws)
            assertFalse(pollPrefs.contains("pollStage"))
            assertTrue(WidgetRuntime.content(context) is WidgetContent.Ready)
        } finally {
            WidgetRuntime.unlisten(listener)
        }
    }

    @Test fun aMissedUnlockBroadcastSettlesOnTheNextCheck() {
        WidgetRuntime.store(context).write(snapshot)
        val power = shadowOf(context.getSystemService(Context.POWER_SERVICE) as PowerManager)
        power.setIsInteractive(false)
        var redraws = 0
        val listener: () -> Unit = { redraws++ }
        WidgetRuntime.listen(listener)
        try {
            WidgetRefreshReceiver().onRendered(context)
            assertEquals("Arming must not repaint", 0, redraws)
            // The user unlocks; no USER_PRESENT reaches this frozen process.
            power.setIsInteractive(true)
            alarm().peekNextScheduledAlarm()!!.operation!!.send()
            ShadowLooper.shadowMainLooper().idle()
            assertEquals("The first check after the unlock must repaint the notes", 1, redraws)
            assertFalse(pollPrefs.contains("pollStage"))
        } finally {
            WidgetRuntime.unlisten(listener)
        }
    }

    @Test fun aLongLockFallsBackToATenMinuteCheckInsteadOfGivingUp() {
        WidgetRuntime.store(context).write(snapshot)
        lock(true)
        pollPrefs.edit().putInt("pollStage", 0).putInt("pollFastRemaining", 1).apply()
        WidgetRefreshReceiver().onRendered(context)
        alarm().peekNextScheduledAlarm()!!.operation!!.send()
        ShadowLooper.shadowMainLooper().idle()
        assertEquals("The fast stage must hand over to the slow stage", 1, pollPrefs.getInt("pollStage", -1))
        assertTrue(pollPrefs.getInt("pollSlowRemaining", -1) > 0)
        val next = alarm().peekNextScheduledAlarm()
        assertNotNull("A long lock must keep checking back", next)
        val delay = next!!.triggerAtTime - System.currentTimeMillis()
        assertTrue("The slow check must be minutes apart, was $delay ms", delay >= 540_000)

        // Morning unlock: the next check settles and the notes appear.
        var redraws = 0
        val listener: () -> Unit = { redraws++ }
        WidgetRuntime.listen(listener)
        try {
            lock(false)
            next.operation!!.send()
            ShadowLooper.shadowMainLooper().idle()
            assertEquals(1, redraws)
            assertFalse(pollPrefs.contains("pollStage"))
        } finally {
            WidgetRuntime.unlisten(listener)
        }
    }

    @Test fun anExhaustedSlowStageStopsButLeavesTheSnapshotAlone() {
        WidgetRuntime.store(context).write(snapshot)
        lock(true)
        pollPrefs.edit().putInt("pollStage", 1).putInt("pollSlowRemaining", 1).apply()
        WidgetRefreshReceiver().onRendered(context)
        alarm().peekNextScheduledAlarm()!!.operation!!.send()
        ShadowLooper.shadowMainLooper().idle()
        assertFalse("Two days of locking must not keep an alarm forever", pollPrefs.contains("pollStage"))
        assertTrue(WidgetRuntime.store(context).file.exists())
    }
}
