package pl.silique.app.widgets

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import javax.crypto.KeyGenerator

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class SnapshotStoreTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private val snapshot get() = WidgetSnapshot.fromMap(mapOf(
        "schema" to 1, "lastVaultId" to "vault-1", "notes" to listOf(mapOf(
            "id" to "note-1", "vaultId" to "vault-1", "title" to "UNIQUE-PRIVATE-TITLE",
            "preview" to "preview", "searchText" to "UNIQUE-PRIVATE-BODY",
            "folder" to "folder", "updatedAt" to "2026-10-23T10:00:00Z"
        ))
    ))
    @Before fun reset() { SnapshotStore(context) { key }.clear() }

    @Test fun encryptedSnapshotOnlyLivesInNoBackupAndContainsNoPlaintext() {
        val store = SnapshotStore(context) { key }
        store.write(snapshot)
        assertEquals(snapshot, store.read())
        assertEquals(context.noBackupFilesDir.canonicalFile, store.file.parentFile.canonicalFile)
        val disk = store.file.readBytes().toString(Charsets.ISO_8859_1)
        assertFalse(disk.contains("UNIQUE-PRIVATE-TITLE"))
        assertFalse(disk.contains("UNIQUE-PRIVATE-BODY"))
        assertFalse(File(context.applicationInfo.dataDir, "shared_prefs/silique.widgets.xml").exists())
        assertFalse(File(store.file.path + ".tmp").exists())
    }

    @Test fun tamperingAndWrongKeystoreKeyFailClosed() {
        val store = SnapshotStore(context) { key }
        store.write(snapshot)
        val bytes = store.file.readBytes()
        bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
        store.file.writeBytes(bytes)
        assertTrue(store.read().notes.isEmpty())
        store.write(snapshot)
        val other = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        assertTrue(SnapshotStore(context) { other }.read().notes.isEmpty())
    }

    @Test fun truncatedFileAndClearReturnEmptyWithoutPlaintextFallback() {
        val store = SnapshotStore(context) { key }
        store.file.writeBytes(byteArrayOf(1, 2, 3))
        assertTrue(store.read().notes.isEmpty())
        store.write(snapshot)
        store.clear()
        assertFalse(store.file.exists())
        assertTrue(store.read().notes.isEmpty())
    }

    @Test fun transientKeystoreFailureKeepsSnapshotFileForLaterRecovery() {
        val store = SnapshotStore(context) { key }
        store.write(snapshot)
        assertTrue(store.file.exists())
        // A transiently unavailable key provider must not destroy the only copy.
        WidgetRuntime.storeFactory = { SnapshotStore(it) { throw IllegalStateException("keystore locked") } }
        try {
            val lockedStore = WidgetRuntime.store(context)
            assertTrue(lockedStore.read().notes.isEmpty())
            assertTrue("Snapshot must survive a transient Keystore outage", store.file.exists())
        } finally {
            WidgetRuntime.storeFactory = { SnapshotStore(it) }
        }
        // Once the key is reachable again, the previously written notes come back.
        assertEquals(snapshot, SnapshotStore(context) { key }.read())
    }
}