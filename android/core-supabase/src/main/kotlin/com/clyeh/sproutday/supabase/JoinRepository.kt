package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant

/**
 * 邀請與加入／核准流程的 RPC（docs/API.md §4、§7）。每支 RPC 的名稱、參數名（`p_*`）、錯誤碼照 API.md 逐支抄。
 *
 * 後端沒有 `join_with_code` RPC（票文用詞）：用邀請碼加入是 `request_join`，核准是 `approve_join`。
 */
class JoinRepository(
    private val client: SupabaseClient,
) {
    private val postgrest get() = client.postgrest

    /**
     * `create_invite(p_family_id, p_role, p_expires_at, p_max_uses) -> text`：僅該家庭 owner。
     * `expiresAt` 必須在現在～現在+30 天，`maxUses` 1–20，否則 `LS017`。RPC 只回傳 code，
     * 其餘欄位（id／used_count）從 `invites` 表反查（code 為 unique，同 iOS `fetchInvite(byCode:)`）。
     */
    suspend fun createInvite(
        familyId: String,
        role: FamilyRole,
        expiresAt: Instant,
        maxUses: Int,
    ): Invite =
        backend {
            val code =
                postgrest
                    .rpc(
                        "create_invite",
                        buildJsonObject {
                            put("p_family_id", familyId)
                            put("p_role", role.wireValue)
                            put("p_expires_at", expiresAt.toString())
                            put("p_max_uses", maxUses)
                        },
                    ).decodeAs<String>()
            client.from("invites").select { filter { eq("code", code) } }.decodeSingle<Invite>()
        }

    /** `request_join(p_code) -> table(status, request_id, family_id)`：碼會先在伺服器端正規化（去非英數、轉大寫）。 */
    suspend fun requestJoin(code: String): JoinOutcome {
        val row =
            backend {
                postgrest.rpc("request_join", buildJsonObject { put("p_code", code) }).decodeSingle<RequestJoinRow>()
            }
        return when (row.status) {
            "pending" ->
                JoinOutcome.Pending(
                    requestId = checkNotNull(row.requestId) { "request_join 回傳 pending 但缺少 request_id" },
                    familyId = row.familyId,
                )
            "joined" -> JoinOutcome.Joined(row.familyId)
            else -> error("request_join 回傳未知的 status：${row.status}")
        }
    }

    /** `approve_join(p_request_id)`：該申請所屬家庭的 owner；申請人寫入 `family_members`，角色取自邀請碼。 */
    suspend fun approveJoin(requestId: String) {
        backend { postgrest.rpc("approve_join", requestIdParams(requestId)) }
    }

    /** `reject_join(p_request_id)`：僅改申請狀態，不寫 `family_members`。 */
    suspend fun rejectJoin(requestId: String) {
        backend { postgrest.rpc("reject_join", requestIdParams(requestId)) }
    }

    /** `withdraw_join(p_request_id)`：申請人本人撤回仍是 pending 的申請，不退還邀請碼次數。 */
    suspend fun withdrawJoin(requestId: String) {
        backend { postgrest.rpc("withdraw_join", requestIdParams(requestId)) }
    }

    // 三支 RPC 的呼叫處各自寫字面值函式名（api-contract-check 的 Kotlin 掃描器不解析變數）。
    private fun requestIdParams(requestId: String) = buildJsonObject { put("p_request_id", requestId) }

    /** `list_join_requests()`：我是 owner 的所有家庭底下 pending 的申請（不帶 family_id，自行用回傳欄位分組），最舊在前。 */
    suspend fun listJoinRequests(): List<PendingJoinRequest> =
        backend { postgrest.rpc("list_join_requests").decodeList<PendingJoinRequest>() }

    /** `get_my_join_request()`：最多一列（有 pending 優先，否則最近一筆已處理）；從未申請過回 null（0 列不是錯誤）。 */
    suspend fun myJoinRequest(): MyJoinRequest? =
        backend { postgrest.rpc("get_my_join_request").decodeList<MyJoinRequest>() }.firstOrNull()
}

@Serializable
private data class RequestJoinRow(
    val status: String,
    @SerialName("request_id") val requestId: String? = null,
    @SerialName("family_id") val familyId: String,
)
