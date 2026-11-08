package com.follow.clashx.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkTransitionTest {
    private val initialLink = NetworkLink("wlan0", listOf("192.0.2.2/24"), listOf("default|192.0.2.1"))

    @Test
    fun `secondary addresses and ipv6 do not reset working ipv4 route`() {
        val transition = NetworkTransition<String>()
        val ipv4 = NetworkAddress("192.0.2.2/24", true)
        val route = NetworkRoute("192.0.2.1|wlan0", true)
        val initial = primaryNetworkLink("wlan0", listOf(ipv4), listOf(route))
        assertFalse(transition.update("wifi", initial))
        val expanded = primaryNetworkLink(
            "wlan0",
            listOf(ipv4, NetworkAddress("2001:db8::2/64", false)),
            listOf(route, NetworkRoute("fe80::1|wlan0", false)),
        )
        assertFalse(transition.update("wifi", expanded))
        val moved = primaryNetworkLink("wlan0", listOf(ipv4), listOf(NetworkRoute("192.0.2.254|wlan0", true)))
        assertTrue(transition.update("wifi", moved))
    }

    @Test
    fun `material link changes reset once while partial link data is ignored`() {
        val transition = NetworkTransition<String>()
        assertFalse(transition.update("wifi", initialLink))
        assertFalse(transition.update("wifi", null))
        assertFalse(transition.update("wifi", initialLink))
        val changed = initialLink.copy(addresses = listOf("192.0.2.3/24"))
        assertTrue(transition.update("wifi", changed))
        assertFalse(transition.update("wifi", changed))
        assertTrue(transition.update("wifi", changed.copy(routes = listOf("default|192.0.2.254"))))
    }

    @Test
    fun `link change on a new network triggers only one reset`() {
        val transition = NetworkTransition<String>()
        assertFalse(transition.update("wifi", initialLink))
        assertTrue(transition.update("cellular", initialLink.copy(interfaceName = "rmnet0")))
        assertFalse(transition.update("cellular", initialLink.copy(interfaceName = "rmnet0")))
    }
    @Test
    fun `restoring the same network after loss resets stale connections`() {
        val transition = NetworkTransition<String>()
        assertFalse(transition.update("wifi"))
        transition.onLost("wifi")
        assertTrue(transition.update("wifi"))
        assertFalse(transition.update("wifi"))
    }

    @Test
    fun `restoring the same network after no available network resets connections`() {
        val transition = NetworkTransition<String>()
        assertFalse(transition.update("wifi"))
        assertFalse(transition.update(null))
        assertTrue(transition.update("wifi"))
    }

    @Test
    fun `switching networks resets once but loss of another network does not`() {
        val transition = NetworkTransition<String>()
        assertFalse(transition.update("wifi"))
        transition.onLost("cellular")
        assertFalse(transition.update("wifi"))
        assertTrue(transition.update("cellular"))
        assertFalse(transition.update("cellular"))
    }
}
