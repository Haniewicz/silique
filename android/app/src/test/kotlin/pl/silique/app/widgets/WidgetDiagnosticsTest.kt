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

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class WidgetDiagnosticsTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()
    private val file get() = File(context.noBackupFilesDir, "silique-widgets.log")

    @Before fun reset() { file.delete() }

    @Test fun recordsTimestampedContentFreeLines() {
        WidgetDiagnostics.record(context, "read_ok", "notes=2 bytes=120")
        WidgetDiagnostics.record(context, "render", "widget=3 type=list state=notes=2")
        val text = WidgetDiagnostics.read(context)
        assertTrue(text.contains("read_ok notes=2 bytes=120"))
        assertTrue(text.contains("render widget=3 type=list state=notes=2"))
        assertTrue("Every line carries a pid", text.lineSequence().filter { it.isNotBlank() }.all { it.contains("pid=") })
        assertTrue("Timestamps must be ISO-8601", text.contains("T"))
    }

    @Test fun staysBoundedByTrimmingTheOldestLines() {
        repeat(4000) { WidgetDiagnostics.record(context, "render", "widget=1 state=notes=$it index=$it") }
        assertTrue(
            "Diagnostics must stay within the documented 64 KiB budget, was ${file.length()}",
            file.length() <= 64 * 1024 + 256
        )
        val text = WidgetDiagnostics.read(context)
        assertTrue(text.contains("widget=1"))
        assertTrue("Newest lines must survive trimming", text.contains("index=3999"))
    }

    @Test fun neverThrowsAndReportsNoLogAsEmpty() {
        assertEquals("", WidgetDiagnostics.read(context))
        // Recording after the file disappeared must start a fresh log, not crash.
        file.delete()
        WidgetDiagnostics.record(context, "read_ok", "notes=0")
        assertTrue(WidgetDiagnostics.read(context).contains("read_ok notes=0"))
    }
}
