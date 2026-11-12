package pl.silique.app.widgets

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import javax.crypto.KeyGenerator

/**
 * Cold-start refresh contract, phrased against only framework + pre-existing
 * symbols so it fails on the pre-fix code base (negative control): a manifest
 * receiver for BOOT_COMPLETED must re-render from a fresh process, guarded by
 * RECEIVE_BOOT_COMPLETED and never exported.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class WidgetColdStartTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()

    @Before fun seed() {
        WidgetRuntime.screenOff = false
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        WidgetRuntime.storeFactory = { SnapshotStore(it) { key } }
    }

    @Test fun bootCompletedRedrawsWidgetsWithoutTheAppProcess() {
        var redraws = 0
        val listener: () -> Unit = { redraws++ }
        WidgetRuntime.listen(listener)
        try {
            context.sendBroadcast(Intent(Intent.ACTION_BOOT_COMPLETED))
            ShadowLooper.shadowMainLooper().idle()
            assertEquals("BOOT_COMPLETED must re-render the widget from a cold process", 1, redraws)
        } finally {
            WidgetRuntime.unlisten(listener)
        }
    }

    @Test fun manifestDeclaresColdStartReceiverAndBootPermission() {
        val pm = context.packageManager
        val boot = pm.queryBroadcastReceivers(
            Intent(Intent.ACTION_BOOT_COMPLETED).setPackage(context.packageName), 0
        )
        val receiver = boot.find { it.activityInfo.name == "pl.silique.app.widgets.WidgetRefreshReceiver" }
        assertNotNull("A manifest receiver for BOOT_COMPLETED must exist", receiver)
        assertFalse("Cold-start receiver must not be exported", receiver!!.activityInfo.exported)

        val info = pm.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        assertTrue(
            "RECEIVE_BOOT_COMPLETED must be requested",
            (info.requestedPermissions ?: emptyArray()).contains(android.Manifest.permission.RECEIVE_BOOT_COMPLETED)
        )
    }
}