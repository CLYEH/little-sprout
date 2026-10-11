package com.clyeh.sproutday.supabase

import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit
import java.util.UUID

/**
 * 契約測試（LS-491）：對本機 Supabase 容器驗證 docs/API.md §4 的時間軸讀取（排序／分頁／寶貝篩選）、日記與相簿詳情、
 * 留言／愛心 RPC、封鎖可見性與留言軟刪。兩個帳號同一家庭：A 發佈（相簿＋照片＋兩篇同日日記），B 互動。
 * 容器沒設定／非本機時整批略過（見 [ContractEnv]）。
 */
class FeedSocialContractTest {
    private lateinit var config: SupabaseConfig

    @Before
    fun requireLocalContainer() {
        config = ContractEnv.requireLocalConfig()
    }

    @Test
    fun timelineCommentsReactionsBlockAndSoftDelete() =
        runBlocking<Unit> {
            val scene = publish()
            assertTimelineOrderAndPaging(scene)
            assertDetails(scene)
            val commentId = interact(scene)
            assertBlockVisibility(scene, commentId)
            assertCommentSoftDelete(scene, commentId)
        }

    /** A 建家庭、B 加入；A 發佈寶貝、相簿＋一張照片、兩篇同日日記（第二篇標寶貝並掛照片）。 */
    private suspend fun publish(): Scene {
        val a = Actor(TestUsers.signIn(config, "feeda"))
        val b = Actor(TestUsers.signIn(config, "feedb"))
        val family = a.user.family.createFamily("時間軸契約測試家庭")
        val invite = a.user.join.createInvite(family.id, FamilyRole.Member, Instant.now().plus(1, ChronoUnit.DAYS), 1)
        val pending = b.user.join.requestJoin(invite.code) as JoinOutcome.Pending
        a.user.join.approveJoin(pending.requestId)

        val childId =
            rpcString(a.user, "create_child") {
                put("p_family_id", family.id)
                put("p_name", "契約寶貝")
                put("p_birthday", "2024-01-01")
                put("p_avatar_url", JsonNull)
            }
        val album = a.user.media.createAlbum(family.id, "契約測試相簿")
        val mediaId = uploadPhoto(a.user, family.id, album.id)
        val sameDay = LocalDate.now(ZoneOffset.UTC).minusDays(DIARY_DAYS_AGO).toString()
        val diary1 = createDiary(a.user, family.id, "第一篇日記", sameDay, emptyList())
        val diary2 = createDiary(a.user, family.id, "第二篇日記", sameDay, listOf(childId))
        a.user.client
            .from("diary_media")
            .insert(DiaryMediaPayload(diary2, mediaId, family.id, 0))
        return Scene(a, b, family.id, childId, album, mediaId, diary1, diary2)
    }

    /** 排序（occurred_at desc；同日依建立順序倒序，LS-415）、分頁、寶貝篩選、半游標 `LS022`。 */
    private suspend fun assertTimelineOrderAndPaging(s: Scene) {
        val all = s.b.feed.timeline(s.familyId)
        assertEquals(
            "時間軸順序：照片、相簿（建立時間新→舊），其後同日兩篇日記依建立順序倒序",
            listOf(s.mediaId, s.album.id, s.diary2, s.diary1),
            all.map { it.refId },
        )
        assertEquals(
            listOf(FeedKind.MEDIA, FeedKind.ALBUM, FeedKind.DIARY, FeedKind.DIARY),
            all.map { it.kind },
        )
        assertEquals("標寶貝的日記帶 child_ids", listOf(s.childId), all.single { it.refId == s.diary2 }.childIds)

        val page1 = s.b.feed.timeline(s.familyId, limit = 2)
        val page2 = s.b.feed.timeline(s.familyId, cursor = page1.last().cursor, limit = 2)
        assertEquals("第一頁", listOf(s.mediaId, s.album.id), page1.map { it.refId })
        assertEquals("第二頁沿游標接續（不重複、不漏、同日邊界正確）", listOf(s.diary2, s.diary1), page2.map { it.refId })
        assertTrue(
            "游標之後沒有更多",
            s.b.feed
                .timeline(s.familyId, cursor = page2.last().cursor, limit = 2)
                .isEmpty(),
        )
        assertEquals(
            "寶貝篩選只回標記含該寶貝的項目",
            listOf(s.diary2),
            s.b.feed
                .timeline(s.familyId, childId = s.childId)
                .map { it.refId },
        )

        val halfCursor =
            expectError<BackendError.PartialCursor> {
                backend {
                    s.b.user.client.postgrest.rpc(
                        "get_family_timeline",
                        buildJsonObject {
                            put("p_family_id", s.familyId)
                            put("p_cursor_occurred_at", page1.last().occurredAt)
                        },
                    )
                }
            }
        assertEquals("LS022", halfCursor.code)
    }

    private suspend fun assertDetails(s: Scene) {
        val diary = checkNotNull(s.b.feed.diaryDetail(s.diary2)) { "B 應讀得到 A 的日記" }
        assertEquals("第二篇日記", diary.diary.body)
        assertEquals(listOf(s.mediaId), diary.media.map { it.id })
        assertEquals(listOf(s.childId), diary.childIds)
        val album = checkNotNull(s.b.feed.albumDetail(s.album.id)) { "B 應讀得到 A 的相簿" }
        assertEquals("契約測試相簿", album.album.title)
        assertEquals(listOf(s.mediaId), album.media.map { it.id })
        assertNull("不存在的日記回 null", s.b.feed.diaryDetail(UUID.randomUUID().toString()))
    }

    /** B 留言＋愛心（含錯誤碼案）→ A 讀到留言數與愛心數；回傳 B 的留言 id。 */
    private suspend fun interact(s: Scene): String {
        val commentId = s.b.social.createComment(s.familyId, ContentTargetType.ALBUM, s.album.id, "B 的留言")
        assertTrue("B 按愛心 → true（最終狀態＝已按）", s.b.social.toggleReaction(s.familyId, ContentTargetType.ALBUM, s.album.id))

        val foreignAlbum =
            s.b.user.media
                .createAlbum(
                    s.b.user.family
                        .createFamily("B 的另一個家庭")
                        .id,
                    "別家相簿",
                )
        val mismatch =
            expectError<BackendError.TargetFamilyMismatch> {
                s.b.social.createComment(s.familyId, ContentTargetType.ALBUM, foreignAlbum.id, "跨家庭")
            }
        assertEquals("LS026", mismatch.code)
        expectError<BackendError.TargetFamilyMismatch> {
            s.b.social.toggleReaction(s.familyId, ContentTargetType.ALBUM, foreignAlbum.id)
        }
        assertNotNull(
            "查不到的 target（孤兒 id）後端不驗證、照樣放行（API.md §3）",
            s.b.social.createComment(s.familyId, ContentTargetType.ALBUM, UUID.randomUUID().toString(), "孤兒"),
        )

        assertEquals("A 的時間軸看到 comment_count", 1L, s.a.commentCount(s))
        val seen = s.a.social.listComments(s.familyId, ContentTargetType.ALBUM, s.album.id)
        assertEquals(listOf(commentId), seen.comments.map { it.id })
        assertEquals("B 的留言", seen.comments.single().body)
        assertEquals(s.b.user.id, seen.comments.single().authorId)
        assertEquals(1L, seen.totalCount)

        val counts = s.a.social.reactionCounts(s.familyId, ContentTargetType.ALBUM, listOf(s.album.id, s.diary1))
        assertEquals(1L, counts.getValue(s.album.id).reactionCount)
        assertFalse("A 沒按過", counts.getValue(s.album.id).reactedByMe)
        assertFalse("沒有愛心的 target 不在結果裡（呼叫端視為 0）", s.diary1 in counts)
        val mine = s.b.social.reactionCounts(s.familyId, ContentTargetType.ALBUM, listOf(s.album.id))
        assertTrue("B 看自己按過", mine.getValue(s.album.id).reactedByMe)

        assertFalse("B 再按一次 → false（收回）", s.b.social.toggleReaction(s.familyId, ContentTargetType.ALBUM, s.album.id))
        assertTrue(
            "收回後計數歸零（不在結果裡）",
            s.a.social
                .reactionCounts(s.familyId, ContentTargetType.ALBUM, listOf(s.album.id))
                .isEmpty(),
        )
        assertTrue(s.b.social.toggleReaction(s.familyId, ContentTargetType.ALBUM, s.album.id))
        return commentId
    }

    /** 封鎖是單向的視角過濾（docs/API.md §3「封鎖過濾」）：封鎖者看不到對方的內容，被封鎖者不受影響。 */
    private suspend fun assertBlockVisibility(
        s: Scene,
        commentId: String,
    ) {
        s.b.social.blockUser(s.familyId, s.a.user.id)
        s.b.social.blockUser(s.familyId, s.a.user.id) // 冪等：重複封鎖不報錯
        assertTrue(
            "B 封鎖 A 後，B 的時間軸不得含 A 的項目（相簿、照片、日記全是 A 的）",
            s.b.feed
                .timeline(s.familyId)
                .isEmpty(),
        )
        assertNull("B 封鎖 A 後，A 建立的相簿讀不到", s.b.feed.albumDetail(s.album.id))
        assertEquals(
            "封鎖是單向的：被封鎖的 A 仍看得到 B 的留言",
            listOf(commentId),
            s.a.social
                .listComments(s.familyId, ContentTargetType.ALBUM, s.album.id)
                .comments
                .map { it.id },
        )
        s.b.social.unblockUser(s.familyId, s.a.user.id)
        s.b.social.unblockUser(s.familyId, s.a.user.id) // 冪等
        assertEquals(
            "解除封鎖後 B 的時間軸恢復",
            4,
            s.b.feed
                .timeline(s.familyId)
                .size,
        )

        s.a.social.blockUser(s.familyId, s.b.user.id)
        val hidden = s.a.social.listComments(s.familyId, ContentTargetType.ALBUM, s.album.id)
        assertTrue("A 封鎖 B 後讀不到 B 的留言", hidden.comments.isEmpty())
        assertEquals(0L, hidden.totalCount)
        assertEquals("A 封鎖 B 後時間軸的 comment_count 不含 B 的留言", 0L, s.a.commentCount(s))
        assertTrue(
            "A 封鎖 B 後愛心數不含 B 的愛心",
            s.a.social
                .reactionCounts(s.familyId, ContentTargetType.ALBUM, listOf(s.album.id))
                .isEmpty(),
        )
        s.a.social.unblockUser(s.familyId, s.b.user.id)
        assertEquals(
            1L,
            s.a.social
                .listComments(s.familyId, ContentTargetType.ALBUM, s.album.id)
                .totalCount,
        )
    }

    /** 作者軟刪（冪等）→ 列表與留言數不含；owner 移除後作者不能還原（`LS027`）；不存在的留言 `LS024`。 */
    private suspend fun assertCommentSoftDelete(
        s: Scene,
        commentId: String,
    ) {
        s.b.social.setCommentDeleted(commentId, deleted = true)
        s.b.social.setCommentDeleted(commentId, deleted = true) // 重送結果相同
        assertTrue(
            "軟刪後 list_comments 不含",
            s.a.social
                .listComments(s.familyId, ContentTargetType.ALBUM, s.album.id)
                .comments
                .isEmpty(),
        )
        assertEquals(0L, s.a.commentCount(s))
        s.b.social.setCommentDeleted(commentId, deleted = false)
        assertEquals(
            1L,
            s.a.social
                .listComments(s.familyId, ContentTargetType.ALBUM, s.album.id)
                .totalCount,
        )

        s.a.social.setCommentDeleted(commentId, deleted = true) // A 是 owner
        val removed =
            expectError<BackendError.RemovedByOwner> { s.b.social.setCommentDeleted(commentId, deleted = false) }
        assertEquals("LS027", removed.code)
        val missing =
            expectError<BackendError.CommentNotFound> {
                s.b.social.setCommentDeleted(UUID.randomUUID().toString(), deleted = true)
            }
        assertEquals("LS024", missing.code)
    }

    private class Actor(
        val user: TestUser,
    ) {
        val feed = FeedRepository(user.client)
        val social = SocialRepository(user.client)

        suspend fun commentCount(s: Scene): Long =
            feed.timeline(s.familyId).single { it.refId == s.album.id }.commentCount
    }

    @Suppress("LongParameterList") // 測試夾具：一個情境一組 id
    private class Scene(
        val a: Actor,
        val b: Actor,
        val familyId: String,
        val childId: String,
        val album: Album,
        val mediaId: String,
        val diary1: String,
        val diary2: String,
    )

    /** 上傳一張照片（原檔，不含縮圖）並掛進相簿；回傳 media id。 */
    private suspend fun uploadPhoto(
        user: TestUser,
        familyId: String,
        albumId: String,
    ): String {
        val mediaId = UUID.randomUUID().toString()
        val path = MediaPaths.original(familyId, mediaId, "jpg", Instant.now())
        user.media.uploadBytes(path, TINY_JPEG, "image/jpeg")
        user.media.insertMedia(NewMedia(mediaId, familyId, path, TINY_JPEG.size.toLong(), 64, 48, null))
        user.media.attachToAlbum(albumId, familyId, mediaId)
        return mediaId
    }

    private suspend fun createDiary(
        user: TestUser,
        familyId: String,
        body: String,
        entryDate: String,
        childIds: List<String>,
    ): String =
        rpcString(user, "create_diary_entry") {
            put("p_family_id", familyId)
            put("p_child_ids", JsonArray(childIds.map(::JsonPrimitive)))
            put("p_body", body)
            put("p_entry_date", entryDate)
        }

    /** 測試用的原始 RPC（回傳 uuid 字串）：建寶貝／日記不是本票的 repository 範圍，只在夾具裡直接呼叫。 */
    private suspend fun rpcString(
        user: TestUser,
        name: String,
        params: JsonObjectBuilder.() -> Unit,
    ): String =
        backend {
            user.client.postgrest
                .rpc(name, buildJsonObject(params))
                .decodeAs<String>()
        }

    @Serializable
    private data class DiaryMediaPayload(
        @SerialName("diary_id") val diaryId: String,
        @SerialName("media_id") val mediaId: String,
        @SerialName("family_id") val familyId: String,
        @SerialName("sort_order") val sortOrder: Int,
    )

    private companion object {
        const val DIARY_DAYS_AGO = 7L
    }
}
