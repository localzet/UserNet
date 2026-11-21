package com.follow.clashx.plugins

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UserNetNetworkTransitionTest {
    @Test
    fun `first physical network recovers a requested transport after relay exit`() {
        val transition = UserNetNetworkTransition<String>()

        val update = transition.update("wifi", recoveryRequested = true, relayReady = false)

        assertTrue(update.changed)
        assertTrue(update.shouldAnnounceReconnect)
        assertTrue(update.shouldRestart)
    }

    @Test
    fun `first network without a recovery request does not restart`() {
        val transition = UserNetNetworkTransition<String>()

        val update = transition.update("wifi", recoveryRequested = false, relayReady = false)

        assertTrue(update.changed)
        assertFalse(update.shouldAnnounceReconnect)
        assertFalse(update.shouldRestart)
        assertFalse(
            transition.update(
                "wifi",
                recoveryRequested = true,
                relayReady = false,
            ).changed,
        )
    }

    @Test
    fun `late first network callback does not restart a ready relay`() {
        val transition = UserNetNetworkTransition<String>()

        val update = transition.update("wifi", recoveryRequested = true, relayReady = true)

        assertTrue(update.changed)
        assertFalse(update.shouldAnnounceReconnect)
        assertFalse(update.shouldRestart)
    }

    @Test
    fun `first network callback recovers a relay that is not ready`() {
        val transition = UserNetNetworkTransition<String>()

        val update = transition.update("wifi", recoveryRequested = true, relayReady = false)

        assertTrue(update.changed)
        assertTrue(update.shouldAnnounceReconnect)
        assertTrue(update.shouldRestart)
    }

    @Test
    fun `restoring physical network restarts relay after offline period`() {
        val transition = UserNetNetworkTransition<String>()
        transition.update("wifi", recoveryRequested = true, relayReady = true)

        val disconnected = transition.update(null, recoveryRequested = true, relayReady = true)
        assertTrue(disconnected.shouldAnnounceReconnect)
        assertFalse(disconnected.shouldRestart)

        val restored = transition.update("cellular", recoveryRequested = true, relayReady = false)
        assertTrue(restored.shouldAnnounceReconnect)
        assertTrue(restored.shouldRestart)
    }

    @Test
    fun `initial offline observation followed by network availability restarts relay`() {
        val transition = UserNetNetworkTransition<String>()
        transition.update(null, recoveryRequested = true, relayReady = false)

        assertTrue(transition.update("wifi", recoveryRequested = true, relayReady = false).shouldRestart)
    }

    @Test
    fun `duplicate physical network observation does not restart relay`() {
        val transition = UserNetNetworkTransition<String>()
        transition.update("wifi", recoveryRequested = true, relayReady = true)

        val update = transition.update("wifi", recoveryRequested = true, relayReady = true)

        assertFalse(update.changed)
        assertFalse(update.shouldRestart)
    }

    @Test
    fun `new network revision invalidates a queued restart`() {
        val transition = UserNetNetworkTransition<String>()
        val pending = transition.update("wifi", recoveryRequested = true, relayReady = false)

        val lost = transition.update(null, recoveryRequested = true, relayReady = true)
        assertFalse(transition.isCurrent(pending.revision, "wifi"))
        assertTrue(transition.isCurrent(lost.revision, null))
    }

    @Test
    fun `relay readiness follows the active stage status`() {
        assertFalse(
            isUserNetRelayReady(
                processRunning = true,
                activeStage = "transport",
                controlState = "complete",
                transportState = "connecting",
            ),
        )
        assertTrue(
            isUserNetRelayReady(
                processRunning = true,
                activeStage = "control",
                controlState = "connected",
                transportState = "idle",
            ),
        )
        assertTrue(
            isUserNetRelayReady(
                processRunning = true,
                activeStage = "control",
                controlState = "complete",
                transportState = "idle",
            ),
        )
        assertTrue(
            isUserNetRelayReady(
                processRunning = true,
                activeStage = "transport",
                controlState = "complete",
                transportState = "connected",
            ),
        )
        assertFalse(
            isUserNetRelayReady(
                processRunning = false,
                activeStage = "transport",
                controlState = "complete",
                transportState = "connected",
            ),
        )
    }

    @Test
    fun `active relay keeps observer after engine detaches for recovery and DNS`() {
        val keepObserver = shouldKeepNetworkObserver(engineCount = 0, recoveryRequested = true)
        assertTrue(keepObserver)

        val transition = UserNetNetworkTransition<String>()
        transition.update("wifi", recoveryRequested = true, relayReady = true)
        val handover = transition.update(
            "cellular",
            recoveryRequested = true,
            relayReady = true,
        )
        assertTrue(handover.shouldRestart)

        val addresses = resolveOnPhysicalNetwork(
            selectNetwork = { if (keepObserver) "cellular" else null },
            lookup = { listOf("resolved on $it") },
        )
        assertEquals(listOf("resolved on cellular"), addresses)
    }

    @Test
    fun `idle plugin releases observer after last engine detaches`() {
        assertFalse(shouldKeepNetworkObserver(engineCount = 0, recoveryRequested = false))
        assertTrue(shouldKeepNetworkObserver(engineCount = 1, recoveryRequested = false))
    }
}
