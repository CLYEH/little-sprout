package com.clyeh.sproutday.supabase

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.time.Instant
import java.util.Base64
import java.util.UUID

/**
 * 契約測試（LS-490）：對本機 Supabase 容器驗證 docs/API.md §3「上傳流程順序」與 §6 的 Storage 路徑規約——
 * 建相簿 → 上傳原檔＋縮圖 → 寫 `media` 列 → 掛進相簿 → 列照片 → 軟刪；另有 `LS002` 額度案。
 * 容器沒設定／非本機時整批略過（見 [ContractEnv]）。
 */
class MediaContractTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var config: SupabaseConfig

    @Before
    fun requireLocalContainer() {
        config = ContractEnv.requireLocalConfig()
    }

    @Test
    fun createAlbumUploadListAndSoftDelete() =
        runBlocking<Unit> {
            val owner = TestUsers.signIn(config, "media")
            val family = owner.family.createFamily("媒體契約測試家庭")
            val album = owner.media.createAlbum(family.id, "契約測試相簿")
            assertEquals(family.id, album.familyId)
            assertEquals(listOf(album.id), owner.media.listAlbums(family.id).map { it.id })

            val mediaId = UUID.randomUUID().toString()
            val now = Instant.now()
            val original = tmp.newFile("original.jpg").also { it.writeBytes(TINY_JPEG) }
            val path = MediaPaths.original(family.id, mediaId, "jpg", now)
            val thumbPath = MediaPaths.thumbnail(family.id, mediaId, now)
            val media =
                NewMedia(mediaId, family.id, path, original.length(), 64, 48, ThumbnailInfo(thumbPath, 32, 24))

            // docs/API.md §3 的順序：①②先 PUT 物件（可並行），③ 才 INSERT media 列。
            owner.media.uploadFile(path, original, "image/jpeg")
            owner.media.uploadBytes(thumbPath, TINY_JPEG, MediaLimits.THUMBNAIL_CONTENT_TYPE)
            owner.media.insertMedia(media)
            owner.media.attachToAlbum(album.id, family.id, mediaId)

            // 冪等：整段重送一次（上一次回應遺失的情境）——物件 upsert 覆寫、media 主鍵衝突當成功、相簿連結不重複。
            owner.media.uploadFile(path, original, "image/jpeg")
            owner.media.insertMedia(media)
            owner.media.attachToAlbum(album.id, family.id, mediaId)

            val listed = owner.media.listAlbumMedia(album.id)
            assertEquals("重送後相簿裡仍只有一張", listOf(mediaId), listed.map { it.id })
            val row = listed.single()
            assertEquals(path, row.storagePath)
            assertEquals("photo", row.type)
            assertEquals(original.length(), row.byteSize)
            assertEquals(thumbPath, row.thumbPath)
            assertEquals(32, row.thumbWidth)
            assertEquals(24, row.thumbHeight)

            owner.media.softDeleteMedia(listOf(mediaId))
            assertTrue(
                "軟刪後不得再列出（上傳者本人讀得到已軟刪列，過濾要在 client 端）",
                owner.media.listAlbumMedia(album.id).isEmpty(),
            )

            owner.media.setAlbumDeleted(album.id, deleted = true)
            assertTrue("軟刪的相簿不得再列出", owner.media.listAlbums(family.id).none { it.id == album.id })
        }

    @Test
    fun quotaExceededIsLs002() =
        runBlocking<Unit> {
            val owner = TestUsers.signIn(config, "quota")
            val family = owner.family.createFamily("額度契約測試家庭")
            val mediaId = UUID.randomUUID().toString()
            val path = MediaPaths.original(family.id, mediaId, "jpg", Instant.now())
            // 額度看 media.byte_size 加總、不看 Storage 實際大小（docs/API.md §3）；預設額度 5 GiB，超 1 byte 就夠。
            val oversized = NewMedia(mediaId, family.id, path, DEFAULT_QUOTA_BYTES + 1, 64, 48, null)

            val error = expectError<BackendError.StorageQuotaExceeded> { owner.media.insertMedia(oversized) }
            assertEquals("LS002", error.code)
            assertNotNull(error.message)
            assertTrue("LS002 不可重試", !error.isTransient)
        }

    private companion object {
        const val DEFAULT_QUOTA_BYTES = 5L * 1024 * 1024 * 1024

        /** 合法的 1×1 JPEG（Storage 只驗 Content-Type 與大小；`media.width／height` 由呼叫端宣告，DB 不核對）。 */
        val TINY_JPEG: ByteArray =
            Base64.getDecoder().decode(
                "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////" +
                    "////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=",
            )
    }
}
