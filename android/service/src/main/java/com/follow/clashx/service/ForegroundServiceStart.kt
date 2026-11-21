package com.follow.clashx.service

internal inline fun startForegroundBeforeHandling(
    startForeground: () -> Unit,
    handleStart: () -> Unit,
) {
    startForeground()
    handleStart()
}
