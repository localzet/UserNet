package com.follow.clashx.common

import android.content.Context
import android.content.Intent
import java.security.MessageDigest
import java.util.UUID

object QuickActionIntentAuthorization {
    const val TOKEN_EXTRA = "com.userlay.usernet.extra.QUICK_ACTION_TOKEN"

    private const val PREFERENCES_NAME = "usernet.quick_action"
    private const val TOKEN_KEY = "intent_token"
    private val lock = Any()

    fun attachToken(intent: Intent): Intent {
        val token = getOrCreateToken(GlobalState.application)
        if (token != null) {
            intent.putExtra(TOKEN_EXTRA, token)
        }
        return intent
    }

    fun isAuthorized(context: Context, intent: Intent): Boolean {
        val supplied = runCatching { intent.getStringExtra(TOKEN_EXTRA) }.getOrNull()
        val expected = getOrCreateToken(context)
        return matchesToken(supplied, expected)
    }

    internal fun matchesToken(supplied: String?, expected: String?): Boolean {
        if (supplied.isNullOrEmpty() || expected.isNullOrEmpty()) return false
        return MessageDigest.isEqual(
            supplied.toByteArray(Charsets.UTF_8),
            expected.toByteArray(Charsets.UTF_8),
        )
    }

    private fun getOrCreateToken(context: Context): String? = synchronized(lock) {
        try {
            val preferences = context.applicationContext.getSharedPreferences(
                PREFERENCES_NAME,
                Context.MODE_PRIVATE,
            )
            val stored = preferences.getString(TOKEN_KEY, null)
            if (stored != null) {
                stored
            } else {
                val token = UUID.randomUUID().toString()
                if (preferences.edit().putString(TOKEN_KEY, token).commit()) token else null
            }
        } catch (_: Exception) {
            null
        }
    }
}
