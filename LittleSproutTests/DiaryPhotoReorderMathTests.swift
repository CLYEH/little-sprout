@testable import LittleSprout
import XCTest

final class DiaryPhotoReorderMathTests: XCTestCase {
    func test_noTranslation_staysAtSourceIndex() {
        XCTAssertEqual(DiaryPhotoReorderMath.targetIndex(sourceIndex: 1, translationWidth: 0, count: 5), 1)
    }

    func test_dragRightPastOneCell_movesForwardOneIndex() {
        let stride = DiaryPhotoReorderMath.cellStride
        XCTAssertEqual(DiaryPhotoReorderMath.targetIndex(sourceIndex: 0, translationWidth: stride, count: 5), 1)
    }

    func test_dragLeftPastOneCell_movesBackOneIndex() {
        let stride = DiaryPhotoReorderMath.cellStride
        XCTAssertEqual(DiaryPhotoReorderMath.targetIndex(sourceIndex: 2, translationWidth: -stride, count: 5), 1)
    }

    func test_dragPastEnd_clampsToLastIndex() {
        let stride = DiaryPhotoReorderMath.cellStride
        XCTAssertEqual(DiaryPhotoReorderMath.targetIndex(sourceIndex: 0, translationWidth: stride * 10, count: 3), 2)
    }

    func test_dragPastStart_clampsToZero() {
        let stride = DiaryPhotoReorderMath.cellStride
        XCTAssertEqual(DiaryPhotoReorderMath.targetIndex(sourceIndex: 2, translationWidth: -stride * 10, count: 3), 0)
    }

    func test_partialDrag_roundsToNearestCell() {
        let stride = DiaryPhotoReorderMath.cellStride
        // 超過半格才進位到下一格。
        XCTAssertEqual(DiaryPhotoReorderMath.targetIndex(sourceIndex: 0, translationWidth: stride * 0.4, count: 5), 0)
        XCTAssertEqual(DiaryPhotoReorderMath.targetIndex(sourceIndex: 0, translationWidth: stride * 0.6, count: 5), 1)
    }

    func test_emptyQueue_returnsZero() {
        XCTAssertEqual(DiaryPhotoReorderMath.targetIndex(sourceIndex: 0, translationWidth: 999, count: 0), 0)
    }
}
