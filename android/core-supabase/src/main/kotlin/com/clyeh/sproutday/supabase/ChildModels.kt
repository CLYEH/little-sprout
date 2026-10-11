package com.clyeh.sproutday.supabase

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * `list_children` 的一列（docs/API.md §4）。回傳全部列、不分角色、不分軟刪與否：[deletedAt] 非 null＝已軟刪（唯讀旗標），
 * 呼叫端要「只列 active」就自行濾。[birthday] 是 Postgres `date`，保留 `yyyy-MM-dd` 字串。
 */
@Serializable
data class Child(
    val id: String,
    val name: String,
    val birthday: String,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    @SerialName("deleted_at") val deletedAt: String? = null,
    @SerialName("created_at") val createdAt: String,
)

/**
 * `public.growth_records` 一列（`upsert_growth_record`／`list_growth_records` 的回傳）。[measuredOn] 是 `date`（`yyyy-MM-dd` 字串）；
 * 三項量測至少一項非 null（後端 CHECK）。
 */
@Serializable
data class GrowthRecord(
    val id: String,
    @SerialName("family_id") val familyId: String,
    @SerialName("child_id") val childId: String,
    @SerialName("author_id") val authorId: String? = null,
    @SerialName("measured_on") val measuredOn: String,
    @SerialName("height_cm") val heightCm: Double? = null,
    @SerialName("weight_kg") val weightKg: Double? = null,
    @SerialName("head_cm") val headCm: Double? = null,
    val note: String? = null,
    @SerialName("created_at") val createdAt: String,
    @SerialName("updated_at") val updatedAt: String,
    @SerialName("deleted_at") val deletedAt: String? = null,
    @SerialName("deleted_by") val deletedBy: String? = null,
) {
    /** 以這一列當「下一頁」的游標（取一頁的最後一列）。 */
    val cursor: GrowthCursor get() = GrowthCursor(measuredOn, id)
}

/** `list_growth_records` 的 keyset 游標 `(measured_on, id)`：一對一起傳，型別層面杜絕只傳一半（`LS022`）。 */
data class GrowthCursor(
    val measuredOn: String,
    val id: String,
)

/** `public.food_catalog` 的一列（唯讀目錄，docs/API.md §3）；只投影畫面用得到的欄位（同 iOS `FoodCatalogItem`）。 */
@Serializable
data class FoodCatalogItem(
    val id: String,
    @SerialName("name_zh") val nameZh: String,
    val category: String,
    @SerialName("sort_order") val sortOrder: Int,
    val allergens: List<String> = emptyList(),
    @SerialName("min_age_months") val minAgeMonths: Int? = null,
)

/** `child_food_records.reaction` 的值域（後端 CHECK，docs/API.md §3）。 */
@Serializable
enum class FoodReaction(
    val wire: String,
) {
    @SerialName("liked")
    LIKED("liked"),

    @SerialName("neutral")
    NEUTRAL("neutral"),

    @SerialName("disliked")
    DISLIKED("disliked"),
}

/** `public.child_food_records` 一列（`upsert_child_food_record`／`list_child_food_records` 的回傳）。 */
@Serializable
data class ChildFoodRecord(
    val id: String,
    @SerialName("family_id") val familyId: String,
    @SerialName("child_id") val childId: String,
    @SerialName("food_id") val foodId: String,
    @SerialName("author_id") val authorId: String? = null,
    @SerialName("first_tried_on") val firstTriedOn: String,
    @SerialName("media_id") val mediaId: String? = null,
    val note: String? = null,
    val reaction: FoodReaction? = null,
    @SerialName("created_at") val createdAt: String,
    @SerialName("updated_at") val updatedAt: String,
    @SerialName("deleted_at") val deletedAt: String? = null,
    @SerialName("deleted_by") val deletedBy: String? = null,
)

/** `list_family_photos_for_food` 的一列（03d 家庭相簿選擇器；已排除飲食專屬照片，欄位同 iOS `photoColumns`）。 */
@Serializable
data class FamilyPhoto(
    val id: String,
    @SerialName("storage_path") val storagePath: String,
    @SerialName("thumb_path") val thumbPath: String? = null,
    @SerialName("taken_at") val takenAt: String? = null,
    @SerialName("created_at") val createdAt: String,
)
