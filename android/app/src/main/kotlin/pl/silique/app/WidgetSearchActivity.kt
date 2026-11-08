package pl.silique.app

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.WindowManager
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.ListView
import pl.silique.app.widgets.WidgetIntents
import pl.silique.app.widgets.WidgetNote
import pl.silique.app.widgets.WidgetRuntime

/** Native-only modal: creating it never initializes a Flutter engine. */
class WidgetSearchActivity : Activity() {
    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(SiliqueLanguage.context(newBase))
    }

    private lateinit var query: EditText
    private lateinit var results: ListView
    private var presentation: ArrayAdapter<String>? = null
    private var rows: List<WidgetNote> = emptyList()
    private var revocationVersion = WidgetRuntime.revocationVersion
    private val changed: () -> Unit = {
        if (revocationVersion != WidgetRuntime.revocationVersion || WidgetRuntime.locked(this) || WidgetRuntime.snapshot(this).notes.isEmpty()) query.setText("")
        revocationVersion = WidgetRuntime.revocationVersion
        refresh()
    }
    private val languageChanged: () -> Unit = { renderPresentation() }
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) { refresh() }
    }
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        setContentView(R.layout.widget_search)
        window.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
        findViewById<android.view.View>(R.id.widget_search_backdrop).setOnClickListener { finish() }
        query = findViewById(R.id.widget_query)
        results = findViewById(R.id.widget_results)
        query.requestFocus()
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE or WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        WidgetRuntime.listen(changed)
        WidgetRuntime.listenLanguage(languageChanged)
        val filter = IntentFilter().apply { addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_USER_PRESENT); addAction(Intent.ACTION_SCREEN_ON) }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(screenReceiver, filter)
        query.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { refresh() }
            override fun afterTextChanged(s: Editable?) {}
        })
        results.setOnItemClickListener { _, _, position, _ ->
            val row = rows.getOrNull(position)
            val current = row?.let { selected -> WidgetRuntime.snapshot(this).notes.find { it.id == selected.id && it.vaultId == selected.vaultId } }
            if (current != null) {
                startActivity(WidgetIntents.noteIntent(this, current.vaultId, current.id).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
                finish()
            } else refresh()
        }
        refresh()
    }
    private fun refresh() {
        if (!::query.isInitialized) return
        if (WidgetRuntime.locked(this) && query.text.isNotEmpty()) query.setText("")
        rows = WidgetRuntime.snapshot(this).search(query.text.toString())
        renderPresentation()
    }
    private fun renderPresentation() {
        if (!::query.isInitialized) return
        query.hint = SiliqueLanguage.text(this, R.string.widget_search_hint)
        val labels = rows.map { it.title.ifEmpty { SiliqueLanguage.text(this, R.string.widget_untitled) } }
        val adapter = presentation
        if (adapter == null) {
            presentation = ArrayAdapter(this, android.R.layout.simple_list_item_2, android.R.id.text1, labels.toMutableList())
            results.adapter = presentation
        } else {
            adapter.setNotifyOnChange(false)
            adapter.clear()
            adapter.addAll(labels)
            adapter.notifyDataSetChanged()
        }
    }
    override fun onResume() { super.onResume(); refresh() }
    override fun onSaveInstanceState(outState: Bundle) {
        // Do not let Android persist native query/results into saved instance state.
        outState.clear()
    }
    override fun onDestroy() {
        WidgetRuntime.unlisten(changed)
        WidgetRuntime.unlistenLanguage(languageChanged)
        unregisterReceiver(screenReceiver)
        rows = emptyList()
        super.onDestroy()
    }
}

/** Reusable immutable launcher intents are converted into a fresh request on every tap. */
class WidgetActionActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val action = intent.getStringExtra("action")
        val snapshot = WidgetRuntime.snapshot(this)
        val vault = intent.getStringExtra("vaultId")
        val note = intent.getStringExtra("noteId")
        if (vault != null && !pl.silique.app.widgets.validWidgetId(vault) || note != null && !pl.silique.app.widgets.validWidgetId(note)) {
            finish()
            return
        }
        val launch = when (action) {
            "openNote" -> snapshot.notes.find { it.id == note && it.vaultId == vault }?.let { WidgetIntents.noteIntent(this, it.vaultId, it.id) }
            // Preserve a well-formed locked-vault target; Dart validates its
            // namespace and retains the request until the vault is unlocked.
            "newNote" -> WidgetIntents.newIntent(this, vault)
            "journal" -> WidgetIntents.journalIntent(this, vault)
            else -> null
        }
        if (launch != null) startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        finish()
    }
}
