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
    fun `stop waits for retry action and stale retry does not invoke it`() {
        val lock = Any()
        val generation = AtomicInteger(1)
        val retryEntered = CountDownLatch(1)
        val finishRetry = CountDownLatch(1)
        val stopAttempting = CountDownLatch(1)
        val stopFinished = CountDownLatch(1)
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
                lock = lock,
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
        val stopThread = Thread {
            stopAttempting.countDown()
            synchronized(lock) { generation.incrementAndGet() }
            stopFinished.countDown()
        }
        stopThread.start()

        assertTrue(stopAttempting.await(2, TimeUnit.SECONDS))
        val blockedDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
        while (stopThread.state != Thread.State.BLOCKED && System.nanoTime() < blockedDeadline) {
            Thread.yield()
        }
        assertEquals(Thread.State.BLOCKED, stopThread.state)

        finishRetry.countDown()
        assertTrue(retryFinished.await(2, TimeUnit.SECONDS))
        assertTrue(stopFinished.await(2, TimeUnit.SECONDS))

        val staleActionCalls = AtomicInteger()
        assertFalse(
            runRelayRestartIfCurrent(
                lock = lock,
                isCurrent = isRetryCurrent,
                restart = { staleActionCalls.incrementAndGet() },
            ),
        )
        requestActive = false
        assertFalse(runRelayRestartIfCurrent(lock, isRetryCurrent) { staleActionCalls.incrementAndGet() })
        assertEquals(1, actionCalls.get())
        assertEquals(0, staleActionCalls.get())
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
