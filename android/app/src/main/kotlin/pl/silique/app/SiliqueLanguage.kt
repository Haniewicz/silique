package pl.silique.app

import android.content.Context
import android.content.res.Configuration
import java.util.Locale

/** App-only resources: never mutate the device locale or recreate the Flutter editor. */
object SiliqueLanguage {
    private const val PREFERENCES = "silique.language"
    private const val LANGUAGE_CODE = "languageCode"

    fun code(base: Context): String =
        base.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getString(LANGUAGE_CODE, "en").let { if (it == "pl") "pl" else "en" }

    fun set(base: Context, languageCode: String) {
        require(languageCode == "en" || languageCode == "pl")
        val preferences = base.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        check(preferences.edit().putString(LANGUAGE_CODE, languageCode).commit() && code(base) == languageCode) {
            "Could not save the interface language"
        }
        pl.silique.app.widgets.WidgetRuntime.languageChanged(base)
    }

    fun context(base: Context): Context {
        val configuration = Configuration(base.resources.configuration)
        configuration.setLocale(Locale.forLanguageTag(code(base)))
        return base.createConfigurationContext(configuration)
    }

    fun text(base: Context, id: Int, vararg arguments: Any): String = context(base).getString(id, *arguments)
}

/** Own only this channel; replacing/disposal cannot remove existing app channels. */
class SiliqueLanguageBridge(private val context: Context, messenger: io.flutter.plugin.common.BinaryMessenger) {
    private val channel = io.flutter.plugin.common.MethodChannel(messenger, "silique/language")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getLanguage" -> result.success(SiliqueLanguage.code(context))
                "setLanguage" -> {
                    val languageCode = (call.arguments as? Map<*, *>)?.get("languageCode") as? String
                    if (languageCode != "en" && languageCode != "pl") {
                        result.error("invalid_arguments", "languageCode must be en or pl", null)
                    } else {
                        try {
                            SiliqueLanguage.set(context, languageCode)
                            result.success(null)
                        } catch (_: Exception) {
                            result.error("language_unavailable", "Could not save or refresh the interface language", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() { channel.setMethodCallHandler(null) }
}
