import Foundation
@testable import LittleSprout
import XCTest

/// 相簿厚度分級（LS-165 票文驗收：「厚度分級與署名規則單元測試」；LS-142 Handoff Notes
/// `EBlnw`）——邊界值逐一釘住：0（無扇影）／1／9／10／49／50／任意大數。
final class AlbumThicknessTierTests: XCTestCase {
    func test_zeroPhotos_isEmptyTier_withNoFanGhost() {
        let tier = AlbumThicknessTier(photoCount: 0)
        XCTAssertEqual(tier, .empty)
        XCTAssertEqual(tier.fanGhostCount, 0)
    }

    func test_onePhoto_isThinTier_lowerBoundary() {
        XCTAssertEqual(AlbumThicknessTier(photoCount: 1), .thin)
        XCTAssertEqual(AlbumThicknessTier(photoCount: 1).fanGhostCount, 1)
    }

    func test_ninePhotos_isThinTier_upperBoundary() {
        XCTAssertEqual(AlbumThicknessTier(photoCount: 9), .thin)
    }

    func test_tenPhotos_isMediumTier_lowerBoundary() {
        XCTAssertEqual(AlbumThicknessTier(photoCount: 10), .medium)
        XCTAssertEqual(AlbumThicknessTier(photoCount: 10).fanGhostCount, 2)
    }

    func test_fortyNinePhotos_isMediumTier_upperBoundary() {
        XCTAssertEqual(AlbumThicknessTier(photoCount: 49), .medium)
    }

    func test_fiftyPhotos_isThickTier_lowerBoundary() {
        XCTAssertEqual(AlbumThicknessTier(photoCount: 50), .thick)
        XCTAssertEqual(AlbumThicknessTier(photoCount: 50).fanGhostCount, 3)
    }

    func test_veryLargeCount_isStillThickTier() {
        XCTAssertEqual(AlbumThicknessTier(photoCount: 5000), .thick)
    }

    /// `AlbumSummary.thicknessTier` 是 `photoCount` 的純函式——不需要另外驗證，這裡釘住
    /// 這條轉發本身沒有寫錯欄位名稱之類的低級錯誤。
    func test_albumSummary_thicknessTier_matchesPhotoCount() {
        let album = AlbumSummary(id: UUID(), title: "測試", photoCount: 12, cover: nil, childIds: [], createdAt: Date())
        XCTAssertEqual(album.thicknessTier, .medium)
    }
}
