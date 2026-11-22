package com.follow.clashx

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.core.content.ContextCompat
import androidx.core.content.pm.ShortcutManagerCompat
import com.follow.clashx.common.GlobalState
import com.follow.clashx.common.QuickAction
import com.follow.clashx.common.QuickActionIntentAuthorization
import com.follow.clashx.common.action
import com.follow.clashx.common.shortcutId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

class QuickActionActivity : Activity() {
    private var hold: Job? = null
    private var permissionPending = false
    private var actionInFlight = false
    private var action: QuickAction? = null
    private var permissionRequest: RunRequest? = null
    private var permissionSource: Intent? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.attributes = window.attributes.apply { alpha = 0f }
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)

        permissionPending = savedInstanceState?.getBoolean(STATE_PERMISSION_PENDING) ?: false
        action = savedInstanceState?.getString(STATE_ACTION)?.let(::parseAction)
        permissionSource = savedInstanceState?.readIntent(STATE_PERMISSION_INTENT)

        if (savedInstanceState == null) {
            handle(intent)
        } else if (permissionPending && action != null) {
            val reservation = ServiceState.reregisterQuickAction(action!!)
            action = reservation.action
            permissionPending = reservation.shouldDispatch
            if (reservation.shouldDispatch) {
                permissionRequest = reservation.request
                permissionSource = permissionSource ?: Intent(intent)
            }
            if (permissionPending &&
                !QuickActionIntentAuthorization.isAuthorized(this, permissionSource!!)
            ) {
                permissionPending = false
                finish()
            }
        }
        holdUntilSettled()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(STATE_PERMISSION_PENDING, permissionPending)
        action?.let { outState.putString(STATE_ACTION, it.name) }
        outState.putParcelable(STATE_PERMISSION_INTENT, permissionSource)
        super.onSaveInstanceState(outState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        permissionPending = false
        val pendingRequest = permissionRequest ?: return
        val source = permissionSource ?: return
        if (!QuickActionIntentAuthorization.isAuthorized(this, source) ||
            !ServiceState.isCurrentQuickAction(pendingRequest)
        ) {
            finishIfSettled()
            return
        }
        if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
            cancelQuickAction(pendingRequest)
            return
        }
        permissionRequest = null
        permissionSource = null
        continueAfterNotificationPermission(pendingRequest, source)
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_PERMISSION_REQUEST) return
        permissionPending = false
        val pendingRequest = permissionRequest ?: return
        val source = permissionSource ?: return
        if (!QuickActionIntentAuthorization.isAuthorized(this, source) ||
            !ServiceState.isCurrentQuickAction(pendingRequest)
        ) {
            finishIfSettled()
            return
        }
        if (resultCode != RESULT_OK) {
            cancelQuickAction(pendingRequest)
            return
        }
        permissionRequest = null
        permissionSource = null
        dispatch(pendingRequest, source)
    }

    override fun onDestroy() {
        hold?.cancel()
        super.onDestroy()
    }

    private fun handle(intent: Intent) {
        if (!QuickActionIntentAuthorization.isAuthorized(this, intent)) {
            finish()
            return
        }
        val requestedAction = QuickAction.entries.firstOrNull { it.action == intent.action }
        if (requestedAction == null) {
            finish()
            return
        }

        ShortcutManagerCompat.reportShortcutUsed(this, requestedAction.shortcutId)
        val reservation = ServiceState.reserveQuickAction(requestedAction)
        if (permissionPending && permissionRequest?.let {
                !ServiceState.isCurrentQuickAction(it)
            } == true
        ) {
            permissionPending = false
            permissionRequest = null
            permissionSource = null
        }
        action = reservation.action
        if (!reservation.shouldDispatch) return

        if (reservation.action == QuickAction.START && needsConfiguration()) {
            ServiceState.invalidateQuickAction(reservation.request)
            startActivity(
                Intent(this, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                ),
            )
            finish()
            return
        }
        requestRequiredPermissions(reservation, Intent(intent))
    }

    private fun needsConfiguration(): Boolean {
        val state = GlobalState.application.sharedState
        return state.setupParams == null || state.vpnOptions == null
    }

    private fun requestRequiredPermissions(
        reservation: QuickActionReservation,
        source: Intent,
    ) {
        if (!ServiceState.isCurrentQuickAction(reservation.request)) {
            finishIfSettled()
            return
        }
        if (reservation.action != QuickAction.START) {
            dispatch(reservation.request, source)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            permissionPending = true
            permissionRequest = reservation.request
            permissionSource = source
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST,
            )
            return
        }
        continueAfterNotificationPermission(reservation.request, source)
    }

    private fun continueAfterNotificationPermission(request: RunRequest, source: Intent) {
        if (!ServiceState.isCurrentQuickAction(request)) {
            finishIfSettled()
            return
        }
        val options = GlobalState.application.sharedState.vpnOptions
        if (options?.enable == true) {
            val permission = VpnService.prepare(this)
            if (permission != null) {
                permissionPending = true
                permissionRequest = request
                permissionSource = source
                @Suppress("DEPRECATION")
                startActivityForResult(permission, VPN_PERMISSION_REQUEST)
                return
            }
        }
        dispatch(request, source)
    }

    private fun dispatch(request: RunRequest, source: Intent) {
        if (!QuickActionIntentAuthorization.isAuthorized(this, source) ||
            !ServiceState.isCurrentQuickAction(request)
        ) {
            finishIfSettled()
            return
        }
        permissionPending = false
        actionInFlight = true
        GlobalState.launch {
            try {
                ServiceState.handleQuickAction(request)
            } finally {
                withContext(Dispatchers.Main.immediate) {
                    actionInFlight = false
                    finishIfSettled()
                }
            }
        }
    }

    private fun cancelQuickAction(request: RunRequest) {
        permissionPending = false
        permissionRequest = null
        permissionSource = null
        GlobalState.launch {
            ServiceState.cancelQuickAction(request)
            withContext(Dispatchers.Main.immediate) { finishIfSettled() }
        }
    }

    private fun holdUntilSettled() {
        hold?.cancel()
        hold = GlobalState.launch(Dispatchers.Main.immediate) {
            val waitResult = withTimeoutOrNull(HOLD_TIMEOUT_MILLIS) {
                while (QuickActionActivityPolicy.shouldHold(
                        permissionPending = permissionPending && permissionRequest?.let {
                            ServiceState.isCurrentQuickAction(it)
                        } == true,
                        actionInFlight = actionInFlight,
                        isRunRequested = ServiceState.isRunRequested,
                        runState = ServiceState.runState.value,
                    )
                ) {
                    delay(HOLD_POLL_MILLIS)
                }
            }
            val timedOut = waitResult == null
            if (QuickActionActivityPolicy.shouldInvalidatePermission(
                    timedOut = timedOut,
                    permissionPending = permissionPending && permissionRequest?.let {
                        ServiceState.isCurrentQuickAction(it)
                    } == true,
                    actionInFlight = actionInFlight,
                )
            ) {
                permissionRequest?.let { ServiceState.invalidateQuickAction(it) }
                permissionPending = false
            }
            if (!isFinishing) finish()
        }
    }

    private fun finishIfSettled() {
        if (!QuickActionActivityPolicy.shouldHold(
                permissionPending = permissionPending && permissionRequest?.let {
                    ServiceState.isCurrentQuickAction(it)
                } == true,
                actionInFlight = actionInFlight,
                isRunRequested = ServiceState.isRunRequested,
                runState = ServiceState.runState.value,
            ) && !isFinishing
        ) {
            finish()
        }
    }

    private fun parseAction(name: String): QuickAction? =
        QuickAction.entries.firstOrNull { it.name == name }

    private companion object {
        const val STATE_PERMISSION_PENDING = "quick_action_permission_pending"
        const val STATE_ACTION = "quick_action_action"
        const val STATE_PERMISSION_INTENT = "quick_action_permission_intent"
        const val NOTIFICATION_PERMISSION_REQUEST = 4101
        const val VPN_PERMISSION_REQUEST = 4102
        const val HOLD_POLL_MILLIS = 100L
        const val HOLD_TIMEOUT_MILLIS = 30_000L
    }
}

private fun Bundle.readIntent(key: String): Intent? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelable(key, Intent::class.java)
    } else {
        @Suppress("DEPRECATION")
        getParcelable(key)
    }

internal object QuickActionActivityPolicy {
    fun shouldHold(
        permissionPending: Boolean,
        actionInFlight: Boolean,
        isRunRequested: Boolean,
        runState: RunState,
    ): Boolean = permissionPending || actionInFlight ||
        (isRunRequested && runState != RunState.STARTED) ||
        (!isRunRequested && runState == RunState.STOPPING)

    fun shouldInvalidatePermission(
        timedOut: Boolean,
        permissionPending: Boolean,
        actionInFlight: Boolean,
    ): Boolean = timedOut && permissionPending && !actionInFlight
}
