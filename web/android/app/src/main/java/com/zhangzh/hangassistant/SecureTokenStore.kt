package com.zhangzh.hangassistant

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

data class NativeSession(val username: String)

/**
 * Persists only the opaque server-issued session cookie in Android Keystore-backed storage.
 * The administrator password is never persisted; the cookie remains HttpOnly in browsers and
 * is never exposed to WebView or JavaScript because this client is fully native.
 */
class SecureSessionStore(context: Context) {
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val preferences = EncryptedSharedPreferences.create(
        context,
        "hand_helper_auth",
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    fun read(): NativeSession? {
        val cookie = preferences.getString("session_cookie", null)
        val username = preferences.getString("username", null)
        return if (cookie.isNullOrBlank() || username.isNullOrBlank()) null else NativeSession(username)
    }

    fun save(session: NativeSession) {
        preferences.edit()
            .putString("username", session.username)
            .apply()
    }

    fun sessionCookie(): String? = preferences.getString("session_cookie", null)

    fun saveSessionCookie(value: String) {
        preferences.edit().putString("session_cookie", value).apply()
    }

    fun clear() = preferences.edit().clear().apply()
}
