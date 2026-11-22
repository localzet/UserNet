package com.follow.clashx.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForegroundServiceStartTest {
    @Test
    fun `foreground notification starts before sticky restart handling`() {
        var foregroundStarted = false
        var startHandled = false

        startForegroundBeforeHandling(
            startForeground = { foregroundStarted = true },
            handleStart = {
                assertTrue(foregroundStarted)
                startHandled = true
            },
        )

        assertTrue(foregroundStarted)
        assertTrue(startHandled)
    }

    @Test
    fun `failed foreground start does not continue start handling`() {
        var startHandled = false

        runCatching {
            startForegroundBeforeHandling(
                startForeground = { error("foreground start failed") },
                handleStart = { startHandled = true },
            )
        }

        assertFalse(startHandled)
    }
}
