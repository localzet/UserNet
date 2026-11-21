package com.follow.clashx

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class QuickActionActivityTest {
    @Test
    fun permissionAndServiceTransitionsKeepTheTemporaryActivityAlive() {
        assertTrue(hold(permissionPending = true))
        assertTrue(hold(actionInFlight = true))
        assertTrue(hold(isRunRequested = true, runState = RunState.STOPPED))
        assertTrue(hold(runState = RunState.STOPPING))
    }

    @Test
    fun settledActionsReleaseTheTemporaryActivity() {
        assertFalse(hold())
    }

    @Test
    fun timeoutInvalidatesOnlyAnUndispatchedPermissionRequest() {
        assertTrue(
            QuickActionActivityPolicy.shouldInvalidatePermission(
                timedOut = true,
                permissionPending = true,
                actionInFlight = false,
            ),
        )
        assertFalse(
            QuickActionActivityPolicy.shouldInvalidatePermission(
                timedOut = false,
                permissionPending = true,
                actionInFlight = false,
            ),
        )
        assertFalse(
            QuickActionActivityPolicy.shouldInvalidatePermission(
                timedOut = true,
                permissionPending = false,
                actionInFlight = true,
            ),
        )
    }

    private fun hold(
        permissionPending: Boolean = false,
        actionInFlight: Boolean = false,
        isRunRequested: Boolean = false,
        runState: RunState = RunState.STOPPED,
    ) = QuickActionActivityPolicy.shouldHold(
        permissionPending = permissionPending,
        actionInFlight = actionInFlight,
        isRunRequested = isRunRequested,
        runState = runState,
    )
}
