package com.follow.clashx

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.core.content.ContextCompat
import androidx.core.content.pm.ShortcutManagerCompat
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.QuickAction
import com.follow.clashx.common.action
import com.follow.clashx.common.shortcutId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class QuickActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle(intent)
    }

    // A caller that repeats an action before this instance is gone reaches it here, not onCreate.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent) {
        val action = QuickAction.entries.firstOrNull { it.action == intent.action }
            ?: run {
                finish()
                return
            }
        ShortcutManagerCompat.reportShortcutUsed(this, action.shortcutId)
        if (needsInteractiveSetup(action)) {
            startActivity(
                Intent(this, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                ),
            )
            finish()
            return
        }
        GlobalState.launch {
            try {
                ServiceState.handleQuickAction(action)
            } finally {
                withContext(Dispatchers.Main.immediate) {
                    if (!isFinishing) finish()
                }
            }
        }
    }

    private fun needsInteractiveSetup(action: QuickAction): Boolean {
        val isStarting = when (action) {
            QuickAction.START -> !ServiceState.isRunRequested
            QuickAction.TOGGLE -> !ServiceState.isRunRequested
            QuickAction.STOP -> false
        }
        if (!isStarting) return false

        val state = GlobalState.application.sharedState
        if (state.setupParams == null || state.vpnOptions == null) return true
        if (state.vpnOptions.enable && VpnService.prepare(this) != null) return true
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
    }
}
