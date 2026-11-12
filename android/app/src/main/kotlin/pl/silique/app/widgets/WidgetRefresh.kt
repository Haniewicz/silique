package pl.silique.app.widgets

import android.app.AlarmManager
import android.app.KeyguardManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Cold-start widget refresh: re-render the stored snapshot from a process that
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
 * broadcast to react to. To cover "the render landed under a locked keyguard",
 * whenever a render happens while the keyguard is locked a bounded AlarmManager
 * poll re-renders on a short cadence until the device is unlocked (or the tick
 * budget runs out). The alarm uses RTC (non-wakeup), so it fires when the user
 * actually wakes the device rather than waking it from sleep; each tick is a
 * plain WidgetRuntime.changed() render, so while locked it keeps the masked
 * state and the moment the keyguard is gone it paints the last snapshot.
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
                WidgetRuntime.changed(app)
                tickUnlockPoll(app)
            }
        }
    }

    /** Called once a widget render has happened (launcher restore, provider update). */
    fun onRendered(context: Context) {
        // Only arm, never cancel: an unlocked render must not kill a poll another
        // provider still needs, and the poll cancels itself on its first unlocked tick.
        if (locked(context)) armUnlockPoll(context)
    }

    /** Clear any outstanding poll (defensive reset and test hook). */
    fun cancelAll(context: Context) {
        cancelUnlockPoll(context.applicationContext)
    }

    private fun syncUnlockPoll(context: Context) {
        if (locked(context)) armUnlockPoll(context) else cancelUnlockPoll(context)
    }

    private fun tickUnlockPoll(context: Context) {
        val remaining = pollPrefs(context).getInt(KEY_REMAINING, 0) - 1
        pollPrefs(context).edit().putInt(KEY_REMAINING, remaining).apply()
        if (remaining <= 0 || !locked(context)) cancelUnlockPoll(context) else scheduleUnlockPoll(context)
    }

    private fun armUnlockPoll(context: Context) {
        val prefs = pollPrefs(context)
        if (prefs.getInt(KEY_REMAINING, 0) <= 0) prefs.edit().putInt(KEY_REMAINING, MAX_UNLOCK_POLL_TICKS).apply()
        scheduleUnlockPoll(context)
    }

    private fun scheduleUnlockPoll(context: Context) {
        val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarm.set(AlarmManager.RTC, System.currentTimeMillis() + UNLOCK_POLL_INTERVAL_MS, pendingIntent(context))
    }

    private fun cancelUnlockPoll(context: Context) {
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pendingIntent(context))
        pollPrefs(context).edit().remove(KEY_REMAINING).apply()
    }

    private fun locked(context: Context): Boolean =
        WidgetRuntime.screenOff || (context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked

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
        private const val KEY_REMAINING = "unlockPollRemaining"
        private const val UNLOCK_POLL_INTERVAL_MS = 60_000L
        private const val MAX_UNLOCK_POLL_TICKS = 30
    }
}