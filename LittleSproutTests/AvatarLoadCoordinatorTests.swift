import Foundation
@testable import LittleSprout
import os
import UIKit
import XCTest

/// `AvatarLoadCoordinator`（LS-173，抽出自 `CreateChildView+Avatar.swift`／
/// `EditChildView.swift` 原本各自複製一份的 `loadPickedAvatar()` 世代守門邏輯，見該型別
/// 文件註解）：連選兩張時舊 task 完成不寫結果、`CancellationError` 一律靜默、非取消錯誤
/// 只在仍是最新世代時才呈現。收 `operation` 閉包而不是真實 `PhotosPickerItem`——理由同
/// `AvatarLoadCoordinator` 檔頭註解，這裡才能用可控的 gate 模擬「舊 task 後完成」交錯。
@MainActor
final class AvatarLoadCoordinatorTests: XCTestCase {
    private func makeLoaded(byte: UInt8) -> AvatarPickerLoader.Loaded {
        AvatarPickerLoader.Loaded(data: Data([byte]), previewImage: UIImage())
    }

    // MARK: - 單一載入，無交錯

    func test_load_success_returnsAppliedWithIsCurrentTrue() async {
        let coordinator = AvatarLoadCoordinator()

        let result = await coordinator.load { self.makeLoaded(byte: 0x42) }

        XCTAssertTrue(result.isCurrent)
        guard case .applied(let data, _) = result.outcome else {
            return XCTFail("應該是 .applied，實際是 \(result.outcome)")
        }
        XCTAssertEqual(data, Data([0x42]))
    }

    /// 被取消的載入一律靜默——不分類成 `.failed`，呼叫端不會顯示任何錯誤文案。
    func test_load_cancellationError_returnsDiscardedSilently() async {
        let coordinator = AvatarLoadCoordinator()

        let result = await coordinator.load { throw CancellationError() }

        XCTAssertTrue(result.isCurrent, "沒有其他載入插隊時，被取消的這次仍是最新世代（同 defer 收 loading 指示的既有語意）")
        guard case .discarded = result.outcome else {
            return XCTFail("CancellationError 應該一律靜默（.discarded），實際是 \(result.outcome)")
        }
    }

    /// 非取消錯誤、且仍是最新世代——這時才該顯示錯誤文案。
    func test_load_nonCancellationError_currentGeneration_returnsFailedWithMessage() async {
        struct DummyError: Error {}
        let coordinator = AvatarLoadCoordinator()

        let result = await coordinator.load { throw DummyError() }

        XCTAssertTrue(result.isCurrent)
        guard case .failed(let message) = result.outcome else {
            return XCTFail("非取消錯誤、仍是最新世代時應該是 .failed，實際是 \(result.outcome)")
        }
        XCTAssertEqual(message, AvatarLoadCoordinator.loadFailureMessage)
    }

    // MARK: - 連選兩張（舊 task 後完成）

    /// 票文核心情境：舊 task 卡在載入中，使用者已經選了第二張——新 task 的載入先完成（讀碼
    /// 推演的常態，見 LS-169 merge-review R3），舊 task 之後才完成，它的結果必須被丟棄，
    /// 不能覆蓋新 task 已經寫入的 `.applied`。
    func test_load_staleSuccessAfterNewerLoadStarted_isDiscardedNotApplied() async {
        let coordinator = AvatarLoadCoordinator()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let staleReachedLock = OSAllocatedUnfairLock(initialState: false)

        let staleTask = Task {
            await coordinator.load {
                staleReachedLock.withLock { $0 = true }
                var iterator = gate.makeAsyncIterator()
                _ = await iterator.next()
                return self.makeLoaded(byte: 0xAA) // "舊" 選取的資料
            }
        }
        var guardIterations = 0
        while !staleReachedLock.withLock({ $0 }) {
            guardIterations += 1
            guard guardIterations < 200 else {
                gateContinuation.finish()
                return XCTFail("等待舊 task 進入載入中逾時")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        // 第二次選取：立即完成，應該正常拿到 .applied（此時舊 task 仍卡在 gate 上）。
        let freshResult = await coordinator.load { self.makeLoaded(byte: 0xBB) }

        XCTAssertTrue(freshResult.isCurrent)
        guard case .applied(let freshData, _) = freshResult.outcome else {
            return XCTFail("新 task 應該正常寫入，實際是 \(freshResult.outcome)")
        }
        XCTAssertEqual(freshData, Data([0xBB]))

        gateContinuation.finish()
        let staleResult = await staleTask.value

        XCTAssertFalse(staleResult.isCurrent, "舊 task 完成時已經不是最新世代")
        guard case .discarded = staleResult.outcome else {
            return XCTFail("舊 task 遲到的成功結果必須被丟棄，不能覆蓋新結果，實際是 \(staleResult.outcome)")
        }
    }

    /// 同一情境但舊 task 遲到的是「非取消錯誤」——世代已落後時，錯誤也要被丟棄
    /// （`.discarded`），不能顯示一則屬於舊選取的錯誤訊息蓋掉新選取已經成功顯示的預覽圖。
    func test_load_staleFailureAfterNewerLoadStarted_isDiscardedNotFailed() async {
        struct DummyError: Error {}
        let coordinator = AvatarLoadCoordinator()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let staleReachedLock = OSAllocatedUnfairLock(initialState: false)

        let staleTask = Task {
            await coordinator.load {
                staleReachedLock.withLock { $0 = true }
                var iterator = gate.makeAsyncIterator()
                _ = await iterator.next()
                throw DummyError()
            }
        }
        var guardIterations = 0
        while !staleReachedLock.withLock({ $0 }) {
            guardIterations += 1
            guard guardIterations < 200 else {
                gateContinuation.finish()
                return XCTFail("等待舊 task 進入載入中逾時")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let freshResult = await coordinator.load { self.makeLoaded(byte: 0xCC) }
        XCTAssertTrue(freshResult.isCurrent)
        guard case .applied = freshResult.outcome else {
            return XCTFail("新 task 應該正常寫入，實際是 \(freshResult.outcome)")
        }

        gateContinuation.finish()
        let staleResult = await staleTask.value

        XCTAssertFalse(staleResult.isCurrent)
        guard case .discarded = staleResult.outcome else {
            return XCTFail("舊 task 遲到的失敗必須被丟棄，不能顯示屬於舊選取的錯誤文案，實際是 \(staleResult.outcome)")
        }
    }
}
