package com.clyeh.sproutday.debug

import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import com.clyeh.sproutday.supabase.BackendError
import com.clyeh.sproutday.supabase.GoogleIdTokenSource
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.android.libraries.identity.googleid.GoogleIdTokenParsingException

/**
 * Google 原生登入（Credential Manager，docs/API.md §1 的 Android 對應）。
 * [context] 必須是 Activity context（Credential Manager 要掛底部面板）；本物件只在單次登入呼叫期間存活，
 * 不被 ViewModel 持有。[webClientId] 是 OAuth「Web application」client ID（不是 Android client ID）。
 */
class CredentialManagerGoogleIdTokenSource(
    private val context: Context,
    private val webClientId: String,
) : GoogleIdTokenSource {
    override suspend fun fetchIdToken(hashedNonce: String): String {
        if (webClientId.isBlank()) {
            throw BackendError.Misconfigured(
                "GOOGLE_WEB_CLIENT_ID 為空：請在 android/local.properties 填入 Google OAuth Web client ID",
            )
        }
        val option =
            GetGoogleIdOption
                .Builder()
                .setServerClientId(webClientId)
                .setFilterByAuthorizedAccounts(false)
                .setNonce(hashedNonce)
                .build()
        val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
        val credential =
            try {
                CredentialManager.create(context).getCredential(context, request).credential
            } catch (e: GetCredentialCancellationException) {
                throw BackendError.UserCancelled(e)
            } catch (e: NoCredentialException) {
                throw BackendError.Misconfigured("裝置上沒有可用的 Google 帳號（${e.message}）", e)
            } catch (e: GetCredentialException) {
                throw BackendError.Auth(e.type, "Credential Manager 失敗：${e.message}", e)
            }
        if (credential !is CustomCredential ||
            credential.type != GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
        ) {
            throw BackendError.Auth(null, "Credential Manager 回傳了非 Google ID token 的憑證：${credential.type}", null)
        }
        return try {
            GoogleIdTokenCredential.createFrom(credential.data).idToken
        } catch (e: GoogleIdTokenParsingException) {
            throw BackendError.Auth(null, "Google ID token 解析失敗：${e.message}", e)
        }
    }
}
