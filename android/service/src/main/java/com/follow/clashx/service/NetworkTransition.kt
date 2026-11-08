package com.follow.clashx.service

internal class NetworkTransition<T> {
    private var current: T? = null
    private var lost = false
    private var link: NetworkLink? = null

    @Synchronized
    fun onLost(network: T) {
        if (current == network) lost = true
    }

    @Synchronized
    fun update(network: T?, newLink: NetworkLink? = null): Boolean {
        val previous = current
        if (network == null) {
            if (previous != null) lost = true
            return false
        }
        val linkChanged = previous == network && link != null && newLink != null && link != newLink
        val reset = previous != null && (previous != network || lost || linkChanged)
        if (previous != network) link = null
        if (newLink != null) link = newLink
        current = network
        lost = false
        return reset
    }
}

internal data class NetworkLink(
    val interfaceName: String,
    val addresses: List<String>,
    val routes: List<String>,
)

internal data class NetworkAddress(val value: String, val ipv4: Boolean)

internal data class NetworkRoute(val value: String, val ipv4: Boolean)

internal fun primaryNetworkLink(
    interfaceName: String,
    addresses: List<NetworkAddress>,
    defaultRoutes: List<NetworkRoute>,
): NetworkLink? {
    val ipv4 = defaultRoutes.any { it.ipv4 } && addresses.any { it.ipv4 }
    val routes = defaultRoutes.filter { it.ipv4 == ipv4 }.map { it.value }.sorted()
    val address = addresses.firstOrNull { it.ipv4 == ipv4 }?.value ?: return null
    if (routes.isEmpty()) return null
    return NetworkLink(interfaceName, listOf(address), routes)
}
