package pl.silique.app.widgets

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Cold-start and retry refresh: re-render the stored snapshot from a process that
 * never launches Flutter. The dynamic SCREEN_OFF/USER_PRESENT receiver in
 * SiliqueApplication dies with the process, so after a reboot nothing re-renders
 * the widget once the launcher has painted the masked "Locked" state.
 *
 * Broadcasts handled (both delivered to this manifest-declared, exported=false
 * receiver in a freshly started process):
 *
 *  - ACTION_BOOT_COMPLETED — explicitly exempt from the Android 8.0+ (API 26)
 *    implicit-broadcast ban and sent once the user has unlocked for the first
 *    time (credential-encrypted storage, i.e. noBackupFilesDir, is readable).
 *    Receiving it requires android.permission.RECEIVE_BOOT_COMPLETED.
 *
 * USER_PRESENT / ACTION_SCREEN_ON / ACTION_SCREEN_OFF are runtime-register-only:
 * they cannot be declared in the manifest, so a cold process has no unlock
 * broadcast to react to. Whenever a render happens in a state that needs a later
 * repaint (locked keyguard or an unreadable snapshot) a bounded AlarmManager
 * check-back is armed instead. It checks the state without decrypting anything:
 *
 *  - the first 30 checks run every 60 s (covers a short lock), then
 *  - checks continue every 10 minutes for up to 48 hours (covers "locked all
 *    night, unlocked in the morning"), and only
 *  - the check that finds the state settled performs the actual render.
 *
 * The alarm is RTC (non-wakeup): it fires when the user actually wakes the
 * device instead of waking it from sleep, so a long check-back costs no wakeups.
 */
class WidgetRefreshReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED -> {
                WidgetRuntime.changed(app)
                syncUnlockPoll(app)
            }
            ACTION_POLL -> {
                if (needsRefresh(app)) tickPending(app) else settle(app)
            }
        }
    }

    /** Called by every widget render, from the provider or from the app process. */
    fun onRendered(context: Context) {
        // Only arm, never cancel: an unlocked render must not kill a poll another
        // provider still needs, and the poll cancels itself on its first settled tick.
        if (needsRefresh(context)) armUnlockPoll(context)
    }

    /** Clear any outstanding poll (defensive reset and test hook). */
    fun cancelAll(context: Context) {
        cancelUnlockPoll(context.applicationContext)
    }

    private fun syncUnlockPoll(context: Context) {
        if (needsRefresh(context)) armUnlockPoll(context) else cancelUnlockPoll(context)
    }

    /** Still pending: decide when to check again, without touching the key or rendering. */
    private fun tickPending(context: Context) {
        val prefs = pollPrefs(context)
        val stage = prefs.getInt(KEY_STAGE, STAGE_FAST)
        if (stage == STAGE_FAST) {
            val remaining = prefs.getInt(KEY_FAST_REMAINING, FAST_TICKS) - 1
            if (remaining > 0) {
                prefs.edit().putInt(KEY_FAST_REMAINING, remaining).apply()
                WidgetDiagnostics.record(context, "poll_wait", "stage=fast remaining=$remaining")
                scheduleUnlockPoll(context, FAST_INTERVAL_MS)
            } else {
                prefs.edit()
                    .putInt(KEY_STAGE, STAGE_SLOW)
                    .putInt(KEY_SLOW_REMAINING, SLOW_TICKS)
                    .apply()
                WidgetDiagnostics.record(context, "poll_wait", "stage=slow remaining=$SLOW_TICKS")
                scheduleUnlockPoll(context, SLOW_INTERVAL_MS)
            }
        } else {
            val remaining = prefs.getInt(KEY_SLOW_REMAINING, SLOW_TICKS) - 1
            if (remaining > 0) {
                prefs.edit().putInt(KEY_SLOW_REMAINING, remaining).apply()
                WidgetDiagnostics.record(context, "poll_wait", "stage=slow remaining=$remaining")
                scheduleUnlockPoll(context, SLOW_INTERVAL_MS)
            } else {
                // Locked for two days: give up; the app or a reboot re-arms this.
                WidgetDiagnostics.record(context, "poll_exhausted")
                cancelUnlockPoll(context)
            }
        }
    }

    /** The state settled: paint the real content once and stop checking back. */
    private fun settle(context: Context) {
        WidgetRuntime.changed(context)
        cancelUnlockPoll(context)
        WidgetDiagnostics.record(context, "poll_settled")
    }

    private fun armUnlockPoll(context: Context) {
        val prefs = pollPrefs(context)
        if (!prefs.contains(KEY_STAGE)) {
            prefs.edit()
                .putInt(KEY_STAGE, STAGE_FAST)
                .putInt(KEY_FAST_REMAINING, FAST_TICKS)
                .apply()
        }
        WidgetDiagnostics.record(context, "arm")
        scheduleUnlockPoll(
            context,
            if (prefs.getInt(KEY_STAGE, STAGE_FAST) == STAGE_FAST) FAST_INTERVAL_MS else SLOW_INTERVAL_MS
        )
    }

    private fun scheduleUnlockPoll(context: Context, intervalMs: Long) {
        val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarm.set(AlarmManager.RTC, System.currentTimeMillis() + intervalMs, pendingIntent(context))
    }

    private fun cancelUnlockPoll(context: Context) {
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pendingIntent(context))
        pollPrefs(context).edit()
            .remove(KEY_STAGE)
            .remove(KEY_FAST_REMAINING)
            .remove(KEY_SLOW_REMAINING)
            .apply()
    }

    /**
     * A locked screen and a snapshot that cannot be read right now both settle
     * without an app launch, so both justify the check-back.
     */
    private fun needsRefresh(context: Context): Boolean =
        WidgetRuntime.locked(context) || WidgetRuntime.content(context) is WidgetContent.Unavailable

    private fun pollPrefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun pendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        0,
        Intent(context, WidgetRefreshReceiver::class.java).setAction(ACTION_POLL),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )

    companion object {
        const val ACTION_POLL = "pl.silique.app.widgets.UNLOCK_POLL"
        private const val PREFS = "silique.widgets.refresh"
        private const val KEY_STAGE = "pollStage"
        private const val KEY_FAST_REMAINING = "pollFastRemaining"
        private const val KEY_SLOW_REMAINING = "pollSlowRemaining"
        private const val STAGE_FAST = 0
        private const val STAGE_SLOW = 1
        private const val FAST_INTERVAL_MS = 60_000L
        private const val FAST_TICKS = 30
        private const val SLOW_INTERVAL_MS = 600_000L
        private const val SLOW_TICKS = 288
    }
}
