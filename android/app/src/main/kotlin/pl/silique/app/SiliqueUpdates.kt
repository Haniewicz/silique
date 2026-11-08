package pl.silique.app

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/** Only publisher-verified APKs from the app's own update cache may be opened. */
class SiliqueUpdates(private val activity: Activity, messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, "silique.notes/updates").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "info" -> {
                        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
                        result.success(mapOf("version" to info.versionName, "build" to version(info)))
                    }
                    "installAndroid" -> result.success(install(call.arguments as String))
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("update_failed", error.message ?: SiliqueLanguage.text(activity, R.string.native_update_open_failed), null)
            }
        }
    }

    private fun version(info: android.content.pm.PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    private fun signatures(info: android.content.pm.PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return signatures?.map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { "%02x".format(it) }
        }?.toSet() ?: emptySet()
    }

    private fun install(path: String): String {
        val root = File(activity.cacheDir, "silique-updates").canonicalFile
        val apk = File(path).canonicalFile
        require(apk.parentFile == root && apk.name.matches(Regex("Silique-[0-9]+\\.apk")) && apk.isFile) {
            SiliqueLanguage.text(activity, R.string.native_update_invalid_file)
        }
        val manager = activity.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val current = manager.getPackageInfo(activity.packageName, flags)
        val update = manager.getPackageArchiveInfo(apk.path, flags)
            ?: throw IllegalArgumentException(SiliqueLanguage.text(activity, R.string.native_update_corrupt_installer))
        require(update.packageName == activity.packageName && version(update) > version(current)) {
            SiliqueLanguage.text(activity, R.string.native_update_not_newer)
        }
        val signers = signatures(current)
        require(signers.isNotEmpty() && signatures(update) == signers) { SiliqueLanguage.text(activity, R.string.native_update_invalid_signature) }
        if (Build.VERSION.SDK_INT >= 26 && !manager.canRequestPackageInstalls()) {
            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
            return "permission_required"
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", apk)
        activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
        return "started"
    }
}
