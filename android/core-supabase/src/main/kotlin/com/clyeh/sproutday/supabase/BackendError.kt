package com.clyeh.sproutday.supabase

import io.github.jan.supabase.auth.exception.AuthRestException
import io.github.jan.supabase.exceptions.RestException
import io.github.jan.supabase.postgrest.exception.PostgrestRestException
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import java.io.IOException

/** `LS050`／`LS057` 的 DETAIL 一項：需要先轉移 owner 才能退出／刪帳號的家庭。 */
@Serializable
data class PendingTransferFamily(
    @SerialName("family_id") val familyId: String,
    @SerialName("family_name") val familyName: String,
)

/**
 * 後端錯誤的 sealed 表示（docs/API.md §5）。`code` 是 Postgres SQLSTATE（`LSnnn`／`42501`…），沒有則為 null。
 * 對應 iOS `LSErrorCode`／`AppError`；這裡只列本層（Auth＋profiles／families／family_members＋邀請／加入流程＋媒體＋時間軸／留言／愛心＋寶貝／成長／飲食＋日記寫入）會碰到的碼，
 * 其餘自訂碼落到 [Server]（保留原始 code），之後的票遇到時再補成具名 case。
 */
sealed class BackendError(
    message: String,
    val code: String?,
    cause: Throwable? = null,
) : Exception(message, cause) {
    class FamilyMustHaveOwner(
        cause: Throwable?,
    ) : BackendError("家庭必須至少保留一位 owner", "LS001", cause)

    /** `media` 的 INSERT／UPDATE 被額度 trigger 擋下：家庭已達儲存額度上限（重試同一筆不會成功）。 */
    class StorageQuotaExceeded(
        cause: Throwable?,
    ) : BackendError("家庭儲存空間已滿，無法再上傳", "LS002", cause)

    class InviteNotFound(
        cause: Throwable?,
    ) : BackendError("邀請碼不存在", "LS010", cause)

    class InviteExpired(
        cause: Throwable?,
    ) : BackendError("邀請碼已過期", "LS011", cause)

    class InviteExhausted(
        cause: Throwable?,
    ) : BackendError("邀請碼的使用次數已用完", "LS012", cause)

    class AlreadyMember(
        cause: Throwable?,
    ) : BackendError("你已經是這個家庭的成員", "LS013", cause)

    class JoinRequestAlreadyPending(
        cause: Throwable?,
    ) : BackendError("你對這個家庭已經有一筆待審核的申請", "LS014", cause)

    class JoinRequestNotFound(
        cause: Throwable?,
    ) : BackendError("申請不存在或已被處理", "LS015", cause)

    /** 機率極低的系統性錯誤（亂數來源異常），UI 顯示通用重試訊息即可。 */
    class InviteCodeCollision(
        cause: Throwable?,
    ) : BackendError("邀請碼產生連續撞碼，請重試", "LS016", cause)

    class InviteParamsInvalid(
        cause: Throwable?,
    ) : BackendError("邀請碼參數不合法（到期時間或可用次數超出範圍）", "LS017", cause)

    /** `LS020`：`update_diary_entry`／`set_diary_deleted` 的日記不存在；`update_diary_entry` 另含已軟刪（須先還原才能編輯）。 */
    class DiaryNotFound(
        cause: Throwable?,
    ) : BackendError("日記不存在，或已被移除須先還原", "LS020", cause)

    /** `LS021`：`update_diary_entry` 的呼叫者不是作者本人，或雖是作者但已不是該家庭 owner／member。 */
    class NotDiaryAuthor(
        cause: Throwable?,
    ) : BackendError("只有日記作者本人能編輯", "LS021", cause)

    /** `LS022`：keyset 游標只給了一半（`get_family_timeline`／`list_comments` 的兩個游標參數要嘛都給、要嘛都不給）。 */
    class PartialCursor(
        cause: Throwable?,
    ) : BackendError("分頁游標只給了一半", "LS022", cause)

    /** `LS024`：`set_comment_deleted` 的留言不存在。 */
    class CommentNotFound(
        cause: Throwable?,
    ) : BackendError("留言不存在", "LS024", cause)

    /** `LS026`：留言／按讚的 target 存在，但屬於別的家庭（呼叫端組錯 family 參數的訊號，換輸入重試沒有用）。 */
    class TargetFamilyMismatch(
        cause: Throwable?,
    ) : BackendError("這個內容不屬於這個家庭", "LS026", cause)

    /** `LS027`：留言已被家庭管理者移除，作者無法自行還原（只有 owner 能還原）。 */
    class RemovedByOwner(
        cause: Throwable?,
    ) : BackendError("這則內容已被家庭管理者移除，只有管理者能還原", "LS027", cause)

    /** `LS041`：`update_child`／`set_child_deleted` 的寶貝不存在，或（`update_child`）已被軟刪、須先還原。 */
    class ChildNotFound(
        cause: Throwable?,
    ) : BackendError("寶貝檔案不存在，或已被移除須先還原", "LS041", cause)

    /** `LS042`：`update_child` 的呼叫者已不是該家庭 owner／member（例如被降級成 viewer）。 */
    class NotChildEditor(
        cause: Throwable?,
    ) : BackendError("你不是這個家庭的 owner 或 member，無法編輯寶貝檔案", "LS042", cause)

    /** `LS043`：`set_child_deleted(false)` 還原已超過 30 天的軟刪。 */
    class RestoreWindowExpired(
        cause: Throwable?,
    ) : BackendError("寶貝檔案已被移除超過 30 天，無法還原", "LS043", cause)

    /** `LS044`：寶貝已軟刪，不能再歸屬新內容（新增日記／相簿標記、成長紀錄、飲食紀錄）。 */
    class ChildDeleted(
        cause: Throwable?,
    ) : BackendError("寶貝已移除，無法歸屬新內容", "LS044", cause)

    /** `LS050`（刪帳號）或 `LS057`（退出／被移除）：唯一 owner 且家庭還有其他成員，須先轉移 owner。 */
    class MustTransferOwnership(
        code: String,
        val families: List<PendingTransferFamily>,
        cause: Throwable?,
    ) : BackendError("你是家庭的唯一 owner，且家庭還有其他成員，須先轉移 owner 身份", code, cause)

    class AccountDeletionPending(
        cause: Throwable?,
    ) : BackendError("帳號已請求刪除，過渡期間不能再建立新資料", "LS051", cause)

    class AccountSuspended(
        cause: Throwable?,
    ) : BackendError("這個帳號已被暫停使用，請聯絡我們", "LS052", cause)

    class FamilySuspended(
        cause: Throwable?,
    ) : BackendError("這個家庭已被暫停使用，請聯絡我們", "LS053", cause)

    class RegistrationsClosed(
        cause: Throwable?,
    ) : BackendError("目前暫停開放新註冊，請稍後再試", "LS054", cause)

    /** 未登入或權限不足（含 RLS 以外的 grant 擋下）。 */
    class PermissionDenied(
        message: String,
        cause: Throwable?,
    ) : BackendError(message, "42501", cause)

    /** `.update()`／`.delete()` 因 RLS USING 過濾匹配 0 列（PostgREST 回 200 + `[]`，不丟錯），docs/API.md §2。 */
    class NoRowsAffected(
        message: String,
    ) : BackendError(message, null)

    /** 呼叫前就知道的狀態錯誤：沒有登入 session。 */
    class NotSignedIn : BackendError("尚未登入", null)

    /** GoTrue 端錯誤（OTP 錯誤／過期、provider 設定不符等）。`code` 為 GoTrue 的 error_code（例如 `otp_expired`）。 */
    class Auth(
        code: String?,
        message: String,
        cause: Throwable?,
    ) : BackendError(message, code, cause)

    /** 使用者在系統介面（Credential Manager／Custom Tab）取消——不是錯誤，呼叫端靜默處理。 */
    class UserCancelled(
        cause: Throwable?,
    ) : BackendError("使用者取消", null, cause)

    /** 缺少設定（例如尚未提供 Google Web client ID）；fail loud，不當成網路錯誤。 */
    class Misconfigured(
        message: String,
        cause: Throwable? = null,
    ) : BackendError(message, null, cause)

    /** Storage 以 413 擋下超過 bucket `file_size_limit`（50 MiB）的檔案；重試同一份檔案不會成功。 */
    class PayloadTooLarge(
        cause: Throwable?,
    ) : BackendError("檔案超過 50 MiB 上限", null, cause)

    /** 其他自訂碼或標準 Postgres／HTTP 錯誤。 */
    class Server(
        message: String,
        code: String?,
        cause: Throwable?,
    ) : BackendError(message, code, cause)

    /** 連線失敗、逾時等（沒有收到後端回應）。 */
    class Network(
        cause: Throwable,
    ) : BackendError("連線失敗：${cause.message}", null, cause)
}

private val detailJson = Json { ignoreUnknownKeys = true }

/**
 * 把 supabase-kt 的 [RestException]／[IOException]（含 ktor 逾時、`HttpRequestException`）轉成 [BackendError]。
 * 刻意只攔這兩類：[kotlinx.coroutines.CancellationException] 不是它們的子類，所以取消會原樣往上傳、不被吞；
 * 序列化失敗、程式錯誤（NPE／ISE）也不攔——契約走鐘要 fail loud，不該被偽裝成「連線失敗」。
 */
internal inline fun <T> backend(block: () -> T): T =
    try {
        block()
    } catch (e: RestException) {
        throw e.toBackendError()
    } catch (e: IOException) {
        throw BackendError.Network(e)
    }

internal fun RestException.toBackendError(): BackendError =
    when (this) {
        is PostgrestRestException -> mapPostgrest(this)
        is AuthRestException -> BackendError.Auth(errorCode?.value, errorDescription, this)
        else ->
            if (statusCode ==
                HTTP_PAYLOAD_TOO_LARGE
            ) {
                BackendError.PayloadTooLarge(this)
            } else {
                BackendError.Server(description ?: error, null, this)
            }
    }

private const val HTTP_PAYLOAD_TOO_LARGE = 413
private const val HTTP_REQUEST_TIMEOUT = 408
private const val HTTP_TOO_MANY_REQUESTS = 429
private const val HTTP_SERVER_ERROR = 500

/**
 * 同一份請求稍後重送有機會成功嗎？上傳佇列用它決定「排退避重試」或「終局失敗」：
 * 連線失敗、伺服器 5xx／408／429、session 暫時失效（token 刷新中、尚未登入）→ true；
 * 額度（LS002）、413、權限（42501）、其餘自訂碼與 4xx → false（重送同樣的位元組只會得到同樣的結果）。
 */
val BackendError.isTransient: Boolean
    get() =
        when (this) {
            is BackendError.Network, is BackendError.NotSignedIn, is BackendError.Auth -> true
            is BackendError.Server -> (cause as? RestException)?.statusCode?.let(::isTransientStatus) ?: false
            else -> false
        }

private fun isTransientStatus(status: Int): Boolean =
    status >= HTTP_SERVER_ERROR || status == HTTP_REQUEST_TIMEOUT || status == HTTP_TOO_MANY_REQUESTS

/** 一對一的簡單映射（docs/API.md §5）；需要解析 DETAIL 或帶訊息的碼在 [mapPostgrest] 另外處理。 */
private val simpleMappers: Map<String, (PostgrestRestException) -> BackendError> =
    mapOf(
        "LS001" to { BackendError.FamilyMustHaveOwner(it) },
        "LS002" to { BackendError.StorageQuotaExceeded(it) },
        "LS010" to { BackendError.InviteNotFound(it) },
        "LS011" to { BackendError.InviteExpired(it) },
        "LS012" to { BackendError.InviteExhausted(it) },
        "LS013" to { BackendError.AlreadyMember(it) },
        "LS014" to { BackendError.JoinRequestAlreadyPending(it) },
        "LS015" to { BackendError.JoinRequestNotFound(it) },
        "LS016" to { BackendError.InviteCodeCollision(it) },
        "LS017" to { BackendError.InviteParamsInvalid(it) },
        "LS020" to { BackendError.DiaryNotFound(it) },
        "LS021" to { BackendError.NotDiaryAuthor(it) },
        "LS022" to { BackendError.PartialCursor(it) },
        "LS024" to { BackendError.CommentNotFound(it) },
        "LS026" to { BackendError.TargetFamilyMismatch(it) },
        "LS027" to { BackendError.RemovedByOwner(it) },
        "LS041" to { BackendError.ChildNotFound(it) },
        "LS042" to { BackendError.NotChildEditor(it) },
        "LS043" to { BackendError.RestoreWindowExpired(it) },
        "LS044" to { BackendError.ChildDeleted(it) },
        "LS051" to { BackendError.AccountDeletionPending(it) },
        "LS052" to { BackendError.AccountSuspended(it) },
        "LS053" to { BackendError.FamilySuspended(it) },
        "LS054" to { BackendError.RegistrationsClosed(it) },
    )

private fun mapPostgrest(e: PostgrestRestException): BackendError {
    val code = e.code
    val message = e.description ?: e.error
    return when {
        code == null -> BackendError.Server(message, null, e)
        code in simpleMappers -> simpleMappers.getValue(code)(e)
        code == "LS050" || code == "LS057" ->
            parseTransferFamilies(code, e.details)?.let { BackendError.MustTransferOwnership(code, it, e) }
                ?: BackendError.Server("$code 的 DETAIL 無法解析：${e.details}", code, e)
        code == "42501" -> BackendError.PermissionDenied(message, e)
        else -> BackendError.Server(message, code, e)
    }
}

/**
 * `LS050` 的 DETAIL 是 JSON 陣列 `[{"family_id","family_name"}, ...]`；`LS057` 是單一物件 `{"family_id","family_name"}`。
 * PostgREST 把 DETAIL 當字串放進 `details`。解不出來回 null，由呼叫端轉成 Server 錯誤（fail loud）——
 * 回空清單會讓 UI 顯示「沒有待轉移家庭、卻又進不去」的死路（同 iOS `parsePendingTransfers`）。
 */
private fun parseTransferFamilies(
    code: String,
    details: JsonElement?,
): List<PendingTransferFamily>? {
    val text = (details as? JsonPrimitive)?.contentOrNull ?: details?.toString()
    if (text.isNullOrBlank()) return null
    return runCatching {
        val element = detailJson.parseToJsonElement(text)
        if (code == "LS057" && element is JsonObject) {
            listOf(detailJson.decodeFromJsonElement(PendingTransferFamily.serializer(), element))
        } else {
            detailJson.decodeFromJsonElement(ListSerializer(PendingTransferFamily.serializer()), element)
        }
    }.getOrNull()
}
