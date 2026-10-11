package com.clyeh.sproutday.supabase

import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.util.UUID

/**
 * 契約測試（LS-492）：對本機 Supabase 容器驗證 docs/API.md §4 的寶貝（建／改／列／軟刪）、成長紀錄（upsert／keyset 分頁／軟刪）、
 * 飲食圖鑑（目錄、自然鍵 upsert、軟刪、家庭相簿照片）與錯誤碼。A 是家庭 owner，C 不是該家庭成員。
 * 容器沒設定／非本機時整批略過（見 [ContractEnv]）。
 */
class ChildrenGrowthFoodContractTest {
    private lateinit var config: SupabaseConfig

    @Before
    fun requireLocalContainer() {
        config = ContractEnv.requireLocalConfig()
    }

    @Test
    fun childrenGrowthAndFoodAgainstLocalContainer() =
        runBlocking<Unit> {
            val s = newScene()
            assertChildCreateUpdateList(s)
            val growth = assertGrowthUpsertAndPaging(s)
            val foodRecord = assertFoodCatalogAndRecords(s)
            assertNonMemberRejected(s, growth.first(), foodRecord)
            assertChildSoftDeleteGuards(s)
        }

    /** A 建家庭與寶貝；C 另外登入但不是這個家庭的成員。 */
    private suspend fun newScene(): Scene {
        val a = Actor(TestUsers.signIn(config, "kida"))
        val c = Actor(TestUsers.signIn(config, "kidc"))
        val family = a.user.family.createFamily("寶貝契約測試家庭")
        val childId = a.children.createChild(family.id, "契約寶貝", "2024-01-01")
        return Scene(a, c, family.id, childId)
    }

    /** 建立 → 改名（PUT 語意整組替換）→ 列出；非成員列出得 0 列。 */
    private suspend fun assertChildCreateUpdateList(s: Scene) {
        val created = s.a.children.listChildren(s.familyId).single()
        assertEquals("剛建好的寶貝：id、名字與生日照傳入的值", Triple(s.childId, "契約寶貝", "2024-01-01"), Triple(created.id, created.name, created.birthday))
        assertNull("剛建好未軟刪", created.deletedAt)
        s.a.children.updateChild(s.childId, "契約寶貝改名", "2024-02-02", "avatars/x.jpg")
        s.a.children.updateChild(s.childId, "契約寶貝改名", "2024-02-02", "avatars/x.jpg") // 重送結果相同
        val listed = s.a.children.listChildren(s.familyId).single()
        assertEquals("契約寶貝改名", listed.name)
        assertEquals("2024-02-02", listed.birthday)
        assertEquals("avatars/x.jpg", listed.avatarUrl)
        assertNull(listed.deletedAt)
        assertTrue("非家庭成員不報錯、只回 0 列", s.c.children.listChildren(s.familyId).isEmpty())
        val tooLong = expectError<BackendError.Server> { s.a.children.createChild(s.familyId, "名".repeat(NAME_LIMIT + 1), "2024-01-01") }
        assertEquals("名字超過 50 字 → CHECK 違反", "23514", tooLong.code)
    }

    /** 同 id 第二次是更新不是新增 → 另兩筆（含同日）→ limit 1 逐頁走訪不漏不重 → 軟刪一筆；回傳剩下的紀錄（新→舊）。 */
    private suspend fun assertGrowthUpsertAndPaging(s: Scene): List<GrowthRecord> {
        val first = s.a.growth.upsert(null, s.childId, "2025-01-10", 70.5, 8.2, null, "第一筆")
        val updated = s.a.growth.upsert(first.id, s.childId, "2025-01-10", 71.0, 8.5, 44.0, "改過")
        assertEquals("同 id 第二次是更新：回傳同一列", first.id, updated.id)
        val afterUpdate = s.a.growth.list(s.childId)
        assertEquals("同 id 第二次是更新不是新增：列表仍 1 筆", 1, afterUpdate.size)
        assertEquals("值是新值", 71.0, afterUpdate.single().heightCm ?: Double.NaN, 0.0)
        assertEquals(44.0, afterUpdate.single().headCm ?: Double.NaN, 0.0)
        assertEquals("改過", afterUpdate.single().note)
        assertEquals(s.a.user.id, afterUpdate.single().authorId)

        val second = s.a.growth.upsert(null, s.childId, "2025-02-10", 75.0, null, null, null)
        val sameDay = s.a.growth.upsert(null, s.childId, "2025-02-10", null, 9.0, null, null)
        assertEquals("新增拿到不同 id、依 measured_on desc 排序，最舊的在最後", first.id, s.a.growth.list(s.childId).last().id)

        val walked = mutableListOf<String>()
        var cursor: GrowthCursor? = null
        while (true) {
            val page = s.a.growth.list(s.childId, cursor, limit = 1)
            if (page.isEmpty()) break
            assertEquals("limit 1 一頁一筆", 1, page.size)
            walked += page.single().id
            cursor = page.single().cursor
        }
        assertEquals("游標逐頁走訪：不漏、不重（含同日兩筆靠 id tie-break）", setOf(first.id, second.id, sameDay.id), walked.toSet())
        assertEquals("走訪順序＝一次讀全部的順序", s.a.growth.list(s.childId).map { it.id }, walked)

        val halfCursor =
            expectError<BackendError.PartialCursor> {
                backend {
                    s.a.user.client.postgrest.rpc(
                        "list_growth_records",
                        buildJsonObject {
                            put("p_child_id", s.childId)
                            put("p_before", "2025-02-10")
                        },
                    )
                }
            }
        assertEquals("LS022", halfCursor.code)
        val noMeasure = expectError<BackendError.Server> { s.a.growth.upsert(null, s.childId, "2025-03-01", null, null, null, null) }
        assertEquals("三項量測全空 → CHECK 違反", "23514", noMeasure.code)

        s.a.growth.delete(sameDay.id)
        s.a.growth.delete(sameDay.id) // 重送結果相同
        val remaining = s.a.growth.list(s.childId)
        assertEquals("軟刪後列表不含該筆", setOf(first.id, second.id), remaining.map { it.id }.toSet())
        return remaining
    }

    /** 目錄 → 自然鍵 upsert（掛照片）→ 列出 → 家庭相簿照片排除飲食專屬照片 → 軟刪後可再新增；回傳目前存活的那筆。 */
    private suspend fun assertFoodCatalogAndRecords(s: Scene): ChildFoodRecord {
        val catalog = s.a.food.catalog()
        assertTrue("目錄至少 1 筆", catalog.isNotEmpty())
        assertEquals("依 sort_order 遞增", catalog.map { it.sortOrder }.sorted(), catalog.map { it.sortOrder })
        assertEquals("id 不重複", catalog.size, catalog.map { it.id }.toSet().size)
        val foodId = catalog.first().id

        val albumPhoto = s.a.uploadPhoto(s.familyId, inAlbum = true)
        val foodOnlyPhoto = s.a.uploadPhoto(s.familyId, inAlbum = false)
        assertEquals(
            "挑照片清單：兩張都還沒掛飲食紀錄 → 都列出，新→舊",
            listOf(foodOnlyPhoto, albumPhoto),
            s.a.food.familyPhotos(s.childId).map { it.id },
        )

        val first = s.a.food.upsertRecord(s.childId, foodId, "2025-03-01", albumPhoto, "好吃", FoodReaction.LIKED)
        val again = s.a.food.upsertRecord(s.childId, foodId, "2025-03-02", albumPhoto, "普通", FoodReaction.NEUTRAL)
        assertEquals("自然鍵 (child, food) 第二次是更新：同一列", first.id, again.id)
        val listed = s.a.food.listRecords(s.childId).single()
        assertEquals("列表恰好一筆、值為新值", again.id, listed.id)
        assertEquals("2025-03-02", listed.firstTriedOn)
        assertEquals(FoodReaction.NEUTRAL, listed.reaction)
        assertEquals(albumPhoto, listed.mediaId)
        assertEquals(foodId, listed.foodId)

        s.a.food.upsertRecord(s.childId, catalog[1].id, "2025-03-03", foodOnlyPhoto, null, null)
        assertEquals(
            "相簿裡的照片掛飲食紀錄後仍列出；只掛在飲食紀錄上的照片被排除（C3a）",
            listOf(albumPhoto),
            s.a.food.familyPhotos(s.childId).map { it.id },
        )
        s.a.food.listRecords(s.childId).single { it.foodId == catalog[1].id }.let { s.a.food.deleteRecord(it.id) }

        val unknownFood = expectError<BackendError.Server> { s.a.food.upsertRecord(s.childId, "no_such_food", "2025-03-01", null, null, null) }
        assertEquals("食物不在目錄 → 外鍵違反", "23503", unknownFood.code)

        s.a.food.deleteRecord(first.id)
        s.a.food.deleteRecord(first.id) // 重送結果相同
        assertTrue("軟刪後列表不含", s.a.food.listRecords(s.childId).isEmpty())
        val reborn = s.a.food.upsertRecord(s.childId, foodId, "2025-03-04", null, null, FoodReaction.DISLIKED)
        assertNotEquals("軟刪後同一食物可再新增一筆全新紀錄", first.id, reborn.id)
        assertEquals(listOf(reborn.id), s.a.food.listRecords(s.childId).map { it.id })
        return reborn
    }

    /** 非家庭成員：讀回 0 列、寫入得 `42501`（不分新增／更新／軟刪）。 */
    private suspend fun assertNonMemberRejected(
        s: Scene,
        growth: GrowthRecord,
        food: ChildFoodRecord,
    ) {
        assertTrue(s.c.growth.list(s.childId).isEmpty())
        assertTrue(s.c.food.listRecords(s.childId).isEmpty())
        assertTrue(s.c.food.familyPhotos(s.childId).isEmpty())
        assertEquals(
            "新增成長紀錄（RLS WITH CHECK 違反）",
            "42501",
            expectError<BackendError.PermissionDenied> { s.c.growth.upsert(null, s.childId, "2025-04-01", 80.0, null, null, null) }.code,
        )
        expectError<BackendError.PermissionDenied> { s.c.growth.upsert(growth.id, s.childId, growth.measuredOn, 99.0, null, null, null) }
        expectError<BackendError.PermissionDenied> { s.c.growth.delete(growth.id) }
        expectError<BackendError.PermissionDenied> { s.c.food.upsertRecord(s.childId, food.foodId, "2025-04-01", null, null, null) }
        expectError<BackendError.PermissionDenied> { s.c.food.deleteRecord(food.id) }
        expectError<BackendError.PermissionDenied> { s.c.children.setChildDeleted(s.childId, deleted = true) }
        assertEquals("被拒絕的寫入沒有改到資料", growth, s.a.growth.list(s.childId).single { it.id == growth.id })
    }

    /** 軟刪：仍列得到（`deleted_at` 非空）、重複軟刪不刷新時鐘、不能再歸屬新內容（`LS044`）、不能編輯（`LS041`）、既有紀錄不連動；還原後恢復。 */
    private suspend fun assertChildSoftDeleteGuards(s: Scene) {
        s.a.children.setChildDeleted(s.childId, deleted = true)
        val deleted = s.a.children.listChildren(s.familyId).single()
        assertNotNull("軟刪後 list_children 仍回該列，deleted_at 非空", deleted.deletedAt)
        s.a.children.setChildDeleted(s.childId, deleted = true)
        assertEquals("重複軟刪是 no-op、不刷新 deleted_at", deleted.deletedAt, s.a.children.listChildren(s.familyId).single().deletedAt)

        assertEquals("LS044", expectError<BackendError.ChildDeleted> { s.a.growth.upsert(null, s.childId, "2025-05-01", 80.0, null, null, null) }.code)
        val foodId = s.a.food.listRecords(s.childId).single().foodId
        expectError<BackendError.ChildDeleted> { s.a.food.upsertRecord(s.childId, foodId, "2025-05-01", null, null, null) }
        assertEquals("LS041", expectError<BackendError.ChildNotFound> { s.a.children.updateChild(s.childId, "改名", "2024-02-02") }.code)
        assertEquals("軟刪不連動：成長紀錄照列", 2, s.a.growth.list(s.childId).size)
        assertEquals("軟刪不連動：飲食紀錄照列", 1, s.a.food.listRecords(s.childId).size)

        s.a.children.setChildDeleted(s.childId, deleted = false)
        assertNull("還原後 deleted_at 清空", s.a.children.listChildren(s.familyId).single().deletedAt)
        assertFalse("還原後又能新增成長紀錄", s.a.growth.upsert(null, s.childId, "2025-05-01", 80.0, null, null, null).id.isBlank())
    }

    private class Actor(
        val user: TestUser,
    ) {
        val children = ChildrenRepository(user.client)
        val growth = GrowthRepository(user.client)
        val food = FoodRepository(user.client)

        /** 上傳一張照片（原檔，不含縮圖），可選掛進一個新相簿（掛了相簿的照片不算飲食專屬）；回傳 media id。 */
        suspend fun uploadPhoto(
            familyId: String,
            inAlbum: Boolean,
        ): String {
            val mediaId = UUID.randomUUID().toString()
            val path = MediaPaths.original(familyId, mediaId, "jpg", Instant.now())
            user.media.uploadBytes(path, TINY_JPEG, "image/jpeg")
            user.media.insertMedia(NewMedia(mediaId, familyId, path, TINY_JPEG.size.toLong(), 64, 48, null))
            if (inAlbum) user.media.attachToAlbum(user.media.createAlbum(familyId, "飲食契約相簿").id, familyId, mediaId)
            return mediaId
        }
    }

    private class Scene(
        val a: Actor,
        val c: Actor,
        val familyId: String,
        val childId: String,
    )

    private companion object {
        const val NAME_LIMIT = 50
    }
}
