package pl.silique.app

import android.app.Activity
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.FlutterException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], qualifiers = "pl")
class NativeMessageLanguageTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()

    @Before fun clearLanguagePreference() {
        context.getSharedPreferences("silique.language", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test fun invalidUpdatePathUsesEnglishDefaultThenChangedLanguageOnSameChannel() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val messenger = Messenger()
        val bridge = SiliqueLanguageBridge(controller.get(), messenger)
        SiliqueUpdates(controller.get(), messenger)
        fun invalidPathMessage(): String? {
            try {
                messenger.call("silique.notes/updates", "installAndroid", "/outside-update-cache/Silique-999.apk")
                fail("An APK outside the update cache must be rejected")
            } catch (error: FlutterException) {
                assertEquals("update_failed", error.code)
                assertNull(error.details)
                return error.message
            }
            return null
        }
        try {
            assertEquals("en", messenger.call("silique/language", "getLanguage"))
            assertEquals("Invalid update file.", invalidPathMessage())
            messenger.call("silique/language", "setLanguage", mapOf("languageCode" to "pl"))
            assertEquals("Nieprawidłowy plik aktualizacji.", invalidPathMessage())
            messenger.call("silique/language", "setLanguage", mapOf("languageCode" to "en"))
            assertEquals("Invalid update file.", invalidPathMessage())
        } finally {
            bridge.dispose()
            controller.pause().stop().destroy()
        }
    }

    @Test fun nativeMessageResourcesHaveCompleteEnglishAndPolishContracts() {
        val detail = "Zażółć/日本語.md"
        data class Message(val name: String, val english: String, val polish: String, val arguments: List<Any> = emptyList())
        val messages = listOf(
            Message("native_storage_private_unavailable", "Private no-backup directory unavailable", "Prywatny katalog wyłączony z kopii zapasowych jest niedostępny"),
            Message("native_storage_picker_busy", "Picker is already open", "Wybór katalogu jest już otwarty"),
            Message("native_storage_picker_unavailable", "System folder picker unavailable: $detail", "Brak systemowego wyboru katalogu: $detail", listOf(detail)),
            Message("native_storage_access_denied", "The system did not grant persistent access to the folder: $detail", "System nie przyznał trwałego dostępu do katalogu: $detail", listOf(detail)),
            Message("native_storage_folder_failed", "Could not use the folder: $detail", "Nie udało się użyć katalogu: $detail", listOf(detail)),
            Message("native_import_picker_busy", "The folder picker is already open.", "Wybór folderu jest już otwarty."),
            Message("native_import_picker_failed", "Could not open the folder picker: $detail", "Nie udało się otworzyć wyboru folderu: $detail", listOf(detail)),
            Message("native_import_select_again", "Select the folder again.", "Wybierz folder ponownie."),
            Message("native_import_missing_path", "Missing path.", "Brak ścieżki."),
            Message("native_import_invalid_limit", "Invalid file limit.", "Nieprawidłowy limit pliku."),
            Message("native_import_file_outside_folder", "The file is not part of the selected folder.", "Plik nie jest częścią wybranego folderu."),
            Message("native_import_file_too_large", "File “$detail” exceeds the import limit.", "Plik „$detail” przekracza limit importu.", listOf(detail)),
            Message("native_import_file_read_failed", "Could not read file “$detail”.", "Nie udało się odczytać pliku „$detail”.", listOf(detail)),
            Message("native_import_vault_label", "Imported vault", "Importowany vault"),
            Message("native_import_folder_failed", "Could not open the folder: $detail", "Nie udało się otworzyć folderu: $detail", listOf(detail)),
            Message("native_import_folder_too_deep", "The folder has more than 12 levels.", "Folder ma więcej niż 12 poziomów."),
            Message("native_import_folder_cycle", "The file provider returned a folder loop.", "Dostawca plików zwrócił zapętlony folder."),
            Message("native_import_folder_read_failed", "Could not read folder “$detail”.", "Nie udało się odczytać folderu „$detail”.", listOf(detail)),
            Message("native_import_invalid_name", "Invalid file name.", "Nieprawidłowa nazwa pliku."),
            Message("native_import_too_many_files", "Too many files for one import. Split it into smaller parts.", "Zbyt wiele plików do jednego importu. Podziel go na części."),
            Message("native_import_duplicate_path", "Two entries have the same path: $detail", "Dwie pozycje mają tę samą ścieżkę: $detail", listOf(detail)),
            Message("native_update_open_failed", "Could not open the update.", "Nie udało się otworzyć aktualizacji."),
            Message("native_update_invalid_file", "Invalid update file.", "Nieprawidłowy plik aktualizacji."),
            Message("native_update_corrupt_installer", "Corrupt installer.", "Uszkodzony instalator."),
            Message("native_update_not_newer", "The installer is not a newer version of Silique.", "Instalator nie jest nowszą wersją Silique."),
            Message("native_update_invalid_signature", "Invalid installer signature.", "Nieprawidłowy podpis instalatora.")
        )
        for (language in listOf("en", "pl")) {
            SiliqueLanguage.set(context, language)
            for (message in messages) {
                val id = context.resources.getIdentifier(message.name, "string", context.packageName)
                assertTrue("Missing native message: ${message.name}", id != 0)
                assertEquals("$language: ${message.name}", if (language == "en") message.english else message.polish,
                    SiliqueLanguage.text(context, id, *message.arguments.toTypedArray()))
            }
        }
    }

    private class Messenger : BinaryMessenger {
        private val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }
        fun call(channel: String, method: String, arguments: Any? = null): Any? {
            val handler = handlers[channel] ?: error("Missing MethodChannel: $channel")
            var reply: ByteBuffer? = null
            handler.onMessage(StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, arguments)).apply { flip() }) { reply = it }
            assertNotNull("MethodChannel must reply", reply)
            return StandardMethodCodec.INSTANCE.decodeEnvelope(reply!!.apply { flip() })
        }
    }
}
