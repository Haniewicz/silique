package pl.silique.app

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import pl.silique.app.widgets.WidgetRuntime

class SiliqueApplication : Application() {
    private val screen = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_SCREEN_OFF) WidgetRuntime.screenOff = true
            else if (intent.action == Intent.ACTION_USER_PRESENT) WidgetRuntime.screenOff = false
            WidgetRuntime.changed(context)
        }
    }
    override fun onCreate() {
        super.onCreate()
        val filter = IntentFilter().apply { addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_USER_PRESENT) }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screen, filter, Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(screen, filter)
    }
}
