package pl.silique.app

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import pl.silique.app.widgets.WidgetRuntime
import pl.silique.app.widgets.WidgetSnapshot

class SiliqueWidgets(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "silique.notes/widgets")
    private val available: () -> Unit = { channel.invokeMethod("actionAvailable", null) }
    init {
        WidgetRuntime.actions.onAvailable = available
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "publishSnapshot" -> {
                    try {
                        val map = call.arguments as? Map<*, *> ?: throw IllegalArgumentException()
                        WidgetRuntime.publish(context, WidgetSnapshot.fromMap(map))
                        result.success(null)
                    } catch (_: Exception) {
                        WidgetRuntime.clear(context)
                        result.error("snapshot_rejected", "Widget snapshot unavailable", null)
                    }
                }
                "clearSnapshot" -> { WidgetRuntime.clear(context); result.success(null) }
                "removeVaultSnapshot" -> {
                    try {
                        val id = call.arguments as? String ?: throw IllegalArgumentException()
                        WidgetRuntime.removeVault(context, id)
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("snapshot_cleanup_pending", "Vault snapshot cleanup pending; retry deletion", null)
                    }
                }
                "takePendingAction" -> result.success(WidgetRuntime.actions.take())
                else -> result.notImplemented()
            }
        }
    }
    fun dispose() {
        if (WidgetRuntime.actions.onAvailable === available) WidgetRuntime.actions.onAvailable = null
        channel.setMethodCallHandler(null)
    }
}
