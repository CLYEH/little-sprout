package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * 成長紀錄（身高／體重／頭圍，docs/API.md §3 `growth_records`、§4）。錯誤碼轉成 [BackendError]
 * （`42501`／`LS022`／`LS027`／`LS044`）；量測全空、非正值、備註超過 2000 字 `23514` 落到 [BackendError.Server]。
 */
class GrowthRepository(
    private val client: SupabaseClient,
) {
    /**
     * `list_growth_records`：`measured_on desc, id desc`，真正的 2 元組 keyset 分頁。第一頁 [cursor] 傳 null，下一頁傳上一頁
     * 最後一列的 [GrowthRecord.cursor]（兩欄位成對送出，只送一個會得 `LS022`；同日多筆靠 id 當 tie-break 不漏）。
     * [limit] 由後端夾在 1..200。傳不屬於自己家庭的寶貝不報錯，只回 0 列。
     */
    suspend fun list(
        childId: String,
        cursor: GrowthCursor? = null,
        limit: Int = DEFAULT_PAGE_SIZE,
    ): List<GrowthRecord> =
        backend {
            client.postgrest
                .rpc(
                    "list_growth_records",
                    buildJsonObject {
                        put("p_child_id", childId)
                        put("p_limit", limit)
                        if (cursor != null) {
                            put("p_before", cursor.measuredOn)
                            put("p_before_id", cursor.id)
                        }
                    },
                ).decodeList<GrowthRecord>()
        }

    /**
     * `upsert_growth_record`：[id] 為 null＝新增（id 由後端產生，owner／member 可呼叫），回傳列的 id 才是這筆紀錄的身分；
     * [id] 非 null＝整組替換五個內容欄位（PUT 語意，**僅原作者本人**），重送結果相同。[childId] 只在新增有意義、更新被忽略。
     * **新增不冪等**——同一份請求送兩次會有兩筆，呼叫端以回傳列為準，重送前先確認上一次沒成功。
     * 錯誤：更新命中 0 列（不存在、不是作者）或新增的寶貝不屬於呼叫者任何家庭 `42501`；新增指向已軟刪寶貝 [BackendError.ChildDeleted]。
     */
    @Suppress("LongParameterList") // 一個欄位一個參數，對應 RPC 簽章
    suspend fun upsert(
        id: String?,
        childId: String,
        measuredOn: String,
        heightCm: Double?,
        weightKg: Double?,
        headCm: Double?,
        note: String?,
    ): GrowthRecord =
        backend {
            client.postgrest
                .rpc(
                    "upsert_growth_record",
                    buildJsonObject {
                        put("p_id", id)
                        put("p_child_id", childId)
                        put("p_measured_on", measuredOn)
                        put("p_height_cm", heightCm)
                        put("p_weight_kg", weightKg)
                        put("p_head_cm", headCm)
                        put("p_note", note)
                    },
                ).decodeAs<GrowthRecord>()
        }

    /**
     * `delete_growth_record`：軟刪（單向，沒有還原）。作者本人或該家庭 owner 可呼叫；紀錄不存在、既非作者也非 owner `42501`；
     * owner 已移除這筆後作者再呼叫 [BackendError.RemovedByOwner]。
     */
    suspend fun delete(id: String) {
        backend {
            client.postgrest.rpc("delete_growth_record", buildJsonObject { put("p_id", id) })
        }
    }

    private companion object {
        const val DEFAULT_PAGE_SIZE = 50
    }
}
