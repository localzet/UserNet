package com.follow.clashx.plugins

import java.util.ArrayDeque

internal class UserNetRelayRecoveryPolicy(
    private val maxAttempts: Int = 5,
    private val initialDelayMillis: Long = 1_000,
    private val maxDelayMillis: Long = 16_000,
    private val attemptWindowMillis: Long = 10 * 60 * 1_000,
    private val stablePeriodMillis: Long = 60_000,
) {
    private val attempts = ArrayDeque<Long>()
    private var consecutiveFailures = 0
    private var readyAtMillis: Long? = null

    @Synchronized
    fun markReady(nowMillis: Long) {
        readyAtMillis = nowMillis
    }

    @Synchronized
    fun nextDelayMillis(nowMillis: Long): Long? {
        while (attempts.isNotEmpty() && nowMillis - attempts.first() >= attemptWindowMillis) {
            attempts.removeFirst()
        }

        readyAtMillis?.let { readyAt ->
            if (nowMillis - readyAt >= stablePeriodMillis) {
                consecutiveFailures = 0
                attempts.clear()
            }
        }
        readyAtMillis = null
        if (attempts.size >= maxAttempts) return null

        val multiplier = 1L shl consecutiveFailures
        consecutiveFailures++
        attempts.addLast(nowMillis)
        return (initialDelayMillis * multiplier).coerceAtMost(maxDelayMillis)
    }

    @Synchronized
    fun reset() {
        attempts.clear()
        consecutiveFailures = 0
        readyAtMillis = null
    }
}

internal fun shouldRetryUnexpectedRelayExit(
    generationIsCurrent: Boolean,
    processIsCurrent: Boolean,
    recoveryRequested: Boolean,
    terminalError: Boolean,
    physicalNetworkAvailable: Boolean,
    networkRestartPending: Boolean,
): Boolean = generationIsCurrent && processIsCurrent && recoveryRequested &&
    !terminalError && physicalNetworkAvailable && !networkRestartPending

internal fun shouldRunScheduledRelayRestart(
    generationIsCurrent: Boolean,
    processIsCurrent: Boolean,
    recoveryRequested: Boolean,
    restartIsCurrent: Boolean,
    terminalError: Boolean,
    physicalNetworkAvailable: Boolean,
    networkIsCurrent: Boolean,
    networkRestartPending: Boolean,
): Boolean = generationIsCurrent && processIsCurrent && recoveryRequested &&
    restartIsCurrent && !terminalError && physicalNetworkAvailable && networkIsCurrent &&
    !networkRestartPending

internal fun runRelayRestartIfCurrent(
    lock: Any,
    operationLock: Any,
    isCurrent: () -> Boolean,
    restart: () -> Unit,
): Boolean = synchronized(operationLock) {
    val current = synchronized(lock) { isCurrent() }
    if (!current) return@synchronized false
    restart()
    true
}

internal fun <T> runUnlessNetworkRestartPending(
    lock: Any,
    networkRestartPending: () -> Boolean,
    action: () -> T,
): T? = synchronized(lock) {
    if (networkRestartPending()) return@synchronized null
    action()
}

internal fun shouldRunScheduledNetworkRestart(
    recoveryRequestIsCurrent: Boolean,
    networkUpdateIsCurrent: Boolean,
    restartIsCurrent: Boolean,
): Boolean = recoveryRequestIsCurrent && networkUpdateIsCurrent && restartIsCurrent

internal fun isRelayGenerationCurrent(expectedGeneration: Long, currentGeneration: Long): Boolean =
    expectedGeneration == currentGeneration

internal fun markRelayReadyIfCurrent(
    policy: UserNetRelayRecoveryPolicy,
    expectedGeneration: Long,
    currentGeneration: Long,
    nowMillis: Long,
): Boolean {
    if (!isRelayGenerationCurrent(expectedGeneration, currentGeneration)) return false
    policy.markReady(nowMillis)
    return true
}
