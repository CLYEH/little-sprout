import Foundation
import UIKit

/// LS-304：`#Preview`／`TapTargetGateHarness`／UITest／單元測試用的灌狀態工具——從
/// `UploadQueueStore.swift` 拆出，理由同 `UploadQueueStore+VideoExportSlot.swift`／
/// `UploadQueueStore+ImportCancellation.swift` 檔頭：主檔逼近 SwiftLint `file_length` 上限。
/// 整支 `#if DEBUG` 圍住（同 `TapTargetGateHarness.swift` 等既有慣例）——這些是測試／預覽
/// 專用的後門，不應該編進 Release build。
#if DEBUG
extension UploadQueueStore {
    /// 只給 `#Preview`／`TapTargetGateHarness`／UITest 用——直接灌狀態，不經過真正的上傳
    /// 流程（同 `TimelineStore.seedForPreview` 的角色與圍欄理由）。
    struct PreviewSeed {
        let upload: PendingUpload
        let enqueuedAt: Date
        let state: UploadItemState

        init(_ upload: PendingUpload, enqueuedAt: Date, state: UploadItemState) {
            self.upload = upload
            self.enqueuedAt = enqueuedAt
            self.state = state
        }
    }

    func seedForPreview(_ seeds: [PreviewSeed]) {
        for seed in seeds {
            entries[seed.upload.id] = Entry(
                thumbnail: seed.upload.thumbnail, pixelSize: seed.upload.pixelSize, payload: seed.upload.kind,
                enqueuedAt: seed.enqueuedAt, state: seed.state, takenAt: seed.upload.takenAt
            )
            order.append(seed.upload.id)
        }
    }

    /// 測試用途：這筆是否還留著上傳用的原始 payload——完成或不可重試失敗後應該是 `nil`
    /// （merge-review R2 F3）。
    func debugPayload(_ id: UUID) -> PendingUpload.Kind? {
        entries[id]?.payload
    }

    /// 測試用途（merge-review R1 m6）：驗證 `taken_at` 有沒有正確套到這一筆——不論 kind 是
    /// 照片還是影片，不需要真的跑完整條上傳／壓縮管線才能斷言。
    func debugTakenAt(_ id: UUID) -> Date? {
        entries[id]?.takenAt
    }

    /// 測試用途：強制清空某筆的 payload，人為打破「`.waiting` 一定有 payload」這個不變量
    /// （merge-review R3 i1）——正常流程走不到這個狀態，只能用這個鉤子模擬，驗證
    /// `start(_:)` 撞到這個不變量被打破時會翻成失敗，不是永遠卡住。
    func debugForcePayloadNil(_ id: UUID) {
        entries[id]?.payload = nil
    }
    // `debugAcquireVideoExportSlot()`／`debugReleaseVideoExportSlot()`／
    // `debugVideoExportWaiterCount` 見 `UploadQueueStore+VideoExportSlot.swift`。
}
#endif
