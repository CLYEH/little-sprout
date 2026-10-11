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
            assertGrowthUpsertSameIdUpdates(s)
            val growth = assertGrowthPagingAndDelete(s)
            val food = assertFoodRecords(s)
            assertFamilyPhotosForFood(s)
            assertNonMemberRejected(s, growth, food)
            assertChildSoftDeleteGuards(s)
            assertSoftDeleteKeepsRecordsAndRestore(s)
        }

    /** A 建家庭與寶貝；C 另外登入但不是這個家庭的成員。 */
    private suspend fun newScene(): Scene {
        val a = Actor(TestUsers.signIn(config, "kida"))
        val c = Actor(TestUsers.signIn(config, "kidc"))
        val family = a.user.family.createFamily("寶貝契約測試家庭")
        val childId = a.children.createChild(family.id, "契約寶貝", "2024-01-01")
        return Scene(a, c, family.id, childId)
    }

    /** 建立 → 改名（PUT 語意整組替換）→ 列出；非成員列出得 0 列；名字超長 `23514`。 */
    private suspend fun assertChildCreateUpdateList(s: Scene) {
        val created =
            s.a.children
                .listChildren(s.familyId)
                .single()
        assertEquals("剛建好的寶貝：id 與名字、生日照傳入的值", s.childId, created.id)
        assertEquals("契約寶貝", created.name)
        assertEquals("2024-01-01", created.birthday)
        assertNull("剛建好未軟刪", created.deletedAt)

        s.a.children.updateChild(s.childId, "契約寶貝改名", "2024-02-02", "avatars/x.jpg")
        s.a.children.updateChild(s.childId, "契約寶貝改名", "2024-02-02", "avatars/x.jpg") // 重送結果相同
        val listed =
            s.a.children
                .listChildren(s.familyId)
                .single()
        assertEquals("契約寶貝改名", listed.name)
        assertEquals("2024-02-02", listed.birthday)
        assertEquals("avatars/x.jpg", listed.avatarUrl)
        assertNull(listed.deletedAt)

        assertTrue(
            "非家庭成員不報錯、只回 0 列",
            s.c.children
                .listChildren(s.familyId)
                .isEmpty(),
        )
        val tooLong =
            expectError<BackendError.Server> { s.a.children.createChild(s.familyId, "名".repeat(51), "2024-01-01") }
        assertEquals("名字超過 50 字 → CHECK 違反", "23514", tooLong.code)
    }

    /** 同 id 第二次是更新不是新增：回傳同一列、列表仍 1 筆、值是新值。 */
    private suspend fun assertGrowthUpsertSameIdUpdates(s: Scene) {
        val first = s.a.growth.upsert(null, s.childId, "2025-01-10", 70.5, 8.2, null, "第一筆")
        val updated = s.a.growth.upsert(first.id, s.childId, "2025-01-10", 71.0, 8.5, 44.0, "改過")
        assertEquals("同 id 第二次是更新：回傳同一列", first.id, updated.id)
        val rows = s.a.growth.list(s.childId)
        assertEquals("同 id 第二次是更新不是新增：列表仍 1 筆", 1, rows.size)
        val row = rows.single()
        assertEquals("值是新值", 71.0, row.heightCm ?: Double.NaN, 0.0)
        assertEquals(44.0, row.headCm ?: Double.NaN, 0.0)
        assertEquals("改過", row.note)
        assertEquals(s.a.user.id, row.authorId)
    }

    /** 再新增兩筆（含同日）→ limit 1 逐頁走訪不漏不重 → 半游標 `LS022` → 軟刪一筆；回傳剩下的紀錄（新→舊）。 */
    private suspend fun assertGrowthPagingAndDelete(s: Scene): List<GrowthRecord> {
        val first =
            s.a.growth
                .list(s.childId)
                .single()
        val second = s.a.growth.upsert(null, s.childId, "2025-02-10", 75.0, null, null, null)
        val sameDay = s.a.growth.upsert(null, s.childId, "2025-02-10", null, 9.0, null, null)
        val all = s.a.growth.list(s.childId)
        assertEquals("measured_on desc，最舊的在最後", first.id, all.last().id)

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
        assertEquals("走訪順序＝一次讀全部的順序", all.map { it.id }, walked)

        val halfCursor = expectError<BackendError.PartialCursor> { s.a.listGrowthHalfCursor(s.childId) }
        assertEquals("LS022", halfCursor.code)
        val noMeasure =
            expectError<BackendError.Server> {
                s.a.growth.upsert(
                    null,
                    s.childId,
                    "2025-03-01",
                    null,
                    null,
                    null,
                    null,
                )
            }
        assertEquals("三項量測全空 → CHECK 違反", "23514", noMeasure.code)

        s.a.growth.delete(sameDay.id)
        s.a.growth.delete(sameDay.id) // 重送結果相同
        val remaining = s.a.growth.list(s.childId)
        assertEquals("軟刪後列表不含該筆", setOf(first.id, second.id), remaining.map { it.id }.toSet())
        return remaining
    }

    /** 目錄 → 自然鍵 upsert 第二次是更新 → 食物不在目錄 `23503` → 軟刪後可再新增；回傳目前存活的那筆。 */
    private suspend fun assertFoodRecords(s: Scene): ChildFoodRecord {
        val catalog = s.a.food.catalog()
        assertTrue("目錄至少 1 筆", catalog.isNotEmpty())
        assertEquals("依 sort_order 遞增", catalog.map { it.sortOrder }.sorted(), catalog.map { it.sortOrder })
        assertEquals("id 不重複", catalog.size, catalog.map { it.id }.toSet().size)
        val foodId = catalog.first().id
        val photo = s.a.uploadPhoto(s.familyId, inAlbum = true)

        val first = s.a.food.upsertRecord(s.childId, foodId, "2025-03-01", photo, "好吃", FoodReaction.LIKED)
        val again = s.a.food.upsertRecord(s.childId, foodId, "2025-03-02", photo, "普通", FoodReaction.NEUTRAL)
        assertEquals("自然鍵 (child, food) 第二次是更新：同一列", first.id, again.id)
        val listed =
            s.a.food
                .listRecords(s.childId)
                .single()
        assertEquals("列表恰好一筆、值為新值", again.id, listed.id)
        assertEquals("2025-03-02", listed.firstTriedOn)
        assertEquals(FoodReaction.NEUTRAL, listed.reaction)
        assertEquals(photo, listed.mediaId)
        assertEquals(foodId, listed.foodId)

        val unknown =
            expectError<BackendError.Server> {
                s.a.food.upsertRecord(
                    s.childId,
                    "no_such_food",
                    "2025-03-01",
                    null,
                    null,
                    null,
                )
            }
        assertEquals("食物不在目錄 → 外鍵違反", "23503", unknown.code)

        s.a.food.deleteRecord(first.id)
        s.a.food.deleteRecord(first.id) // 重送結果相同
        assertTrue(
            "軟刪後列表不含",
            s.a.food
                .listRecords(s.childId)
                .isEmpty(),
        )
        val reborn = s.a.food.upsertRecord(s.childId, foodId, "2025-03-04", null, null, FoodReaction.DISLIKED)
        assertNotEquals("軟刪後同一食物可再新增一筆全新紀錄", first.id, reborn.id)
        assertEquals(
            listOf(reborn.id),
            s.a.food
                .listRecords(s.childId)
                .map { it.id },
        )
        return reborn
    }

    /** 家庭相簿照片：已在相簿的照片掛飲食紀錄後仍列出；只掛在飲食紀錄上的照片被排除（C3a）；非成員得 0 列。 */
    private suspend fun assertFamilyPhotosForFood(s: Scene) {
        val catalog = s.a.food.catalog()
        val albumPhoto = s.a.uploadPhoto(s.familyId, inAlbum = true)
        val foodOnlyPhoto = s.a.uploadPhoto(s.familyId, inAlbum = false)
        val before =
            s.a.food
                .familyPhotos(s.childId)
                .map { it.id }
        assertTrue("兩張新照片都還沒掛飲食紀錄 → 都列出", before.containsAll(listOf(albumPhoto, foodOnlyPhoto)))
        assertTrue("created_at desc：後上傳的在前", before.indexOf(foodOnlyPhoto) < before.indexOf(albumPhoto))

        val record = s.a.food.upsertRecord(s.childId, catalog[1].id, "2025-03-03", foodOnlyPhoto, null, null)
        s.a.food.upsertRecord(s.childId, catalog[2].id, "2025-03-03", albumPhoto, null, null)
        val after =
            s.a.food
                .familyPhotos(s.childId)
                .map { it.id }
        assertTrue("相簿裡的照片掛飲食紀錄後仍列出", albumPhoto in after)
        assertFalse("只掛在飲食紀錄上的照片被排除", foodOnlyPhoto in after)
        assertTrue(
            "非家庭成員得 0 列",
            s.c.food
                .familyPhotos(s.childId)
                .isEmpty(),
        )

        s.a.food
            .listRecords(s.childId)
            .filter {
                it.id != record.id && it.foodId == catalog[2].id
            }.forEach { s.a.food.deleteRecord(it.id) }
        s.a.food.deleteRecord(record.id)
    }

    /** 非家庭成員：讀回 0 列、寫入得 `42501`（不分新增／更新／軟刪），且沒有改到資料。 */
    private suspend fun assertNonMemberRejected(
        s: Scene,
        growth: List<GrowthRecord>,
        food: ChildFoodRecord,
    ) {
        val target = growth.first()
        assertTrue(
            s.c.growth
                .list(s.childId)
                .isEmpty(),
        )
        assertTrue(
            s.c.food
                .listRecords(s.childId)
                .isEmpty(),
        )
        val insert =
            expectError<BackendError.PermissionDenied> {
                s.c.growth.upsert(
                    null,
                    s.childId,
                    "2025-04-01",
                    80.0,
                    null,
                    null,
                    null,
                )
            }
        assertEquals("新增成長紀錄（RLS WITH CHECK 違反）", "42501", insert.code)
        expectError<BackendError.PermissionDenied> {
            s.c.growth.upsert(target.id, s.childId, target.measuredOn, 99.0, null, null, null)
        }
        expectError<BackendError.PermissionDenied> { s.c.growth.delete(target.id) }
        expectError<BackendError.PermissionDenied> {
            s.c.food.upsertRecord(s.childId, food.foodId, "2025-04-01", null, null, null)
        }
        expectError<BackendError.PermissionDenied> { s.c.food.deleteRecord(food.id) }
        expectError<BackendError.PermissionDenied> { s.c.children.setChildDeleted(s.childId, deleted = true) }
        assertEquals(
            "被拒絕的寫入沒有改到資料",
            target,
            s.a.growth
                .list(s.childId)
                .single { it.id == target.id },
        )
    }

    /** 軟刪：仍列得到（`deleted_at` 非空）、重複軟刪不刷新時鐘、不能再歸屬新內容（`LS044`）、不能編輯（`LS041`）。 */
    private suspend fun assertChildSoftDeleteGuards(s: Scene) {
        s.a.children.setChildDeleted(s.childId, deleted = true)
        val deleted =
            s.a.children
                .listChildren(s.familyId)
                .single()
        assertNotNull("軟刪後 list_children 仍回該列，deleted_at 非空", deleted.deletedAt)
        s.a.children.setChildDeleted(s.childId, deleted = true)
        assertEquals(
            "重複軟刪是 no-op、不刷新 deleted_at",
            deleted.deletedAt,
            s.a.children
                .listChildren(s.familyId)
                .single()
                .deletedAt,
        )

        val growthGuard =
            expectError<BackendError.ChildDeleted> {
                s.a.growth.upsert(
                    null,
                    s.childId,
                    "2025-05-01",
                    80.0,
                    null,
                    null,
                    null,
                )
            }
        assertEquals("LS044", growthGuard.code)
        val foodId =
            s.a.food
                .listRecords(s.childId)
                .single()
                .foodId
        expectError<BackendError.ChildDeleted> {
            s.a.food.upsertRecord(
                s.childId,
                foodId,
                "2025-05-01",
                null,
                null,
                null,
            )
        }
        val editGuard =
            expectError<BackendError.ChildNotFound> { s.a.children.updateChild(s.childId, "改名", "2024-02-02") }
        assertEquals("LS041", editGuard.code)
    }

    /** 軟刪不連動（成長／飲食紀錄照列）；還原後恢復新增。 */
    private suspend fun assertSoftDeleteKeepsRecordsAndRestore(s: Scene) {
        assertEquals(
            "軟刪不連動：成長紀錄照列",
            2,
            s.a.growth
                .list(s.childId)
                .size,
        )
        assertEquals(
            "軟刪不連動：飲食紀錄照列",
            1,
            s.a.food
                .listRecords(s.childId)
                .size,
        )

        s.a.children.setChildDeleted(s.childId, deleted = false)
        assertNull(
            "還原後 deleted_at 清空",
            s.a.children
                .listChildren(s.familyId)
                .single()
                .deletedAt,
        )
        assertFalse(
            "還原後又能新增成長紀錄",
            s.a.growth
                .upsert(null, s.childId, "2025-05-01", 80.0, null, null, null)
                .id
                .isBlank(),
        )
    }

    private class Actor(
        val user: TestUser,
    ) {
        val children = ChildrenRepository(user.client)
        val growth = GrowthRepository(user.client)
        val food = FoodRepository(user.client)

        /** 只送 `p_before` 不送 `p_before_id`（型別層面 [GrowthCursor] 擋掉的用法）→ 後端 `LS022`。 */
        suspend fun listGrowthHalfCursor(childId: String) {
            backend {
                user.client.postgrest.rpc(
                    "list_growth_records",
                    buildJsonObject {
                        put("p_child_id", childId)
                        put("p_before", "2025-02-10")
                    },
                )
            }
        }

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
}
