package pl.silique.app

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import pl.silique.app.widgets.WidgetRuntime

/**
 * Repaint the launcher when the screen state changes. The lock state itself is
 * read live by WidgetRuntime.locked(), so a broadcast missed while the process
 * was frozen cannot leave the widget masked forever.
 */
class SiliqueApplication : Application() {
    private val screen = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            WidgetRuntime.changed(context)
        }
    }
    override fun onCreate() {
        super.onCreate()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screen, filter, Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(screen, filter)
    }
}
