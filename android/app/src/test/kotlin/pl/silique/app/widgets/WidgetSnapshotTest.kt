package pl.silique.app.widgets

import org.junit.Assert.*
import org.junit.Test

class WidgetSnapshotTest {
    private fun note(id: String = "note-1", text: String = "orchid body") = mapOf(
        "id" to id, "vaultId" to "vault-1", "title" to "Garden",
        "preview" to "A".repeat(600), "searchText" to text,
        "folder" to "Plants", "updatedAt" to "2026-10-23T10:00:00Z"
    )
    private fun payload(notes: List<Map<String, Any>> = listOf(note())) = mapOf(
        "schema" to 1, "notes" to notes, "lastVaultId" to "vault-1"
    )

    @Test fun snapshotRoundTripsFullSearchBodyWithBoundedRowPreview() {
        val snapshot = WidgetSnapshot.fromMap(payload())
        assertEquals("orchid body", snapshot.notes.single().searchText)
        assertTrue(snapshot.notes.single().preview.length <= 240)
        assertEquals(snapshot, WidgetSnapshot.decode(snapshot.encode()))
    }

    @Test fun searchUsesBodyTitleAndFolderCaseInsensitivelyWithAllTerms() {
        val snapshot = WidgetSnapshot.fromMap(payload())
        assertEquals(listOf("note-1"), snapshot.search("ORCHID garden").map { it.id })
        assertEquals(1, snapshot.search("plants").size)
        assertTrue(snapshot.search("orchid missing").isEmpty())
        assertEquals(1, snapshot.search("").size)
    }

    @Test fun malformedIdentifiersAreRejectedNotRepaired() {
        for (id in listOf("", " note-1", "note-1 ", "../secret", "a\nb")) {
            assertThrows(IllegalArgumentException::class.java) { WidgetSnapshot.fromMap(payload(listOf(note(id)))) }
        }
    }

    @Test fun wrongSchemaDuplicateIdsAndUntrustedVisibilityFlagsFailClosed() {
        assertThrows(IllegalArgumentException::class.java) { WidgetSnapshot.fromMap(payload() + ("schema" to 2)) }
        assertThrows(IllegalArgumentException::class.java) { WidgetSnapshot.fromMap(payload(listOf(note(), note()))) }
        for (flag in listOf("hidden", "deleted", "passwordProtected")) {
            assertThrows(IllegalArgumentException::class.java) {
                WidgetSnapshot.fromMap(payload(listOf(note() + (flag to true))))
            }
        }
    }
}
