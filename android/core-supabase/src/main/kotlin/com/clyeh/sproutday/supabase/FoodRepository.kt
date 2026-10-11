package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.order
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * 飲食圖鑑（docs/API.md §3 `food_catalog`／`child_food_records`、§4）。錯誤碼轉成 [BackendError]
 * （`42501`／`LS027`／`LS044`）；食物 id 不在目錄 `23503`、備註超過 2000 字或 reaction 不合法 `23514` 落到 [BackendError.Server]。
 */
class FoodRepository(
    private val client: SupabaseClient,
) {
    /**
     * 讀整張 `food_catalog`（唯讀目錄，不分家庭；274 種，遠低於 PostgREST 的 1000 列上限，所以一次讀全表、不分頁，同 iOS
     * `listFoodCatalog`）。只回 `active` 的品項，依 `sort_order` 排序（全域唯一）。
     */
    suspend fun catalog(): List<FoodCatalogItem> =
        backend {
            client
                .from("food_catalog")
                .select(Columns.raw("id,name_zh,category,sort_order,allergens,min_age_months")) {
                    filter { eq("active", true) }
                    order("sort_order", Order.ASCENDING)
                }.decodeList<FoodCatalogItem>()
        }

    /**
     * `list_child_food_records`：未軟刪的飲食紀錄，`first_tried_on desc, id desc`；**不分頁**（食物目錄 274 種是天花板）。
     * 傳不屬於自己家庭的寶貝不報錯，只回 0 列。
     */
    suspend fun listRecords(childId: String): List<ChildFoodRecord> =
        backend {
            client.postgrest
                .rpc("list_child_food_records", buildJsonObject { put("p_child_id", childId) })
                .decodeList<ChildFoodRecord>()
        }

    /**
     * `upsert_child_food_record`：自然鍵 `(child_id, food_id)` upsert——沒有未刪紀錄就新增、有就整組替換（PUT 語意，僅原作者），
     * **重送結果相同**（連點兩次最後恰好一列），所以呼叫端不必先查既存 id；以回傳列為準。owner／member 可呼叫。
     * [mediaId] 必須是同家庭的 media（跨家庭 `23503`）。錯誤：寶貝不存在或不屬於呼叫者 `42501`；已有紀錄但呼叫者不是原作者 `42501`；
     * 寶貝已軟刪 [BackendError.ChildDeleted]。
     */
    @Suppress("LongParameterList") // 一個欄位一個參數，對應 RPC 簽章
    suspend fun upsertRecord(
        childId: String,
        foodId: String,
        firstTriedOn: String,
        mediaId: String?,
        note: String?,
        reaction: FoodReaction?,
    ): ChildFoodRecord =
        backend {
            client.postgrest
                .rpc(
                    "upsert_child_food_record",
                    buildJsonObject {
                        put("p_child_id", childId)
                        put("p_food_id", foodId)
                        put("p_first_tried_on", firstTriedOn)
                        put("p_media_id", mediaId)
                        put("p_note", note)
                        put("p_reaction", reaction?.wire)
                    },
                ).decodeAs<ChildFoodRecord>()
        }

    /**
     * `delete_child_food_record`：軟刪（這格圖鑑退回未嘗試；之後可再 [upsertRecord] 新增一筆全新紀錄）。作者本人或該家庭 owner 可呼叫；
     * 紀錄不存在、既非作者也非 owner `42501`；owner 已移除後作者再呼叫 [BackendError.RemovedByOwner]。
     */
    suspend fun deleteRecord(id: String) {
        backend {
            client.postgrest.rpc("delete_child_food_record", buildJsonObject { put("p_id", id) })
        }
    }

    /**
     * `list_family_photos_for_food`：03d「從家庭相簿挑」的照片列表——該寶貝所屬家庭、未軟刪的照片，**排除**只掛在飲食紀錄上的照片，
     * `created_at desc, id desc`，最多 [limit] 張（iOS 傳 300）。傳不屬於自己家庭的寶貝不報錯，只回 0 列。
     */
    suspend fun familyPhotos(
        childId: String,
        limit: Int = FAMILY_PHOTO_LIMIT,
    ): List<FamilyPhoto> =
        backend {
            client.postgrest
                .rpc(
                    "list_family_photos_for_food",
                    buildJsonObject {
                        put("p_child_id", childId)
                        put("p_limit", limit)
                    },
                ).decodeList<FamilyPhoto>()
        }

    private companion object {
        const val FAMILY_PHOTO_LIMIT = 300
    }
}
