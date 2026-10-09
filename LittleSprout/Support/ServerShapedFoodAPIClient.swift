#if DEBUG
import Foundation

/// LS-380 R3（QA `a27eafaf`）：照**真後端的回傳形狀**運作的假 `FoodAPIClient`——給 harness 驗「編輯後詳情頁換新」。
///
/// 跟 `PreviewFoodAPIClient` 的差別（正是 R2 測試綠、真後端紅的那條縫）：
/// - `upsert_child_food_record` 回傳的是**伺服器那一列**：`id`／`created_at`／`author_id` 沿用既有列、
///   `updated_at` 由「伺服器時鐘」給（固定起點、每次寫入 +1 秒，跟裝置時鐘無關，同 `private.touch_updated_at()`），
///   不是呼叫端拿本地值回填。
/// - `list_child_food_records` 讀回同一份伺服器狀態（整列）。
/// - 照片相關一律沒有（這條測試只看反應／備註）。
final class ServerShapedFoodAPIClient: FoodAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [ChildFoodRecord]
    private var serverClock: Date

    init(rows: [ChildFoodRecord], serverClock: Date) {
        self.rows = rows
        self.serverClock = serverClock
    }

    func listFoodCatalog() async throws -> [FoodCatalogItem] { PreviewFoodCatalog.items }

    func listChildFoodRecords(childID: UUID) async throws -> [ChildFoodRecord] {
        lock.withLock { rows.filter { $0.childID == childID } }
    }

    func upsertChildFoodRecord(_ input: FoodRecordUpsert) async throws -> ChildFoodRecord {
        let midnight = BirthdayFormat.date(fromWireString: BirthdayFormat.wireString(from: input.firstTriedOn))!
        return lock.withLock {
            serverClock = serverClock.addingTimeInterval(1)
            let existing = rows.first { $0.childID == input.childID && $0.foodID == input.foodID }
            let row = ChildFoodRecord(
                id: existing?.id ?? UUID(), familyID: existing?.familyID ?? UUID(), childID: input.childID,
                foodID: input.foodID, authorID: existing?.authorID, firstTriedOn: midnight, mediaID: input.mediaID,
                note: input.note, reaction: input.reaction?.rawValue,
                createdAt: existing?.createdAt ?? serverClock, updatedAt: serverClock
            )
            rows = rows.filter { $0.id != row.id } + [row]
            return row
        }
    }

    func deleteChildFoodRecord(id: UUID) async throws {
        lock.withLock { rows.removeAll { $0.id == id } }
    }

    func listFamilyPhotos(childID: UUID) async throws -> [FamilyPhoto] { [] }
    func fetchFamilyPhoto(id: UUID) async throws -> FamilyPhoto? { nil }
    func signedURLs(forStoragePaths paths: [String]) async throws -> [String: URL] { [:] }

    func uploadPhoto(childID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
        UUID()
    }

    func softDeleteMedia(mediaIDs: [UUID]) async throws {}
}
#endif
