package com.clyeh.sproutday.supabase

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID

/**
 * 契約測試（LS-493）：對本機 Supabase 容器驗證 docs/API.md §4 的日記寫入——建（標記寶貝）→ 改（body＋日期）→ 附照片（`diary_media`）→
 * 時間軸與詳情讀得到 → 非作者改寫 `LS021` → 軟刪後時間軸／詳情消失 → 還原後回來；以及跨家庭寶貝標記 `23503`。
 * A 是家庭 owner＋作者，B 是同家庭 member。容器沒設定／非本機時整批略過（見 [ContractEnv]）。
 */
class DiaryContractTest {
    private lateinit var config: SupabaseConfig

    @Before
    fun requireLocalContainer() {
        config = ContractEnv.requireLocalConfig()
    }

    @Test
    fun diaryWriteAgainstLocalContainer() =
        runBlocking<Unit> {
            val s = newScene()
            val diaryId = assertCreateUpdateAttach(s)
            assertNonAuthorRejected(s, diaryId)
            assertSoftDeleteAndRestore(s, diaryId)
            assertCrossFamilyChildRejected(s)
        }

    /** A 建家庭與寶貝；B 以 member 加入。 */
    private suspend fun newScene(): Scene {
        val a = Actor(TestUsers.signIn(config, "diarya"))
        val b = Actor(TestUsers.signIn(config, "diaryb"))
        val family = a.user.family.createFamily("日記契約測試家庭")
        val invite = a.user.join.createInvite(family.id, FamilyRole.Member, Instant.now().plus(1, ChronoUnit.DAYS), 1)
        val pending = b.user.join.requestJoin(invite.code) as JoinOutcome.Pending
        a.user.join.approveJoin(pending.requestId)
        return Scene(a, b, family.id, a.children.createChild(family.id, "日記寶貝", "2024-01-01"))
    }

    /** 建（標記寶貝）→ 改 body＋日期（重送相同）→ 上傳一張並掛上（重掛不重複）→ 時間軸與詳情讀得到。 */
    private suspend fun assertCreateUpdateAttach(s: Scene): String {
        val diaryId = s.a.diary.createEntry(s.familyId, listOf(s.childId), "第一版內文", "2025-01-01")
        s.a.diary.updateEntry(diaryId, "第二版內文", "2025-02-02", listOf(s.childId))
        s.a.diary.updateEntry(diaryId, "第二版內文", "2025-02-02", listOf(s.childId)) // 重送結果相同

        val mediaId = s.a.uploadPhoto(s.familyId)
        s.a.diary.attachMedia(diaryId, s.familyId, listOf(mediaId))
        s.a.diary.attachMedia(diaryId, s.familyId, listOf(mediaId)) // 重掛收斂到同一個終態

        val pointer = s.a.timelineDiary(s.familyId, diaryId)
        assertNotNull("時間軸應出現這篇 diary 卡", pointer)
        assertEquals("child_ids 含被標記的寶貝", listOf(s.childId), pointer?.childIds)
        val detail = checkNotNull(s.a.feed.diaryDetail(diaryId)) { "作者應讀得到自己的日記" }
        assertEquals("update 整組替換 body", "第二版內文", detail.diary.body)
        assertEquals("update 整組替換日期", "2025-02-02", detail.diary.entryDate)
        assertEquals("author_id 恆為呼叫者", s.a.user.id, detail.diary.authorId)
        assertEquals("附照片：diaryDetail 讀到該 media，重掛不重複", listOf(mediaId), detail.media.map { it.id })
        assertEquals(listOf(s.childId), detail.childIds)
        assertNotNull("同家庭 member 看得到", s.b.timelineDiary(s.familyId, diaryId))
        return diaryId
    }

    /** B 是同家庭 member 但不是作者：改寫 `LS021`，且沒有改到資料。 */
    private suspend fun assertNonAuthorRejected(
        s: Scene,
        diaryId: String,
    ) {
        val denied = expectError<BackendError.NotDiaryAuthor> { s.b.diary.updateEntry(diaryId, "B 想改", "2025-03-03", emptyList()) }
        assertEquals("LS021", denied.code)
        val detail = checkNotNull(s.a.feed.diaryDetail(diaryId))
        assertEquals("被拒絕的寫入沒有改到資料", "第二版內文", detail.diary.body)
        assertEquals(listOf(s.childId), detail.childIds)
    }

    /** 軟刪（重送相同）→ 時間軸不含、詳情 null、編輯得 `LS020`；還原後時間軸又含。 */
    private suspend fun assertSoftDeleteAndRestore(
        s: Scene,
        diaryId: String,
    ) {
        s.a.diary.setDeleted(diaryId, deleted = true)
        s.a.diary.setDeleted(diaryId, deleted = true) // 重送結果相同
        assertNull("軟刪後時間軸不含這篇", s.a.timelineDiary(s.familyId, diaryId))
        assertNull("軟刪後詳情回 null", s.a.feed.diaryDetail(diaryId))
        assertNull("軟刪後同家庭 member 的時間軸也不含", s.b.timelineDiary(s.familyId, diaryId))
        val edit = expectError<BackendError.DiaryNotFound> { s.a.diary.updateEntry(diaryId, "x", "2025-02-02", emptyList()) }
        assertEquals("已軟刪須先還原才能編輯 → LS020", "LS020", edit.code)

        s.a.diary.setDeleted(diaryId, deleted = false)
        assertNotNull("還原後時間軸又含這篇", s.a.timelineDiary(s.familyId, diaryId))
        assertNotNull("還原後詳情讀得到", s.a.feed.diaryDetail(diaryId))
    }

    /** 標記別的家庭的寶貝：建立與更新都得 `23503`（複合外鍵），空陣列則是家庭共用（合法）。 */
    private suspend fun assertCrossFamilyChildRejected(s: Scene) {
        val other = s.a.user.family.createFamily("另一個家庭")
        val foreignChild = s.a.children.createChild(other.id, "別家寶貝", "2024-01-01")
        val create =
            expectError<BackendError.Server> { s.a.diary.createEntry(s.familyId, listOf(foreignChild), "跨家庭", "2025-04-04") }
        assertEquals("建立時標記別家寶貝 → 外鍵違反", "23503", create.code)

        val shared = s.a.diary.createEntry(s.familyId, emptyList(), "家庭共用", "2025-04-04")
        val update = expectError<BackendError.Server> { s.a.diary.updateEntry(shared, "跨家庭", "2025-04-04", listOf(foreignChild)) }
        assertEquals("更新時標記別家寶貝 → 外鍵違反", "23503", update.code)
        assertTrue("空陣列＝不標記寶貝", s.a.timelineDiary(s.familyId, shared)?.childIds?.isEmpty() == true)
    }

    private class Actor(
        val user: TestUser,
    ) {
        val children = ChildrenRepository(user.client)
        val diary = DiaryRepository(user.client)
        val feed = FeedRepository(user.client)

        /** 時間軸裡 kind=diary 且 ref_id 是 [diaryId] 的那一列；沒有回 null。 */
        suspend fun timelineDiary(
            familyId: String,
            diaryId: String,
        ): FeedPointer? =
            feed.timeline(familyId, limit = TIMELINE_LIMIT).firstOrNull { it.kind == FeedKind.DIARY && it.refId == diaryId }

        /** 上傳一張照片（原檔，不含縮圖）並建好 `media` 列（尚未掛任何日記／相簿）；回傳 media id。 */
        suspend fun uploadPhoto(familyId: String): String {
            val mediaId = UUID.randomUUID().toString()
            val path = MediaPaths.original(familyId, mediaId, "jpg", Instant.now())
            user.media.uploadBytes(path, TINY_JPEG, "image/jpeg")
            user.media.insertMedia(NewMedia(mediaId, familyId, path, TINY_JPEG.size.toLong(), 64, 48, null))
            return mediaId
        }
    }

    private class Scene(
        val a: Actor,
        val b: Actor,
        val familyId: String,
        val childId: String,
    )

    private companion object {
        const val TIMELINE_LIMIT = 100
    }
}
