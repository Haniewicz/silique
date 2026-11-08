package pl.silique.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Storage location picker for Android.
 *
 * `ACTION_OPEN_DOCUMENT_TREE` hands out a document tree, not a filesystem path,
 * and SQLite needs a path. The picker therefore:
 *  1. persists the tree permission (`takePersistableUriPermission`) so the grant
 *     survives a restart,
 *  2. proves that grant with a real create/write/read/delete through the
 *     document provider (no `DocumentFile` dependency, plain ContentResolver),
 *  3. derives a filesystem path for the tree when the provider exposes one, so
 *     Dart can verify that the vault database really can live there.
 *
 * Nothing is written anywhere else: when the tree has no writable path the Dart
 * side asks the user explicitly instead of silently picking a directory.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "silique.notes/storage"
    private val requestTree = 4711
    private var pendingResult: MethodChannel.Result? = null
    private var vaultImporter: SiliqueImport? = null
    private var widgets: SiliqueWidgets? = null
    private var imageClipboard: SiliqueClipboard? = null
    private var credentialDirectoryChannel: MethodChannel? = null
    private var language: SiliqueLanguageBridge? = null

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(SiliqueLanguage.context(newBase))
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        pl.silique.app.widgets.WidgetRuntime.actions.accept(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pl.silique.app.widgets.WidgetRuntime.actions.accept(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        language?.dispose()
        language = SiliqueLanguageBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        credentialDirectoryChannel?.setMethodCallHandler(null)
        credentialDirectoryChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "silique.notes/credential-directory"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "noBackupDirectory" || call.arguments != null) {
                    result.notImplemented()
                } else {
                    try {
                        // Context supplies the actual OS-excluded backup path;
                        // canonicalPath removes Android's /data/data alias.
                        result.success(noBackupFilesDir.canonicalPath)
                    } catch (_: Exception) {
                        result.error("unavailable", SiliqueLanguage.text(this, R.string.native_storage_private_unavailable), null)
                    }
                }
            }
        }
        SiliqueUpdates(this, flutterEngine.dartExecutor.binaryMessenger)
        widgets?.dispose()
        widgets = SiliqueWidgets(this, flutterEngine.dartExecutor.binaryMessenger)
        vaultImporter?.dispose()
        vaultImporter = SiliqueImport(this, flutterEngine.dartExecutor.binaryMessenger)
        imageClipboard?.dispose()
        imageClipboard = SiliqueClipboard(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> {
                        if (pendingResult != null) {
                            result.error("busy", SiliqueLanguage.text(this, R.string.native_storage_picker_busy), null)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
                            )
                        }
                        try {
                            startActivityForResult(intent, requestTree)
                        } catch (error: Exception) {
                            pendingResult = null
                            result.error(
                                "unavailable",
                                SiliqueLanguage.text(this, R.string.native_storage_picker_unavailable, "${error.message}"),
                                null
                            )
                        }
                    }
                    // macOS uses this channel for security-scoped bookmarks; on
                    // Android the grant is persisted by `pick`, so this keeps one
                    // call site in Dart.
                    "remember" -> result.success(null)
                    "forget" -> {
                        preferences().edit().remove("treeUri").apply()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun preferences() = getSharedPreferences("silique.storage", Context.MODE_PRIVATE)

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (vaultImporter?.onActivityResult(requestCode, resultCode, data) == true) return
        if (requestCode != requestTree) return
        val result = pendingResult ?: return
        pendingResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
            val writable = probeWrite(uri)
            if (writable) {
                preferences().edit().putString("treeUri", uri.toString()).apply()
            }
            result.success(
                mapOf(
                    "uri" to uri.toString(),
                    "label" to treeLabel(uri),
                    "path" to filesystemPath(uri),
                    "writable" to writable
                )
            )
        } catch (error: SecurityException) {
            result.error(
                "denied",
                SiliqueLanguage.text(this, R.string.native_storage_access_denied, "${error.message}"),
                null
            )
        } catch (error: Exception) {
            result.error("failed", SiliqueLanguage.text(this, R.string.native_storage_folder_failed, "${error.message}"), null)
        }
    }

    override fun onDestroy() {
        language?.dispose()
        language = null
        credentialDirectoryChannel?.setMethodCallHandler(null)
        credentialDirectoryChannel = null
        widgets?.dispose()
        imageClipboard?.dispose()
        vaultImporter?.dispose()
        super.onDestroy()
    }

    private fun treeDocumentUri(treeUri: Uri): Uri = DocumentsContract.buildDocumentUriUsingTree(
        treeUri,
        DocumentsContract.getTreeDocumentId(treeUri)
    )

    private fun treeLabel(treeUri: Uri): String = try {
        contentResolver.query(treeDocumentUri(treeUri), null, null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
        } ?: treeUri.lastPathSegment ?: treeUri.toString()
    } catch (error: Exception) {
        treeUri.lastPathSegment ?: treeUri.toString()
    }

    /** Real create/write/read/delete in the granted tree; proof of access. */
    private fun probeWrite(treeUri: Uri): Boolean = try {
        val parent = treeDocumentUri(treeUri)
        val created: Uri? = DocumentsContract.createDocument(
            contentResolver, parent, "text/plain", "silique-write-test"
        )
        if (created == null) {
            false
        } else {
            val written = contentResolver.openOutputStream(created, "w")?.use { stream ->
                stream.write("ok".toByteArray())
                stream.flush()
                true
            } ?: false
            val readBack = contentResolver.openInputStream(created)?.use { stream ->
                stream.bufferedReader().readText()
            }
            DocumentsContract.deleteDocument(contentResolver, created)
            written && readBack == "ok"
        }
    } catch (error: Exception) {
        false
    }

    /**
     * Best-effort mapping of a document tree onto a filesystem path.
     *
     * Only the primary volume is mapped; providers such as Google Drive or
     * Downloads have no path at all, and then Dart must not assume one.
     */
    private fun filesystemPath(uri: Uri): String? {
        val documentId = try {
            DocumentsContract.getTreeDocumentId(uri)
        } catch (error: Exception) {
            return null
        }
        val parts = documentId.split(":", limit = 2)
        if (parts.size != 2 || parts[0] != "primary") return null
        val base = Environment.getExternalStorageDirectory() ?: return null
        val relative = parts[1]
        val target = if (relative.isEmpty()) base else File(base, relative)
        return target.absolutePath
    }
}
