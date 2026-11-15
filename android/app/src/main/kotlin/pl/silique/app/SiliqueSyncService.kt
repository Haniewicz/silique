package pl.silique.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Foreground "data sync" service that keeps a long sync operation alive while
 * the app is backgrounded. Started from Dart through the `silique.notes/background`
 * channel (`start` with a title/message, `stop`), it posts one ongoing,
 * low-importance notification whose tap reopens the app. Mirrors the existing
 * channel-bridge style (`SiliqueWidgets`, `SiliqueClipboard`): this class owns
 * only its channel and never invents a new messenger pattern.
 *
 * Every failure is swallowed by the bridge: the service is a progress marker,
 * never a gate on the sync it decorates, so a refused notification permission or
 * an unavailable API constant must not abort the operation.
 */
class SiliqueSyncService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_START) {
            val title = intent.getStringExtra(EXTRA_TITLE) ?: getString(R.string.native_sync_notification_title)
            val message = intent.getStringExtra(EXTRA_MESSAGE) ?: getString(R.string.native_sync_notification_message)
            post(title, message)
            return START_NOT_STICKY
        }
        return super.onStartCommand(intent, flags, startId)
    }

    private fun createChannel() {
        // Notification channels exist since API 26; below that, no channel is
        // needed and the plain legacy builder is used instead.
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val name = SiliqueLanguage.text(context, R.string.native_sync_channel_name)
        val description = SiliqueLanguage.text(context, R.string.native_sync_channel_description)
        val channel = NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_LOW)
        channel.description = description
        manager.createNotificationChannel(channel)
    }

    private fun post(title: String, message: String) {
        // A missing POST_NOTIFICATIONS grant (Android 13+) must downgrade to a
        // silent foreground start, never throw into the operation path.
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            startSilent()
            return
        }
        val tapIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pending = tapIntent?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        val builder = builder()
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(title)
            .setContentText(message)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(Notification.PRIORITY_LOW)
            .setCategory(Notification.CATEGORY_SYNC)
        pending?.let { builder.setContentIntent(it) }
        val notification = builder.build()
        val type = dataSyncType()
        startForegroundCompat(type, notification)
    }

    private fun startSilent() {
        // Keep the declared dataSync type even without the notification grant:
        // API 34 rejects a foreground start whose type does not match the
        // manifest declaration. The notification itself may stay invisible.
        startForegroundCompat(dataSyncType(), builder()
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(getString(R.string.native_sync_notification_title))
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_MIN)
            .build())
    }

    /** A notification builder on the channel when available (API 26+), else the legacy one. */
    private fun builder(): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

    /**
     * The `dataSync` foreground-service type constant exists since API 29; older
     * platforms (and unavailable constants) degrade to a plain `0` type.
     */
    private fun dataSyncType(): Int =
        if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0

    private fun startForegroundCompat(type: Int, notification: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, type)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            // Best effort: if the type/permission is refused, fall back to a
            // plain foreground start so the process is still kept alive.
            try {
                startForeground(NOTIFICATION_ID, notification)
            } catch (_: Exception) {
                // Nothing more to try; the operation continues out-of-foreground.
            }
        }
    }

    companion object {
        private const val CHANNEL_ID = "silique-sync"
        private const val NOTIFICATION_ID = 4712
        private const val ACTION_START = "pl.silique.app.action.SYNC_START"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_MESSAGE = "message"

        fun start(context: Context, title: String, message: String) {
            val intent = Intent(context, SiliqueSyncService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_MESSAGE, message)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                // Pre-26 has no startForegroundService; a plain startService plus
                // the service's own startForeground keeps the process alive.
                @Suppress("DEPRECATION")
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            // stopService removes the ongoing notification and calls onDestroy.
            // It is safe on every API level and a no-op when nothing is running.
            context.stopService(Intent(context, SiliqueSyncService::class.java))
        }
    }
}

/** Mirrors `SiliqueLanguageBridge`: owns only its channel. */
class SiliqueBackground(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "silique.notes/background")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val args = call.arguments as? Map<*, *>
                    val title = args?.get("title") as? String ?: ""
                    val message = args?.get("message") as? String ?: ""
                    try {
                        SiliqueSyncService.start(context, title, message)
                        result.success(null)
                    } catch (_: Exception) {
                        // A refused foreground start must not fail the sync.
                        result.success(null)
                    }
                }
                "stop" -> {
                    try {
                        SiliqueSyncService.stop(context)
                        result.success(null)
                    } catch (_: Exception) {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() { channel.setMethodCallHandler(null) }
}