package com.follow.clashx.plugins

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import com.follow.clashx.common.Components
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class UserNetMethodChannelTest {
    @Test
    fun `method calls use a serial background task queue`() {
        val messenger = RecordingBinaryMessenger()

        createUserNetMethodChannel(
            messenger,
            MethodChannel.MethodCallHandler { _, result -> result.success(null) },
        )

        assertSame(messenger.backgroundQueue, messenger.registeredQueue)
        assertTrue(messenger.registeredQueueIsSerial)
        assertNotNull(messenger.registeredHandler)
        assertEquals(
            "${Components.PACKAGE_NAME}/usernet_transport",
            messenger.lastRegisteredChannel,
        )
    }

    private class RecordingBinaryMessenger : BinaryMessenger {
        val backgroundQueue = object : BinaryMessenger.TaskQueue {}
        var registeredQueue: BinaryMessenger.TaskQueue? = null
        var registeredQueueIsSerial = false
        var registeredHandler: BinaryMessenger.BinaryMessageHandler? = null
        var lastRegisteredChannel = ""

        override fun makeBackgroundTaskQueue(
            options: BinaryMessenger.TaskQueueOptions,
        ): BinaryMessenger.TaskQueue {
            registeredQueueIsSerial = options.isSerial
            return backgroundQueue
        }

        override fun send(channel: String, message: ByteBuffer?) = Unit

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) = Unit

        override fun setMessageHandler(
            channel: String,
            handler: BinaryMessenger.BinaryMessageHandler?,
        ) {
            lastRegisteredChannel = channel
            registeredHandler = handler
        }

        override fun setMessageHandler(
            channel: String,
            handler: BinaryMessenger.BinaryMessageHandler?,
            taskQueue: BinaryMessenger.TaskQueue?,
        ) {
            lastRegisteredChannel = channel
            registeredHandler = handler
            registeredQueue = taskQueue
        }
    }
}
