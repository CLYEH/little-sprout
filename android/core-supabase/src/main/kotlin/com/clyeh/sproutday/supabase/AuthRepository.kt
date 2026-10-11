package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.OtpType
import io.github.jan.supabase.auth.SignOutScope
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.Apple
import io.github.jan.supabase.auth.providers.Google
import io.github.jan.supabase.auth.providers.builtin.IDToken
import io.github.jan.supabase.auth.providers.builtin.OTP
import io.github.jan.supabase.auth.status.SessionStatus
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.security.MessageDigest
import java.security.SecureRandom

/** 登入狀態的不可變快照；來源是 supabase-kt 的 `sessionStatus`（行程重啟後由 storage 還原）。 */
sealed interface AuthState {
    /** 正在從 storage 載入 session（冷啟動瞬間）。 */
    data object Initializing : AuthState

    data object SignedOut : AuthState

    data class SignedIn(
        val userId: String,
        val email: String?,
    ) : AuthState

    /** session 還在 storage 裡，但 refresh 失敗（多半離線）；恢復連線後 SDK 會自動重試，不要當成登出。 */
    data object RefreshFailed : AuthState
}

/** 由 app 層（需要 Activity／Credential Manager）提供 Google ID token；core-supabase 本身不碰 Android Context。 */
fun interface GoogleIdTokenSource {
    /**
     * @param hashedNonce SHA-256(raw nonce) 的小寫 hex；必須原樣交給 Google（`GetGoogleIdOption.setNonce`），
     *   Supabase 端用 raw nonce 驗證。
     * @return Google ID token（JWT 字串）。使用者取消時丟 [BackendError.UserCancelled]。
     */
    suspend fun fetchIdToken(hashedNonce: String): String
}

/**
 * Auth（docs/API.md §1）：Google 原生（Credential Manager → `signInWithIdToken`）、Apple（Supabase web OAuth，
 * Custom Tab → `sproutday://auth/callback`）、Email OTP。session 持久化與 auto-refresh 由 supabase-kt 負責，這裡不重做一份。
 */
class AuthRepository(
    private val client: SupabaseClient,
) {
    private val auth get() = client.auth

    /** 冷啟動時先是 [AuthState.Initializing]，storage 載入完成後才變成 SignedIn／SignedOut。 */
    val authState: Flow<AuthState> =
        auth.sessionStatus.map { status ->
            when (status) {
                is SessionStatus.Initializing -> AuthState.Initializing
                // GoTrue 的 session 回應一定帶 user；真的缺（理論上不會）就當成認不出身分、走登入畫面，而不是帶空 uid 進資料層。
                is SessionStatus.Authenticated ->
                    status.session.user?.let { AuthState.SignedIn(it.id, it.email) } ?: AuthState.SignedOut
                is SessionStatus.NotAuthenticated -> AuthState.SignedOut
                is SessionStatus.RefreshFailure -> AuthState.RefreshFailed
            }
        }

    /** Email OTP 第一步：寄出 6 碼。新帳號自動建立（與 iOS `signInWithOTP` 預設相同）。 */
    suspend fun sendEmailOtp(email: String) =
        backend {
            auth.signInWith(OTP) {
                this.email = email.trim()
                createUser = true
            }
        }

    /** Email OTP 第二步：驗證成功即建立 session（`authState` 轉 SignedIn）。 */
    suspend fun verifyEmailOtp(
        email: String,
        token: String,
    ) = backend {
        auth.verifyEmailOtp(type = OtpType.Email.EMAIL, email = email.trim(), token = token.trim())
    }

    /**
     * Google 原生登入：[source] 負責跟 Credential Manager 拿 ID token；這裡只管 nonce 與 `signInWithIdToken`。
     * ID token 帶 nonce 是為了防重放，raw nonce 不離開本函式與 Supabase 的請求。
     */
    suspend fun signInWithGoogle(source: GoogleIdTokenSource) {
        val rawNonce = randomNonce()
        val idToken = source.fetchIdToken(sha256Hex(rawNonce))
        backend {
            auth.signInWith(IDToken) {
                this.idToken = idToken
                provider = Google
                nonce = rawNonce
            }
        }
    }

    /**
     * Apple 登入（Supabase web OAuth，PKCE；[SupabaseClientFactory] 明確設 flowType，SDK 預設是 IMPLICIT）：
     * 開 Custom Tab 後立即返回；session 在 redirect 回 app 時由
     * `SupabaseClient.handleDeeplinks(intent)` 完成，結果走 [authState]。
     * 需要 Apple Service ID 與 Supabase Auth 的 Apple provider（使用者辦）。
     */
    suspend fun signInWithApple() = backend { auth.signInWith(Apple) }

    /**
     * 登出目前這台裝置（LOCAL scope，與 iOS 一致；GLOBAL 會撤銷同帳號所有裝置）。
     * 即使呼叫被取消（例如 viewModelScope 在登出中途被清掉）或伺服器撤銷失敗，本機 session 一定清乾淨——
     * 清除放在 [NonCancellable] 的 finally，避免「畫面以為登出了、storage 還留著 refresh token」。
     * 伺服器撤銷失敗仍會往外丟（呼叫端可提示「已在此裝置登出，但伺服器端未撤銷」）。
     */
    suspend fun signOut() {
        try {
            backend { auth.signOut(SignOutScope.LOCAL) }
        } finally {
            withContext(NonCancellable) { auth.clearSession() }
        }
    }

    /** 目前登入者的 uid；未登入回 null。純記憶體讀取。 */
    fun currentUserId(): String? = auth.currentUserOrNull()?.id

    private fun randomNonce(): String =
        SecureRandom().let { rng -> ByteArray(NONCE_BYTES).also(rng::nextBytes) }.toHex()

    private fun sha256Hex(value: String): String =
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).toHex()

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    private companion object {
        const val NONCE_BYTES = 32
    }
}
