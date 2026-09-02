import Foundation
@testable import LittleSprout
import XCTest

/// LS-130：`thumb_path` 選路（thumb 優先／NULL 退回原圖）＋瀑布流縮圖尺寸／全尺寸簽名策略。
/// 跟 `TimelineContentAssemblerTests` 是同一個測試對象，拆成獨立檔案純粹是為了 SwiftLint
/// `type_body_length`（250 行）——共用該檔的 `pointer(...)`／`mediaRow(...)` 工廠函式（同
/// `OTPVerificationModelRateLimitTests.swift` 的拆檔理由與寫法）。
extension TimelineContentAssemblerTests {
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
}
