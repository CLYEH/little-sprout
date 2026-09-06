import Foundation
@testable import LittleSprout
import SwiftUI
import UIKit
import XCTest

/// `DiaryEditorView` 的 `.onDisappear` 清理接線（LS-212 R2，merge-review R1 M1）：畫面被
/// push 進來（`.navigationDestination(isPresented:)`），`.navigationBarBackButtonHidden(true)`
/// 只隱藏了系統返回鈕，互動式返回手勢（邊緣滑走）依然有效，原本只掛在 `cancelButton` 的清理完
/// 全不會經過。這裡不用 XCUITest（跨行程，無法觀察內部的 `softDeleteMedia` 呼叫）——改用
/// `UIHostingController` 直接 host 真正的生產 `DiaryEditorView`，用「把 view controller 從
/// window 上移除」模擬「畫面消失」（涵蓋取消鈕、成功發佈後 dismiss、互動式滑走三種觸發方式共同
/// 的終點：view 從畫面上消失），跟 `Support/StubDiaryAPIClient`／`StubMediaUploadService` 同一個
/// 行程內，可以直接斷言呼叫記錄。`DiaryEditorView.init(store:childrenStore:)`（`#if DEBUG`）是
/// 這裡需要的測試專用注入點，讓測試能在 view 出現之前先跑一次 `store.publish()` 佈置「已上傳但
/// 未 attach」的狀態。
///
/// **實測（LS-212 R2）**：這個測試 bundle 沒有 host app（`bundle.unit-test`，未設
/// `TEST_HOST`）——`.onAppear`／`.onDisappear` 本身仍會確實觸發（用 `print` 直接驗證過），但
/// `.onDisappear` 內 `Task { await store.discardDraft() }` 這個 `Task` 的後續執行**不**能靠
/// `RunLoop.main.run(until:)` 等 Foundation run loop 機制推進——這個 bundle 沒有真正的
/// `UIApplicationMain`，GCD main queue 跟 CFRunLoop 的整合前提不成立，不論單次跑多久或輪詢幾次
/// 都觀察不到。改成在**測試函式自己**（`@MainActor` `async` test method）用 `Task.sleep`
/// 讓出 MainActor——這才是 Swift Concurrency 認得的「排隊等下一個工作」機制，讓
/// `.onDisappear` 排進去的那個 `Task` 有機會真的被執行到。
@MainActor
final class DiaryEditorViewLifecycleTests: XCTestCase {
    /// 用 `Task.sleep` 反覆讓出 MainActor，讓 `.onDisappear` 排進佇列的 `Task` 有機會被執行到
    /// ——不是等「畫面渲染」（那個用得到 RunLoop／UIKit 機制），而是等 Swift Concurrency 自己
    /// 排程的工作，兩者機制不同，見本檔文件註解。
    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 讓 view 出現、跑一小段 run loop（模擬畫面渲染穩定——這段用 UIKit／RunLoop 沒問題，是給
    /// view controller 走完 appearance transition 用的，跟上面「等 Task 執行」是不同機制），再
    /// 移除 `window.rootViewController` 模擬「畫面消失」——涵蓋取消鈕觸發的 `dismiss()`、成功
    /// 發佈後的 `dismiss()`、與互動式滑走三種觸發方式共同的終點（view 從畫面上被移除）。
    private func presentThenDismiss(_ view: DiaryEditorView) {
        let hosting = UIHostingController(rootView: view)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.rootViewController = nil
    }

    /// mutation 鑑別力關鍵：拿掉 `DiaryEditorView.body` 的 `.onDisappear` modifier，這支測試應該
    /// 轉紅——「畫面消失」不再觸發 `discardDraft()`，`softDeleteMediaCalls` 逾時後仍是空陣列。
    func test_onDisappear_afterFailedPublish_softDeletesOrphanMedia() async throws {
        let mediaService = StubMediaUploadService()
        let uploadedMediaID = UUID()
        mediaService.setUploadPhotoHandler { _, _, _, _ in uploadedMediaID }
        let diaryClient = StubDiaryAPIClient()
        diaryClient.setCreateHandler { _, _, _, _ in UUID() }
        diaryClient.setAttachMediaHandler { _, _, _ in throw AppError.network(message: "connection dropped") }
        let store = DiaryComposerStore(familyID: UUID(), diaryAPIClient: diaryClient, mediaUploadService: mediaService)
        store.body = "內容"
        store.addPhoto(
            data: Data("a".utf8), fileExtension: "jpg", pixelSize: PixelSize(width: 100, height: 100), previewImage: nil
        )
        let publishResult = await store.publish()
        XCTAssertFalse(publishResult, "測試前置：attachMedia 恆失敗，publish() 應該失敗但照片已經上傳成功")

        presentThenDismiss(DiaryEditorView(store: store, childrenStore: .preview()))
        await waitUntil { !mediaService.softDeleteMediaCalls.isEmpty }

        XCTAssertEqual(
            mediaService.softDeleteMediaCalls, [.init(mediaIDs: [uploadedMediaID])],
            "畫面消失（取消鈕、成功發佈後 dismiss、或互動式滑走）都該經過 .onDisappear 觸發 discardDraft() 軟刪孤兒 media"
        )
    }

    /// 對稱情境：發佈成功後畫面消失不該把已經合法 attach 的 media 軟刪掉——`discardDraft()`
    /// 自己的 `guard publishState != .success` 要在 `.onDisappear` 這條新路徑上依然生效。
    func test_onDisappear_afterSuccessfulPublish_doesNotSoftDeleteAttachedMedia() async throws {
        let mediaService = StubMediaUploadService()
        let diaryClient = StubDiaryAPIClient()
        let store = DiaryComposerStore(familyID: UUID(), diaryAPIClient: diaryClient, mediaUploadService: mediaService)
        store.body = "內容"
        store.addPhoto(
            data: Data("a".utf8), fileExtension: "jpg", pixelSize: PixelSize(width: 100, height: 100), previewImage: nil
        )
        let publishResult = await store.publish()
        XCTAssertTrue(publishResult, "測試前置：預設 stub 不會失敗，publish() 應該成功")

        presentThenDismiss(DiaryEditorView(store: store, childrenStore: .preview()))
        // 沒有「等到就提早結束」的正向條件可等（我們要驗證的正是「不會發生」）——固定跑滿
        // `waitUntil` 的逾時視窗，確保給了跟上面那支測試同樣充裕的時間讓（不該發生的）呼叫有
        // 機會出現，這裡故意用一個恆假的條件把整個逾時視窗耗滿。
        await waitUntil(timeout: 1.0) { false }

        XCTAssertTrue(
            mediaService.softDeleteMediaCalls.isEmpty, "發佈成功後畫面消失不該把已經合法 attach 的 media 軟刪掉"
        )
    }
}
