import Foundation
@testable import LittleSprout
import XCTest

/// LS-130：`thumb_path` 選路（thumb 優先／NULL 退回原圖）＋瀑布流縮圖尺寸／全尺寸簽名策略。
/// 跟 `TimelineContentAssemblerTests` 是同一個測試對象，拆成獨立檔案純粹是為了 SwiftLint
/// `type_body_length`（250 行）——共用該檔的 `pointer(...)`／`mediaRow(...)` 工廠函式（同
/// `OTPVerificationModelRateLimitTests.swift` 的拆檔理由與寫法）。
extension TimelineContentAssemblerTests {
    // MARK: - assemble .diary kind（日記卡前 3 張）：thumb_path 選路
    //
    // R2-m2（merge-review `b7ecfbf4`）：`fetchDiaryContents`／`fetchAlbumContents` 跟另外
    // 兩支共用同一支 `signedURLs`／`displayPath` 輔助函式，選路構造上是對的；但只靠
    // `test_assemble_albumKind_includesCover`（用無縮圖 media row）沒有縮圖選路測試涵蓋，
    // 若有人手動改壞這兩支各自的 `signed[displayPath(row)]` 查表（例如 rebase 衝突解錯），
    // 既有測試不會紅——這裡各補一條，沿用 `signedURLsCalls` 斷言。

    func test_assemble_diaryKind_thumbPathPresent_signsThumbPathForPreviewPhotos() async throws {
        let stub = StubTimelineAPIClient()
        let diaryID = UUID()
        let mediaID = UUID()
        stub.setFetchDiariesHandler { ids in
            XCTAssertEqual(ids, [diaryID])
            return [DiaryRow(id: diaryID, body: "有縮圖的日記", entryDate: Date(), createdAt: Date())]
        }
        stub.setFetchDiaryMediaLinksHandler { diaryIds in
            XCTAssertEqual(diaryIds, [diaryID])
            return [DiaryMediaLinkRow(diaryId: diaryID, mediaId: mediaID, sortOrder: 0)]
        }
        stub.setFetchMediaHandler { ids in
            ids.map { id in
                mediaRow(id: id, path: "f/\(id).jpg", thumbPath: "f/\(id)_thumb.jpg", thumbWidth: 200, thumbHeight: 150)
            }
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let entries = try await TimelineContentAssembler.assemble(
            pointers: [pointer(kind: .diary, refId: diaryID)], apiClient: stub
        )

        guard case .diary(let content) = entries[0].content else {
            return XCTFail("預期組出 .diary content")
        }
        XCTAssertEqual(
            stub.signedURLsCalls, [["f/\(mediaID)_thumb.jpg"]], "日記卡前 3 張有縮圖時只該簽縮圖路徑"
        )
        XCTAssertEqual(
            content.previewPhotos.first?.signedURL, URL(string: "https://example.com/f/\(mediaID)_thumb.jpg")
        )
        XCTAssertEqual(content.previewPhotos.first?.isThumbnail, true)
    }

    func test_assemble_diaryKind_thumbPathNil_fallsBackToStoragePathForPreviewPhotos() async throws {
        let stub = StubTimelineAPIClient()
        let diaryID = UUID()
        let mediaID = UUID()
        stub.setFetchDiariesHandler { _ in
            [DiaryRow(id: diaryID, body: "無縮圖的日記", entryDate: Date(), createdAt: Date())]
        }
        stub.setFetchDiaryMediaLinksHandler { _ in
            [DiaryMediaLinkRow(diaryId: diaryID, mediaId: mediaID, sortOrder: 0)]
        }
        stub.setFetchMediaHandler { ids in
            ids.map { mediaRow(id: $0, path: "f/\($0).jpg") }
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let entries = try await TimelineContentAssembler.assemble(
            pointers: [pointer(kind: .diary, refId: diaryID)], apiClient: stub
        )

        guard case .diary(let content) = entries[0].content else {
            return XCTFail("預期組出 .diary content")
        }
        XCTAssertEqual(
            stub.signedURLsCalls, [["f/\(mediaID).jpg"]], "無縮圖時日記卡前 3 張退回簽原圖路徑"
        )
        XCTAssertEqual(content.previewPhotos.first?.isThumbnail, false)
    }

    // MARK: - assemble .album kind（相簿封面）：thumb_path 選路

    func test_assemble_albumKind_thumbPathPresent_signsThumbPathForCover() async throws {
        let stub = StubTimelineAPIClient()
        let albumID = UUID()
        let coverID = UUID()
        stub.setFetchAlbumsHandler { ids in
            XCTAssertEqual(ids, [albumID])
            return [AlbumRow(id: albumID, title: "有縮圖封面的相簿", coverMediaId: coverID)]
        }
        stub.setFetchMediaHandler { ids in
            XCTAssertEqual(ids, [coverID])
            return [
                mediaRow(
                    id: coverID, path: "f/cover.jpg", thumbPath: "f/cover_thumb.jpg", thumbWidth: 200, thumbHeight: 150
                )
            ]
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let entries = try await TimelineContentAssembler.assemble(
            pointers: [pointer(kind: .album, refId: albumID)], apiClient: stub
        )

        guard case .album(let content) = entries[0].content else {
            return XCTFail("預期組出 .album content")
        }
        XCTAssertEqual(stub.signedURLsCalls, [["f/cover_thumb.jpg"]], "相簿封面有縮圖時只該簽縮圖路徑")
        XCTAssertEqual(content.cover?.signedURL, URL(string: "https://example.com/f/cover_thumb.jpg"))
        XCTAssertEqual(content.cover?.isThumbnail, true)
    }

    func test_assemble_albumKind_thumbPathNil_fallsBackToStoragePathForCover() async throws {
        let stub = StubTimelineAPIClient()
        let albumID = UUID()
        let coverID = UUID()
        stub.setFetchAlbumsHandler { _ in
            [AlbumRow(id: albumID, title: "無縮圖封面的相簿", coverMediaId: coverID)]
        }
        stub.setFetchMediaHandler { ids in
            ids.map { mediaRow(id: $0, path: "f/cover.jpg") }
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let entries = try await TimelineContentAssembler.assemble(
            pointers: [pointer(kind: .album, refId: albumID)], apiClient: stub
        )

        guard case .album(let content) = entries[0].content else {
            return XCTFail("預期組出 .album content")
        }
        XCTAssertEqual(stub.signedURLsCalls, [["f/cover.jpg"]], "無縮圖時相簿封面退回簽原圖路徑")
        XCTAssertEqual(content.cover?.isThumbnail, false)
    }

    // MARK: - assemble .media kind：thumb_path 選路

    func test_assemble_mediaKind_thumbPathPresent_signsThumbPathNotStoragePath() async throws {
        let stub = StubTimelineAPIClient()
        let mediaID = UUID()
        stub.setFetchMediaHandler { ids in
            XCTAssertEqual(ids, [mediaID])
            return [
                mediaRow(
                    id: mediaID, path: "f/solo.jpg", thumbPath: "f/solo_thumb.jpg", thumbWidth: 200, thumbHeight: 150
                )
            ]
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let entries = try await TimelineContentAssembler.assemble(
            pointers: [pointer(kind: .media, refId: mediaID)], apiClient: stub
        )

        guard case .media(let content) = entries[0].content else {
            return XCTFail("預期組出 .media content")
        }
        XCTAssertEqual(stub.signedURLsCalls, [["f/solo_thumb.jpg"]], "有縮圖時只該簽縮圖路徑，不該簽原圖")
        XCTAssertEqual(content.signedURL, URL(string: "https://example.com/f/solo_thumb.jpg"))
    }

    func test_assemble_mediaKind_thumbPathNil_fallsBackToStoragePath() async throws {
        let stub = StubTimelineAPIClient()
        let mediaID = UUID()
        stub.setFetchMediaHandler { _ in
            [mediaRow(id: mediaID, path: "f/solo.jpg")]
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let entries = try await TimelineContentAssembler.assemble(
            pointers: [pointer(kind: .media, refId: mediaID)], apiClient: stub
        )

        guard case .media(let content) = entries[0].content else {
            return XCTFail("預期組出 .media content")
        }
        XCTAssertEqual(
            stub.signedURLsCalls, [["f/solo.jpg"]], "無縮圖的列（既有資料，v0.7.1 行為）退回簽原圖路徑"
        )
        XCTAssertEqual(content.signedURL, URL(string: "https://example.com/f/solo.jpg"))
    }

    // MARK: - fetchDiaryPhotos：格內用縮圖、比例用縮圖尺寸、全尺寸不在這裡簽

    func test_fetchDiaryPhotos_thumbPresent_signsThumbPath_andAspectRatioUsesThumbDimensions() async throws {
        let stub = StubTimelineAPIClient()
        let diaryID = UUID()
        let mediaID = UUID()
        stub.setFetchDiaryMediaLinksHandler { diaryIds in
            XCTAssertEqual(diaryIds, [diaryID])
            return [DiaryMediaLinkRow(diaryId: diaryID, mediaId: mediaID, sortOrder: 0)]
        }
        stub.setFetchMediaHandler { ids in
            // 原圖 800×600（比例 4:3 ≈ 1.33）、縮圖 200×100（比例 2:1）——刻意不同，斷言
            // 瀑布流比例用的是縮圖尺寸，不是原圖尺寸。
            ids.map { id in
                mediaRow(id: id, path: "f/\(id).jpg", thumbPath: "f/\(id)_thumb.jpg", thumbWidth: 200, thumbHeight: 100)
            }
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let photos = try await TimelineContentAssembler.fetchDiaryPhotos(diaryID: diaryID, apiClient: stub)

        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(
            stub.signedURLsCalls, [["f/\(mediaID)_thumb.jpg"]],
            "格內顯示只該簽縮圖路徑；全尺寸原檔不在 fetchDiaryPhotos 簽，見 TimelineStore.signFullSizeURL"
        )
        XCTAssertEqual(photos[0].aspectRatio, 2.0, "比例該用縮圖尺寸（200/100=2），不是原圖（800/600≈1.33）")
        XCTAssertEqual(photos[0].storagePath, "f/\(mediaID).jpg", "原圖路徑仍要留著，供放大／播放影片時現簽全尺寸")
    }

    func test_fetchDiaryPhotos_thumbNil_signsStoragePath_andAspectRatioFallsBackToOriginalDimensions() async throws {
        let stub = StubTimelineAPIClient()
        let diaryID = UUID()
        let mediaID = UUID()
        stub.setFetchDiaryMediaLinksHandler { _ in
            [DiaryMediaLinkRow(diaryId: diaryID, mediaId: mediaID, sortOrder: 0)]
        }
        stub.setFetchMediaHandler { ids in
            // width 800／height 600，thumb 三欄皆 nil——既有資料／縮圖產生失敗的過渡列。
            ids.map { mediaRow(id: $0, path: "f/\($0).jpg") }
        }
        stub.setSignedURLsHandler { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, URL(string: "https://example.com/\($0)")!) })
        }

        let photos = try await TimelineContentAssembler.fetchDiaryPhotos(diaryID: diaryID, apiClient: stub)

        XCTAssertEqual(
            stub.signedURLsCalls, [["f/\(mediaID).jpg"]], "無縮圖時退回簽原圖路徑——與 v0.7.1 行為相同"
        )
        XCTAssertEqual(photos[0].aspectRatio, 800.0 / 600.0, accuracy: 0.0001)
    }

    // MARK: - R2-M1：MediaContent.needsVideoDurationLookup——縮圖影片不該再讀時長
    //
    // 直接建構 `MediaContent`，不透過 assembler／stub——這條規則本身是純函式，不需要批次
    // 組裝的機器就能釘住（PhotoCardView／MasonryPhotoWallView 的 `.task` guard 只是照抄
    // 這個屬性，見兩檔 `.task(id:)` 註解）。mutation：把 `&&` 換成 `||`，或拿掉
    // `!isThumbnail`，這三條測試會有至少一條變紅。

    func test_needsVideoDurationLookup_videoWithoutThumbnail_isTrue() {
        let content = MediaContent(
            id: UUID(), type: .video, width: 884, height: 1920, thumbWidth: nil, thumbHeight: nil,
            storagePath: "f/v.mov", isThumbnail: false, signedURL: URL(string: "https://example.com/f/v.mov")
        )
        XCTAssertTrue(content.needsVideoDurationLookup, "無縮圖的影片，signedURL 就是原始影片檔，該讀時長")
    }

    func test_needsVideoDurationLookup_videoWithThumbnail_isFalse() {
        let content = MediaContent(
            id: UUID(), type: .video, width: 884, height: 1920, thumbWidth: 200, thumbHeight: 434,
            storagePath: "f/v.mov", isThumbnail: true, signedURL: URL(string: "https://example.com/f/v_thumb.jpg")
        )
        XCTAssertFalse(
            content.needsVideoDurationLookup, "有縮圖的影片，signedURL 是縮圖 JPEG，讀時長必定失敗，不該嘗試"
        )
    }

    func test_needsVideoDurationLookup_photo_isFalseRegardlessOfThumbnail() {
        let withThumb = MediaContent(
            id: UUID(), type: .photo, width: 800, height: 600, thumbWidth: 200, thumbHeight: 150,
            storagePath: "f/p.jpg", isThumbnail: true, signedURL: URL(string: "https://example.com/f/p_thumb.jpg")
        )
        let withoutThumb = MediaContent(
            id: UUID(), type: .photo, width: 800, height: 600, thumbWidth: nil, thumbHeight: nil,
            storagePath: "f/p.jpg", isThumbnail: false, signedURL: URL(string: "https://example.com/f/p.jpg")
        )
        XCTAssertFalse(withThumb.needsVideoDurationLookup, "照片不該讀影片時長，不管有沒有縮圖")
        XCTAssertFalse(withoutThumb.needsVideoDurationLookup)
    }
}
