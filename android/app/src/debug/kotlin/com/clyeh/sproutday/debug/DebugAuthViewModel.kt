package com.clyeh.sproutday.debug

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.clyeh.sproutday.BuildConfig
import com.clyeh.sproutday.supabase.Album
import com.clyeh.sproutday.supabase.AuthRepository
import com.clyeh.sproutday.supabase.AuthState
import com.clyeh.sproutday.supabase.BackendError
import com.clyeh.sproutday.supabase.Family
import com.clyeh.sproutday.supabase.FamilyMember
import com.clyeh.sproutday.supabase.FamilyRepository
import com.clyeh.sproutday.supabase.MediaRepository
import com.clyeh.sproutday.upload.UploadItem
import com.clyeh.sproutday.upload.UploadQueue
import com.clyeh.sproutday.upload.UploadRejectedException
import com.clyeh.sproutday.upload.UploadSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.getAndUpdate
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.LocalTime

/** 除錯面板的畫面狀態（不可變；只透過 `update {}` 改）。 */
data class DebugUiState(
    val auth: AuthState = AuthState.Initializing,
    val busy: Boolean = false,
    val family: Family? = null,
    val members: List<FamilyMember> = emptyList(),
    val album: Album? = null,
    val uploads: List<UploadItem> = emptyList(),
    val log: List<String> = emptyList(),
)

/**
 * 除錯用登入面板的 ViewModel（LS-479）：不是產品畫面。auth 狀態來自 supabase-kt 的 sessionStatus（旋轉／行程重建後由 storage 還原），
 * 本地狀態用單一 [MutableStateFlow] + `update {}`；`busy` 以原子 `getAndUpdate` 擋重複送出（OTP 連點兩次只會走一次）。
 */
@Suppress("TooManyFunctions") // 除錯面板：一個動作一個函式，不是產品邏輯
class DebugAuthViewModel(
    private val auth: AuthRepository,
    private val families: FamilyRepository,
    private val media: MediaRepository,
    private val uploadQueue: UploadQueue,
) : ViewModel() {
    private val local = MutableStateFlow(DebugUiState())

    val state: StateFlow<DebugUiState> =
        combine(
            auth.authState,
            local,
            uploadQueue.items,
        ) { authState, ui, uploads -> ui.copy(auth = authState, uploads = uploads) }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(STOP_TIMEOUT_MS), DebugUiState())

    fun sendOtp(email: String) =
        run("寄 OTP") {
            auth.sendEmailOtp(email)
            "已寄出（本機請用 demo-otp.sh 取碼）"
        }

    fun verifyOtp(
        email: String,
        code: String,
    ) = run("驗證 OTP") {
        auth.verifyEmailOtp(email, code)
        "驗證成功"
    }

    /** [activity] 只在這次呼叫期間被 Credential Manager 使用，不存進 ViewModel。 */
    fun signInWithGoogle(activity: Context) =
        run("Google 登入") {
            auth.signInWithGoogle(CredentialManagerGoogleIdTokenSource(activity, BuildConfig.GOOGLE_WEB_CLIENT_ID))
            "成功"
        }

    fun signInWithApple() =
        run("Apple 登入") {
            auth.signInWithApple()
            "已開啟瀏覽器；完成後會從 sproutday://auth/callback 回來"
        }

    fun signOut() =
        run("登出") {
            uploadQueue.clear() // 先取消佇列：登出後的 session 不該再替上一個帳號上傳
            auth.signOut()
            local.update { it.copy(family = null, members = emptyList(), album = null) }
            "已登出"
        }

    fun createFamily() =
        run("建立家庭") {
            val family = families.createFamily("除錯家庭 ${LocalTime.now().withNano(0)}")
            local.update { it.copy(family = family, members = emptyList()) }
            "${family.name}（${family.id.take(ID_PREVIEW)}…）"
        }

    fun listMembers() =
        run("列成員") {
            val family = local.value.family ?: families.fetchMyFamilies().firstOrNull() ?: return@run "還沒有家庭"
            val members = families.listMembers(family.id)
            local.update { it.copy(family = family, members = members) }
            "${members.size} 位"
        }

    fun createAlbum() =
        run("建相簿") {
            val family = local.value.family ?: families.fetchMyFamilies().firstOrNull() ?: return@run "還沒有家庭"
            val album = media.createAlbum(family.id, "除錯相簿 ${LocalTime.now().withNano(0)}")
            local.update { it.copy(family = family, album = album) }
            "${album.title}（${album.id.take(ID_PREVIEW)}…）"
        }

    /** [itemId] 由選圖結果的回呼產生（每次選圖一個）：同一次選圖重送入列只會有一筆。 */
    fun uploadPicked(
        itemId: String,
        source: UploadSource,
    ) = run("上傳") {
        val family = local.value.family ?: return@run "先建家庭"
        val album = local.value.album ?: return@run "先建相簿"
        try {
            val item = uploadQueue.enqueue(itemId, family.id, album.id, source)
            "已入列 ${item.id.take(ID_PREVIEW)}…（${item.state}）"
        } catch (e: UploadRejectedException) {
            "已拒絕（${e.message}）"
        }
    }

    fun listPhotos() =
        run("列照片") {
            val album = local.value.album ?: return@run "先建相簿"
            val photos = media.listAlbumMedia(album.id)
            "${photos.size} 張：" +
                photos.joinToString {
                    "${it.id.take(
                        ID_PREVIEW,
                    )}…(${it.width}x${it.height}, thumb=${it.thumbWidth}x${it.thumbHeight})"
                }
        }

    private fun run(
        label: String,
        block: suspend () -> String,
    ) {
        if (local.getAndUpdate { it.copy(busy = true) }.busy) return // 已有動作在跑：丟掉重複點擊
        viewModelScope.launch {
            try {
                append("$label：${block()}")
            } catch (e: CancellationException) {
                throw e
            } catch (e: BackendError.UserCancelled) {
                append("$label：已取消（${e.message}）")
            } catch (e: BackendError) {
                append("$label ✗ [${e.code ?: "-"}] ${e.message}")
            } finally {
                local.update { it.copy(busy = false) }
            }
        }
    }

    private fun append(line: String) = local.update { it.copy(log = (listOf(line) + it.log).take(LOG_LIMIT)) }

    companion object {
        private const val STOP_TIMEOUT_MS = 5_000L
        private const val LOG_LIMIT = 30
        private const val ID_PREVIEW = 8

        fun factory(
            auth: AuthRepository,
            families: FamilyRepository,
            media: MediaRepository,
            uploadQueue: UploadQueue,
        ): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { DebugAuthViewModel(auth, families, media, uploadQueue) }
            }
    }
}
