package com.zhangzh.hangassistant

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

data class AuthTokens(val accessToken: String, val refreshToken: String)

/** Stores only the application's API tokens; account passwords are never persisted. */
class SecureTokenStore(context: Context) {
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

    fun read(): AuthTokens? {
        val access = preferences.getString("access_token", null)
        val refresh = preferences.getString("refresh_token", null)
        return if (access.isNullOrBlank() || refresh.isNullOrBlank()) null else AuthTokens(access, refresh)
    }

    fun save(tokens: AuthTokens) {
        preferences.edit()
            .putString("access_token", tokens.accessToken)
            .putString("refresh_token", tokens.refreshToken)
            .apply()
    }

    fun clear() = preferences.edit().clear().apply()
}
