package com.follow.clashx.common

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class QuickActionIntentAuthorizationTest {
    @Test
    fun acceptsMatchingToken() {
        assertTrue(QuickActionIntentAuthorization.matchesToken("token", "token"))
    }

    @Test
    fun rejectsMissingOrMismatchedToken() {
        assertFalse(QuickActionIntentAuthorization.matchesToken(null, "token"))
        assertFalse(QuickActionIntentAuthorization.matchesToken("", "token"))
        assertFalse(QuickActionIntentAuthorization.matchesToken("forged", "token"))
    }
}
