package com.clyeh.sproutday.supabase

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** `public.family_role`。 */
@Serializable
enum class FamilyRole(
    val sortRank: Int,
) {
    @SerialName("owner")
    Owner(0),

    @SerialName("member")
    Member(1),

    @SerialName("viewer")
    Viewer(2),

    ;

    /** 傳給 RPC 的字面值（`create_invite` 的 `p_role`）。 */
    val wireValue: String get() = name.lowercase()
}

/** `public.profiles` 可讀欄位子集（docs/API.md §3）。 */
@Serializable
data class Profile(
    val id: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("avatar_url") val avatarUrl: String? = null,
)

/** `public.families` 可讀欄位子集；刻意不投影額度欄位（同 iOS `Family`）。 */
@Serializable
data class Family(
    val id: String,
    val name: String,
    @SerialName("created_by") val createdBy: String? = null,
    @SerialName("created_at") val createdAt: String,
    @SerialName("require_approval") val requireApproval: Boolean,
)

/** `family_members` 一列 join `profiles`（PostgREST FK 內嵌）。 */
data class FamilyMember(
    val userId: String,
    val role: FamilyRole,
    val displayName: String,
    val avatarUrl: String?,
)

/** `public.invites` 可讀欄位子集；`create_invite` 只回傳 code，其餘欄位由表反查。 */
@Serializable
data class Invite(
    val id: String,
    val code: String,
    val role: FamilyRole,
    @SerialName("max_uses") val maxUses: Int,
    @SerialName("used_count") val usedCount: Int,
    @SerialName("expires_at") val expiresAt: String,
)

/** `request_join` 的結果：家庭開審核則待審，關審核則直接入家。 */
sealed interface JoinOutcome {
    data class Pending(
        val requestId: String,
        val familyId: String,
    ) : JoinOutcome

    data class Joined(
        val familyId: String,
    ) : JoinOutcome
}

/** `list_join_requests` 一列（owner 的審核佇列）。 */
@Serializable
data class PendingJoinRequest(
    @SerialName("request_id") val requestId: String,
    @SerialName("family_id") val familyId: String,
    @SerialName("applicant_id") val applicantId: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    val role: FamilyRole,
    @SerialName("created_at") val createdAt: String,
)

/** `get_my_join_request` 的一列（我送出的申請）。`status`：pending／approved／rejected／withdrawn。 */
@Serializable
data class MyJoinRequest(
    @SerialName("request_id") val requestId: String,
    @SerialName("family_id") val familyId: String,
    @SerialName("family_name") val familyName: String,
    val status: String,
    @SerialName("created_at") val createdAt: String,
    @SerialName("resolved_at") val resolvedAt: String? = null,
)

/** `delete_my_account` 的結果；呼叫端（本票的 UI 不呼叫）依此分流。 */
sealed interface DeleteAccountOutcome {
    /** 請求已記錄；實際刪除由 Edge Function `delete-account` 完成（另票）。 */
    data object Requested : DeleteAccountOutcome

    /** `LS050`：須先轉移這些家庭的 owner。 */
    data class MustTransferOwnership(
        val families: List<PendingTransferFamily>,
    ) : DeleteAccountOutcome
}
