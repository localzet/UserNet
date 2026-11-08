package com.follow.clashx.plugins

import org.junit.Assert.assertEquals
import org.junit.Test

class PhysicalNetworkResolverTest {
    @Test
    fun `legacy network selection prefers wifi over cellular even when cellular was current`() {
        val priorities = mapOf("wifi" to 0, "cellular" to 4)
        val selected = selectLegacyPhysicalNetwork(
            listOf("cellular", "wifi"), active = "vpn", current = "cellular",
        ) { priorities.getValue(it) }
        assertEquals("wifi", selected)
    }

    @Test
    fun `missing physical network never invokes resolver`() {
        var called = false
        val result = resolveOnPhysicalNetwork<String, String>(
            selectNetwork = { null },
            lookup = { called = true; listOf("unexpected") },
        )
        assertEquals(emptyList<String>(), result)
        assertEquals(false, called)
    }

    @Test
    fun `uses selected physical network`() {
        val result = resolveOnPhysicalNetwork(
            selectNetwork = { "wifi" },
            lookup = { listOf("address on $it") },
        )
        assertEquals(listOf("address on wifi"), result)
    }

    @Test
    fun `discards result after physical network changes or disappears`() {
        for (replacement in listOf("cellular", null)) {
            var current: String? = "wifi"
            val result = resolveOnPhysicalNetwork(
                selectNetwork = { current },
                lookup = { current = replacement; listOf("stale") },
            )
            assertEquals(emptyList<String>(), result)
        }
    }

    @Test
    fun `lookup failure does not fall back to system resolver`() {
        val result = resolveOnPhysicalNetwork<String, String>(
            selectNetwork = { "wifi" },
            lookup = { throw IllegalStateException("dns failed") },
        )
        assertEquals(emptyList<String>(), result)
    }
}
