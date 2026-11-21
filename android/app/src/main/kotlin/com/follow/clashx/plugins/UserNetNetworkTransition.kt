package com.follow.clashx.plugins

internal data class UserNetNetworkUpdate(
    val changed: Boolean,
    val revision: Long,
    val shouldAnnounceReconnect: Boolean,
    val shouldRestart: Boolean,
)

internal class UserNetNetworkTransition<T> {
    private var current: T? = null
    private var initialized = false
    private var revision = 0L

    @Synchronized
    fun update(
        network: T?,
        recoveryRequested: Boolean,
        relayReady: Boolean,
    ): UserNetNetworkUpdate {
        val wasInitialized = initialized
        val firstAvailableNetwork = !wasInitialized && network != null
        val changed = (wasInitialized && current != network) || firstAvailableNetwork
        val shouldRestart = changed && recoveryRequested && network != null &&
            (wasInitialized || !relayReady)
        if (changed) revision++
        current = network
        initialized = true
        return UserNetNetworkUpdate(
            changed = changed,
            revision = revision,
            shouldAnnounceReconnect = changed && recoveryRequested &&
                (network == null || shouldRestart),
            shouldRestart = shouldRestart,
        )
    }

    @Synchronized
    fun isCurrent(expectedRevision: Long, network: T?): Boolean =
        revision == expectedRevision && current == network

    @Synchronized
    fun reset() {
        revision++
        current = null
        initialized = false
    }
}

internal fun isUserNetRelayReady(
    processRunning: Boolean,
    activeStage: String,
    controlState: String,
    transportState: String,
): Boolean {
    if (!processRunning) return false
    return when (activeStage) {
        "control" -> controlState == "connected" || controlState == "complete"
        else -> transportState == "connected"
    }
}

internal fun shouldKeepNetworkObserver(
    engineCount: Int,
    recoveryRequested: Boolean,
): Boolean = engineCount > 0 || recoveryRequested
