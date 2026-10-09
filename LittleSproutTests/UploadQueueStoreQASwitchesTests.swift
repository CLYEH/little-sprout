import Foundation
@testable import LittleSprout
import XCTest

/// LS-427：QA 專用上傳停滯／失敗開關（`QAUploadSwitches.swift`）。三案各自守一個意圖：
/// 沒開開關＝佇列行為完全不變（QA 開關不能影響正式使用）；STALL＝每筆都真的先延遲（否則 QA 的
/// 「30 張變成分鐘級」失效，續傳驗不到）；FAIL_EVERY_N＝剛好第 k、2k… 筆走既有的可重試失敗路徑。
@MainActor
final class UploadQueueStoreQASwitchesTests: XCTestCase {
    private let familyID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func makeUpload(_ tag: String) -> PendingUpload {
        PendingUpload(
            id: UUID(), kind: .photo(data: Data(tag.utf8), fileExtension: "jpg"), thumbnail: nil,
            pixelSize: PixelSize(width: 4, height: 3)
        )
    }

    /// 並發 1：呼叫順序＝入列順序，第 n 次呼叫對應第 n 筆。
    private func makeStore(
        _ service: StubMediaUploadService, switches: QAUploadSwitches, sleep: @escaping (Duration) async throws -> Void
    ) -> UploadQueueStore {
        let store = UploadQueueStore(familyID: familyID, mediaUploadService: service, maxConcurrentUploads: 1)
        store.qaGate = QAUploadGate(switches: switches, sleep: sleep)
        return store
    }

    private func waitUntil(_ store: UploadQueueStore, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else { return XCTFail("等待佇列結算逾時") }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func test_noSwitches_behaviourUnchanged_andEnvNeedsQAAPIURL() async {
        // 沒有 `LS_QA_API_URL`（非 QA 環境）就算帶了開關也一律視為未設。
        XCTAssertEqual(
            QAUploadSwitches.from(environment: ["LS_QA_UPLOAD_STALL_MS": "500", "LS_QA_UPLOAD_FAIL_EVERY_N": "2"]),
            .none, "不在 QA 環境（沒有 LS_QA_API_URL）時，開關不得生效"
        )
        XCTAssertEqual(
            QAUploadSwitches.from(environment: [
                "LS_QA_API_URL": "http://127.0.0.1:54321", "LS_QA_UPLOAD_STALL_MS": "500",
                "LS_QA_UPLOAD_FAIL_EVERY_N": "2"
            ]),
            QAUploadSwitches(stallMilliseconds: 500, failEveryN: 2)
        )

        let service = StubMediaUploadService()
        var sleeps: [Duration] = []
        let store = makeStore(service, switches: .none) { sleeps.append($0) }
        store.enqueue((0..<3).map { makeUpload("\($0)") })
        await waitUntil(store) { store.uploadingCount == 0 && store.waitingCount == 0 }

        XCTAssertTrue(sleeps.isEmpty, "未設 STALL 不得延遲")
        XCTAssertEqual(service.uploadPhotoCalls.count, 3)
        XCTAssertEqual(store.sections.first { $0.kind == .completed }?.rows.count, 3, "未設開關：全部照常完成")
    }

    func test_stall_delaysEveryUploadBeforeNetworkCall() async {
        let service = StubMediaUploadService()
        var sleeps: [Duration] = []
        let store = makeStore(service, switches: QAUploadSwitches(stallMilliseconds: 4000, failEveryN: nil)) {
            sleeps.append($0)
        }
        store.enqueue((0..<3).map { makeUpload("\($0)") })
        await waitUntil(store) { store.uploadingCount == 0 && store.waitingCount == 0 }

        XCTAssertEqual(sleeps, Array(repeating: .milliseconds(4000), count: 3), "每一筆上傳前都要先停滯 STALL_MS")
        XCTAssertEqual(service.uploadPhotoCalls.count, 3, "停滯結束後仍照常上傳")
    }

    func test_failEveryN_failsEveryKthCallWithRetryableError() async {
        let service = StubMediaUploadService()
        let store = makeStore(service, switches: QAUploadSwitches(stallMilliseconds: nil, failEveryN: 2)) { _ in }
        let uploads = (0..<4).map { makeUpload("\($0)") }
        store.enqueue(uploads)
        await waitUntil(store) { store.uploadingCount == 0 && store.waitingCount == 0 }

        let states = uploads.map { upload in store.rows.first { $0.id == upload.id }?.state }
        XCTAssertEqual(
            states, [.completed, .failed(.network), .completed, .failed(.network)],
            "FAIL_EVERY_N=2：第 2、4 筆回可重試錯誤（.network，isRetryable），其餘成功"
        )
        XCTAssertTrue(UploadFailureReason.network.isRetryable)
        XCTAssertEqual(service.uploadPhotoCalls.count, 2, "被 QA 開關擋掉的筆不會真的打到上傳服務")
    }
}
