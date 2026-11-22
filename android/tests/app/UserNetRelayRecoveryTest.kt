package com.follow.clashx.plugins

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class UserNetRelayRecoveryTest {
    @Test
    fun `retry delays back off and stop after the configured budget`() {
        val policy = UserNetRelayRecoveryPolicy(
            maxAttempts = 5,
            initialDelayMillis = 1_000,
            maxDelayMillis = 4_000,
            attemptWindowMillis = 60_000,
        )

        assertEquals(1_000L, policy.nextDelayMillis(0))
        assertEquals(2_000L, policy.nextDelayMillis(1))
        assertEquals(4_000L, policy.nextDelayMillis(2))
        assertEquals(4_000L, policy.nextDelayMillis(3))
        assertEquals(4_000L, policy.nextDelayMillis(4))
        assertNull(policy.nextDelayMillis(5))
    }

    @Test
    fun `stable relay resets the backoff and rolling retry budget`() {
        val policy = UserNetRelayRecoveryPolicy(
            maxAttempts = 3,
            initialDelayMillis = 1_000,
            stablePeriodMillis = 10_000,
            attemptWindowMillis = 60_000,
        )

        assertEquals(1_000L, policy.nextDelayMillis(0))
        policy.markReady(1)
        assertEquals(1_000L, policy.nextDelayMillis(11_000))
        policy.markReady(11_001)
        assertEquals(1_000L, policy.nextDelayMillis(22_001))
        assertEquals(2_000L, policy.nextDelayMillis(23_000))
        assertEquals(4_000L, policy.nextDelayMillis(24_000))
        assertNull(policy.nextDelayMillis(25_000))

        policy.reset()

        assertEquals(1_000L, policy.nextDelayMillis(14_000))
    }

    @Test
    fun `recovery requires the same active request and a physical network`() {
        assertTrue(
            shouldRetryUnexpectedRelayExit(
                generationIsCurrent = true,
                processIsCurrent = true,
                recoveryRequested = true,
                terminalError = false,
                physicalNetworkAvailable = true,
                networkRestartPending = false,
            ),
        )
        assertFalse(
            shouldRetryUnexpectedRelayExit(
                generationIsCurrent = false,
                processIsCurrent = true,
                recoveryRequested = true,
                terminalError = false,
                physicalNetworkAvailable = true,
                networkRestartPending = false,
            ),
        )
        assertFalse(
            shouldRetryUnexpectedRelayExit(
                generationIsCurrent = true,
                processIsCurrent = false,
                recoveryRequested = true,
                terminalError = false,
                physicalNetworkAvailable = true,
                networkRestartPending = false,
            ),
        )
        assertFalse(
            shouldRetryUnexpectedRelayExit(
                generationIsCurrent = true,
                processIsCurrent = true,
                recoveryRequested = false,
                terminalError = false,
                physicalNetworkAvailable = true,
                networkRestartPending = false,
            ),
        )
        assertFalse(
            shouldRetryUnexpectedRelayExit(
                generationIsCurrent = true,
                processIsCurrent = true,
                recoveryRequested = true,
                terminalError = true,
                physicalNetworkAvailable = true,
                networkRestartPending = false,
            ),
        )
        assertFalse(
            shouldRetryUnexpectedRelayExit(
                generationIsCurrent = true,
                processIsCurrent = true,
                recoveryRequested = true,
                terminalError = false,
                physicalNetworkAvailable = false,
                networkRestartPending = false,
            ),
        )
        assertFalse(
            shouldRetryUnexpectedRelayExit(
                generationIsCurrent = true,
                processIsCurrent = true,
                recoveryRequested = true,
                terminalError = false,
                physicalNetworkAvailable = true,
                networkRestartPending = true,
            ),
        )
    }

    @Test
    fun `state callbacks remain available while retry operation is blocked`() {
        val stateLock = Any()
        val operationLock = Any()
        val generation = AtomicInteger(1)
        val retryEntered = CountDownLatch(1)
        val finishRetry = CountDownLatch(1)
        val stateUpdateAttempting = CountDownLatch(1)
        val stateUpdateFinished = CountDownLatch(1)
        val retryFinished = CountDownLatch(1)
        val actionCalls = AtomicInteger()
        var requestActive = true

        val isRetryCurrent = {
            shouldRunScheduledRelayRestart(
                generationIsCurrent = generation.get() == 1,
                processIsCurrent = true,
                recoveryRequested = requestActive,
                restartIsCurrent = true,
                terminalError = false,
                physicalNetworkAvailable = true,
                networkIsCurrent = true,
                networkRestartPending = false,
            )
        }

        Thread {
            runRelayRestartIfCurrent(
                lock = stateLock,
                operationLock = operationLock,
                isCurrent = isRetryCurrent,
                restart = {
                    actionCalls.incrementAndGet()
                    retryEntered.countDown()
                    check(finishRetry.await(2, TimeUnit.SECONDS))
                },
            )
            retryFinished.countDown()
        }.start()

        assertTrue(retryEntered.await(2, TimeUnit.SECONDS))
        val stateUpdateThread = Thread {
            stateUpdateAttempting.countDown()
            synchronized(stateLock) {
                generation.incrementAndGet()
                requestActive = false
            }
            stateUpdateFinished.countDown()
        }
        stateUpdateThread.start()

        assertTrue(stateUpdateAttempting.await(2, TimeUnit.SECONDS))
        assertTrue("state callback must not wait for process teardown", stateUpdateFinished.await(2, TimeUnit.SECONDS))

        finishRetry.countDown()
        assertTrue(retryFinished.await(2, TimeUnit.SECONDS))

        val staleActionCalls = AtomicInteger()
        assertFalse(
            runRelayRestartIfCurrent(
                lock = stateLock,
                operationLock = operationLock,
                isCurrent = isRetryCurrent,
                restart = { staleActionCalls.incrementAndGet() },
            ),
        )
        assertFalse(
            runRelayRestartIfCurrent(stateLock, operationLock, isRetryCurrent) {
                staleActionCalls.incrementAndGet()
            },
        )
        assertEquals(1, actionCalls.get())
        assertEquals(0, staleActionCalls.get())
    }

    @Test
    fun `relay retry yields to network recovery before stopping the process`() {
        val stateLock = Any()
        var networkRestartPending = false
        val stopCalls = AtomicInteger()

        val firstStop = runUnlessNetworkRestartPending(
            lock = stateLock,
            networkRestartPending = { networkRestartPending },
            action = { stopCalls.incrementAndGet() },
        )
        assertEquals(1, firstStop)

        synchronized(stateLock) { networkRestartPending = true }
        val retryStop = runUnlessNetworkRestartPending(
            lock = stateLock,
            networkRestartPending = { networkRestartPending },
            action = { stopCalls.incrementAndGet() },
        )

        assertNull(retryStop)
        assertEquals(1, stopCalls.get())
    }

    @Test
    fun `cancelled network worker cannot restart a newer user launch`() {
        assertTrue(
            shouldRunScheduledNetworkRestart(
                recoveryRequestIsCurrent = true,
                networkUpdateIsCurrent = true,
                restartIsCurrent = true,
            ),
        )
        assertFalse(
            shouldRunScheduledNetworkRestart(
                recoveryRequestIsCurrent = true,
                networkUpdateIsCurrent = true,
                restartIsCurrent = false,
            ),
        )
        assertFalse(
            shouldRunScheduledNetworkRestart(
                recoveryRequestIsCurrent = false,
                networkUpdateIsCurrent = true,
                restartIsCurrent = true,
            ),
        )
    }

    @Test
    fun `stale READY event cannot mutate the active relay generation`() {
        val policy = UserNetRelayRecoveryPolicy(
            maxAttempts = 1,
            stablePeriodMillis = 10,
            attemptWindowMillis = 1_000,
        )
        assertEquals(1_000L, policy.nextDelayMillis(0))

        assertFalse(
            markRelayReadyIfCurrent(
                policy,
                expectedGeneration = 6,
                currentGeneration = 7,
                nowMillis = 10,
            ),
        )
        assertNull(policy.nextDelayMillis(20))

        assertTrue(
            markRelayReadyIfCurrent(
                policy,
                expectedGeneration = 7,
                currentGeneration = 7,
                nowMillis = 20,
            ),
        )
        assertEquals(1_000L, policy.nextDelayMillis(30))
    }
}
