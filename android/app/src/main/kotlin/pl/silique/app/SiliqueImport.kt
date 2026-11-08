package pl.silique.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.Executors

/** Read-only SAF import; cloud providers need no filesystem path or write grant. */
class SiliqueImport(private val activity: Activity, messenger: BinaryMessenger) {
    private val requestCode = 4730
    private val channel = MethodChannel(messenger, "silique.notes/import")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var tree: Uri? = null
    private var token: String? = null
    private val files = mutableMapOf<String, Uri>()
    private val excluded = setOf(".obsidian", ".git", ".trash", ".DS_Store", "Thumbs.db")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pick" -> {
                    if (pending != null) {
                        result.error("busy", SiliqueLanguage.text(activity, R.string.native_import_picker_busy), null)
                    } else {
                        pending = result
                        try {
                            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                            }, requestCode)
                        } catch (error: Exception) {
                            pending = null
                            result.error("picker", SiliqueLanguage.text(activity, R.string.native_import_picker_failed, "${error.message}"), null)
                        }
                    }
                }
                "list", "read" -> {
                    val requestedToken = call.argument<String>("token")
                    worker.execute {
                        try {
                            check(requestedToken != null && requestedToken == token) { SiliqueLanguage.text(activity, R.string.native_import_select_again) }
                            val value: Any = if (call.method == "list") list() else {
                                val path = call.argument<String>("path") ?: error(SiliqueLanguage.text(activity, R.string.native_import_missing_path))
                                val limit = call.argument<Int>("limit") ?: 0
                                require(limit in 0..268435456) { SiliqueLanguage.text(activity, R.string.native_import_invalid_limit) }
                                val uri = files[path] ?: error(SiliqueLanguage.text(activity, R.string.native_import_file_outside_folder))
                                activity.contentResolver.openInputStream(uri)?.use { input ->
                                    val output = ByteArrayOutputStream()
                                    val buffer = ByteArray(65536)
                                    while (true) {
                                        val count = input.read(buffer)
                                        if (count < 0) break
                                        require(output.size().toLong() + count <= limit) { SiliqueLanguage.text(activity, R.string.native_import_file_too_large, path) }
                                        output.write(buffer, 0, count)
                                    }
                                    output.toByteArray()
                                } ?: error(SiliqueLanguage.text(activity, R.string.native_import_file_read_failed, path))
                            }
                            main.post { result.success(value) }
                        } catch (error: Exception) {
                            main.post { result.error("import", error.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun onActivityResult(code: Int, status: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        val result = pending ?: return true
        pending = null
        val uri = data?.data
        if (status != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            val document = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
            val label = activity.contentResolver.query(document,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: SiliqueLanguage.text(activity, R.string.native_import_vault_label)
            tree = uri
            token = UUID.randomUUID().toString()
            result.success(mapOf("label" to label, "token" to token))
        } catch (error: Exception) {
            result.error("folder", SiliqueLanguage.text(activity, R.string.native_import_folder_failed, "${error.message}"), null)
        }
        return true
    }

    private fun list(): List<Map<String, Any>> {
        val root = tree ?: error(SiliqueLanguage.text(activity, R.string.native_import_select_again))
        val result = mutableListOf<Map<String, Any>>()
        val visited = mutableSetOf<String>()
        files.clear()
        fun visit(id: String, parent: String) {
            require(parent.isEmpty() || parent.split('/').size <= 12) { SiliqueLanguage.text(activity, R.string.native_import_folder_too_deep) }
            check(visited.add(id)) { SiliqueLanguage.text(activity, R.string.native_import_folder_cycle) }
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(root, id)
            val projection = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE)
            val cursor = activity.contentResolver.query(children, projection, null, null, null)
                ?: error(SiliqueLanguage.text(activity, R.string.native_import_folder_read_failed, parent))
            cursor.use {
                while (it.moveToNext()) {
                    val childId = it.getString(0)
                    val name = it.getString(1)
                    if (name in excluded) continue
                    require(name.isNotEmpty() && name != "." && name != ".." && !name.contains('/') && !name.contains('\\')) { SiliqueLanguage.text(activity, R.string.native_import_invalid_name) }
                    val path = if (parent.isEmpty()) name else "$parent/$name"
                    val directory = it.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR
                    check(result.size < 20000) { SiliqueLanguage.text(activity, R.string.native_import_too_many_files) }
                    result.add(mapOf("path" to path, "directory" to directory))
                    if (directory) visit(childId, path) else {
                        check(!files.containsKey(path)) { SiliqueLanguage.text(activity, R.string.native_import_duplicate_path, path) }
                        files[path] = DocumentsContract.buildDocumentUriUsingTree(root, childId)
                    }
                }
            }
        }
        visit(DocumentsContract.getTreeDocumentId(root), "")
        return result
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }
}
