package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * `families`／`family_members` 讀寫（docs/API.md §2–§3）。錯誤碼轉成 [BackendError]。
 *
 * 後端沒有 `create_family` RPC（票文用詞）：建立家庭是直接 INSERT `families`，DB trigger 自動把建立者寫成第一位 owner。
 */
class FamilyRepository(
    private val client: SupabaseClient,
) {
    /**
     * 建立家庭：`created_by` 必須是自己；建立者由 DB trigger 自動寫成第一位 owner，不要自己再寫 `family_members`。
     * 可能的錯誤：`LS051`（帳號刪除中）、`LS052`（停權）、`LS054`（暫停註冊）。
     */
    suspend fun createFamily(name: String): Family {
        val uid = client.requireUserId()
        return backend {
            client
                .from("families")
                .insert(CreateFamilyPayload(name = name, createdBy = uid)) { select() }
                .decodeSingle<Family>()
        }
    }

    /** 我所屬的家庭（RLS 已限縮，最舊的在前）。 */
    suspend fun fetchMyFamilies(): List<Family> =
        backend {
            client.from("families").select { order("created_at", Order.ASCENDING) }.decodeList<Family>()
        }

    suspend fun updateFamilyName(
        familyId: String,
        name: String,
    ) = updateFamily(familyId) { set("name", name) }

    suspend fun setRequireApproval(
        familyId: String,
        requireApproval: Boolean,
    ) = updateFamily(familyId) { set("require_approval", requireApproval) }

    /** RLS 是 USING 過濾：非 owner 時 UPDATE 合法執行但匹配 0 列、不丟錯（API.md §2），這裡明確轉成 [BackendError.NoRowsAffected]。 */
    private suspend fun updateFamily(
        familyId: String,
        set: io.github.jan.supabase.postgrest.query.PostgrestUpdate.() -> Unit,
    ) {
        val rows =
            backend {
                client
                    .from("families")
                    .update(set) {
                        select()
                        filter { eq("id", familyId) }
                    }.decodeList<Family>()
            }
        if (rows.isEmpty()) throw BackendError.NoRowsAffected("沒有權限修改這個家庭，或家庭不存在")
    }

    /** 家庭成員（含顯示名稱／頭像），owner 最前、其次 member、viewer；同角色依名稱排序。 */
    suspend fun listMembers(familyId: String): List<FamilyMember> {
        val rows =
            backend {
                client
                    .from("family_members")
                    .select(Columns.raw("user_id, role, profiles(display_name, avatar_url)")) {
                        filter { eq("family_id", familyId) }
                    }.decodeList<MemberRow>()
            }
        return rows
            .map { FamilyMember(it.userId, it.role, it.profiles?.displayName.orEmpty(), it.profiles?.avatarUrl) }
            .sortedWith(compareBy<FamilyMember> { it.role.sortRank }.thenBy { it.displayName })
    }

    /**
     * 移除成員／自行退出（owner 移除任何人；任何人可退出自己）。唯一 owner 且家庭還有其他成員 → [BackendError.MustTransferOwnership]（`LS057`）；
     * 會導致 0 owner 的其他情況 → [BackendError.FamilyMustHaveOwner]（`LS001`）。0 列受影響（無權限）明確轉成錯誤。
     */
    suspend fun removeMember(
        familyId: String,
        userId: String,
    ) {
        val rows =
            backend {
                client
                    .from("family_members")
                    .delete {
                        select(Columns.raw("user_id"))
                        filter {
                            eq("family_id", familyId)
                            eq("user_id", userId)
                        }
                    }.decodeList<MemberIdRow>()
            }
        if (rows.isEmpty()) throw BackendError.NoRowsAffected("沒有權限移除這位成員，或這位成員已經不在家庭裡")
    }
}

@Serializable
private data class CreateFamilyPayload(
    val name: String,
    @SerialName("created_by") val createdBy: String,
)

@Serializable
private data class MemberRow(
    @SerialName("user_id") val userId: String,
    val role: FamilyRole,
    val profiles: MemberProfile? = null,
)

@Serializable
private data class MemberProfile(
    @SerialName("display_name") val displayName: String,
    @SerialName("avatar_url") val avatarUrl: String? = null,
)

@Serializable
private data class MemberIdRow(
    @SerialName("user_id") val userId: String,
)
