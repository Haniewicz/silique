package pl.silique.app.widgets

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SnapshotStore(context: Context, private val keyProvider: () -> SecretKey = { deviceKey() }) {
    val file = File(context.noBackupFilesDir, "silique-widgets.enc")
    private val atomic = AtomicFile(file)
    fun write(snapshot: WidgetSnapshot) = synchronized(lock) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, keyProvider())
        cipher.updateAAD(aad)
        val encrypted = cipher.doFinal(snapshot.encode())
        val stream = atomic.startWrite()
        try {
            stream.write(byteArrayOf(1)); stream.write(cipher.iv); stream.write(encrypted)
            atomic.finishWrite(stream)
        } catch (error: Exception) { atomic.failWrite(stream); throw error }
    }
    fun read(): WidgetSnapshot = synchronized(lock) {
        try {
            val bytes = atomic.openRead().use { stream ->
                require(stream.available() <= 32 * 1024 * 1024)
                stream.readBytes()
            }
            require(bytes.size >= 29 && bytes[0] == 1.toByte())
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, keyProvider(), GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
            cipher.updateAAD(aad)
            WidgetSnapshot.decode(cipher.doFinal(bytes.copyOfRange(13, bytes.size)))
        } catch (_: Exception) { atomic.delete(); WidgetSnapshot() }
    }
    fun clear() = synchronized(lock) { atomic.delete() }
    fun removeVault(id: String) = synchronized(lock) {
        require(validWidgetId(id))
        val snapshot = read()
        val remaining = snapshot.notes.filter { it.vaultId != id }
        if (remaining.isEmpty()) {
            atomic.delete()
            check(!file.exists()) { "Widget snapshot cleanup pending" }
        } else {
            write(WidgetSnapshot(remaining,
                snapshot.lastVaultId?.takeIf { it != id } ?: remaining.first().vaultId))
        }
    }
    companion object {
        private val lock = Any()
        private val aad = "silique.widgets.snapshot.v1".toByteArray(Charsets.UTF_8)
        private fun deviceKey(): SecretKey = synchronized(lock) {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val alias = "silique.widgets.snapshot.v1"
            (store.getKey(alias, null) as? SecretKey) ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
            }.generateKey()
        }
    }
}
