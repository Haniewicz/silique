package pl.silique.app

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import pl.silique.app.widgets.WidgetDiagnostics
import pl.silique.app.widgets.WidgetRuntime
import pl.silique.app.widgets.WidgetSnapshot

class SiliqueWidgets(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "silique.notes/widgets")
    private val available: () -> Unit = { channel.invokeMethod("actionAvailable", null) }
    init {
        WidgetRuntime.actions.onAvailable = available
        channel.setMethodCallHandler { call, result -> handle(call.method, call.arguments, result) }
    }

    /** The channel handler, kept apart so host tests need no Flutter engine. */
    internal fun handle(method: String, arguments: Any?, result: MethodChannel.Result) {
        when (method) {
            "publishSnapshot" -> {
                try {
                    val map = arguments as? Map<*, *> ?: throw IllegalArgumentException()
                    WidgetRuntime.publish(context, WidgetSnapshot.fromMap(map))
                    result.success(null)
                } catch (error: Exception) {
                    // Never drop the last good snapshot because one publish was
                    // rejected: the launcher would then show an empty list until
                    // the app happens to publish different content.
                    WidgetDiagnostics.record(context, "publish_rejected", error.javaClass.simpleName)
                    result.error("snapshot_rejected", "Widget snapshot unavailable", null)
                }
            }
            "clearSnapshot" -> { WidgetRuntime.clear(context); result.success(null) }
            "removeVaultSnapshot" -> {
                try {
                    val id = arguments as? String ?: throw IllegalArgumentException()
                    WidgetRuntime.removeVault(context, id)
                    result.success(null)
                } catch (_: Exception) {
                    result.error("snapshot_cleanup_pending", "Vault snapshot cleanup pending; retry deletion", null)
                }
            }
            "widgetDiagnostics" -> result.success(WidgetDiagnostics.read(context))
            "takePendingAction" -> result.success(WidgetRuntime.actions.take())
            else -> result.notImplemented()
        }
    }
    fun dispose() {
        if (WidgetRuntime.actions.onAvailable === available) WidgetRuntime.actions.onAvailable = null
        channel.setMethodCallHandler(null)
    }
}
