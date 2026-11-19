package pl.silique.app.widgets

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.BadPaddingException
import javax.crypto.Cipher
import javax.crypto.IllegalBlockSizeException
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** What a snapshot read produced, without collapsing "unreadable" into "empty". */
sealed class SnapshotRead {
    /** The stored snapshot was decrypted and decoded. */
    class Ok(val snapshot: WidgetSnapshot) : SnapshotRead()

    /** No snapshot is stored: never published, or deliberately cleared. */
    object Missing : SnapshotRead()

    /** Stored but unreadable right now (Keystore not usable, transient I/O). The file is kept. */
    class Unavailable(val error: Exception) : SnapshotRead()

    /** The stored bytes cannot be decrypted with the current key; the file was dropped. */
    object Corrupt : SnapshotRead()
}

class SnapshotStore(context: Context, private val keyProvider: () -> SecretKey = { deviceKey() }) {
    private val context = context.applicationContext
    val file = File(this.context.noBackupFilesDir, "silique-widgets.enc")
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
        WidgetDiagnostics.record(this.context, "write_ok",
            "notes=${snapshot.notes.size} bytes=${encrypted.size}")
    }

    /**
     * Reads the snapshot and reports why it is unavailable instead of silently
     * looking empty. Only a real decryption/format failure drops the file; a
     * transiently unusable key or an I/O blip must keep the only copy.
     */
    fun readOutcome(): SnapshotRead = synchronized(lock) {
        // Resolve the key first and independently: a transiently unavailable key
        // (credential-encrypted Keystore still locked before first unlock) must
        // never destroy the only encrypted copy of the snapshot.
        val key = try {
            keyProvider()
        } catch (error: Exception) {
            WidgetDiagnostics.record(context, "read_key_unavailable", error.javaClass.simpleName)
            return@synchronized SnapshotRead.Unavailable(error)
        }
        val bytes = try {
            atomic.openRead().use { stream ->
                require(stream.available() <= MAX_BYTES) { "Widget snapshot is too large" }
                stream.readBytes()
            }
        } catch (error: java.io.IOException) {
            if (error is java.io.FileNotFoundException) {
                WidgetDiagnostics.record(context, "read_missing")
                return@synchronized SnapshotRead.Missing
            }
            WidgetDiagnostics.record(context, "read_io", error.javaClass.simpleName)
            return@synchronized SnapshotRead.Unavailable(error)
        } catch (error: IllegalArgumentException) {
            // Framing this large can never become readable again.
            WidgetDiagnostics.record(context, "read_oversized")
            return@synchronized corrupt()
        } catch (error: Exception) {
            WidgetDiagnostics.record(context, "read_io", error.javaClass.simpleName)
            return@synchronized SnapshotRead.Unavailable(error)
        }
        if (bytes.size < MIN_BYTES || bytes[0] != VERSION) return@synchronized corrupt()
        val cipher = try {
            Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
                updateAAD(aad)
            }
        } catch (error: Exception) {
            // The key object exists but cannot be used yet: keep the ciphertext.
            WidgetDiagnostics.record(context, "read_key_unavailable", error.javaClass.simpleName)
            return@synchronized SnapshotRead.Unavailable(error)
        }
        val plain = try {
            cipher.doFinal(bytes.copyOfRange(13, bytes.size))
        } catch (_: BadPaddingException) {
            return@synchronized corrupt()
        } catch (_: IllegalBlockSizeException) {
            return@synchronized corrupt()
        } catch (error: GeneralSecurityException) {
            WidgetDiagnostics.record(context, "read_key_unavailable", error.javaClass.simpleName)
            return@synchronized SnapshotRead.Unavailable(error)
        }
        val snapshot = try {
            WidgetSnapshot.decode(plain)
        } catch (_: Exception) {
            return@synchronized corrupt()
        }
        WidgetDiagnostics.record(context, "read_ok",
            "notes=${snapshot.notes.size} bytes=${bytes.size}")
        SnapshotRead.Ok(snapshot)
    }

    fun read(): WidgetSnapshot = when (val outcome = readOutcome()) {
        is SnapshotRead.Ok -> outcome.snapshot
        else -> WidgetSnapshot()
    }

    private fun corrupt(): SnapshotRead {
        WidgetDiagnostics.record(context, "read_corrupt")
        atomic.delete()
        return SnapshotRead.Corrupt
    }

    fun clear() = synchronized(lock) {
        atomic.delete()
        WidgetDiagnostics.record(context, "cleared")
    }
    fun removeVault(id: String) = synchronized(lock) {
        require(validWidgetId(id))
        when (val outcome = readOutcome()) {
            is SnapshotRead.Ok -> {
                val snapshot = outcome.snapshot
                val remaining = snapshot.notes.filter { it.vaultId != id }
                if (remaining.isEmpty()) {
                    atomic.delete()
                    check(!file.exists()) { "Widget snapshot cleanup pending" }
                } else {
                    write(WidgetSnapshot(remaining,
                        snapshot.lastVaultId?.takeIf { it != id } ?: remaining.first().vaultId))
                }
            }
            // Nothing of ours is left on disk to purge (already cleared, or the
            // corrupt copy was dropped while classifying it).
            SnapshotRead.Missing, SnapshotRead.Corrupt -> Unit
            // A transient read failure is not "no notes left": keep the only copy
            // and let the caller retry the revocation.
            is SnapshotRead.Unavailable -> throw IllegalStateException("Widget snapshot unavailable")
        }
        WidgetDiagnostics.record(context, "remove_vault")
    }
    companion object {
        private val lock = Any()
        private val aad = "silique.widgets.snapshot.v1".toByteArray(Charsets.UTF_8)
        private val VERSION = 1.toByte()
        private const val MIN_BYTES = 29
        private const val MAX_BYTES = 32 * 1024 * 1024
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
