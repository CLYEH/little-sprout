#if DEBUG
import Foundation

/// 只給 SwiftUI `#Preview` 用的假 `DiaryAPIClient`——不打真網路（同 `PreviewChildAPIClient` 的
/// 角色，見該檔）。生產路徑一律用 `SupabaseDiaryAPIClient`。
final class PreviewDiaryAPIClient: DiaryAPIClient, @unchecked Sendable {
    func createDiaryEntry(familyID: UUID, body: String, entryDate: Date, childIDs: [UUID]) async throws -> UUID {
        UUID()
    }

    func updateDiaryEntry(diaryID: UUID, body: String, entryDate: Date, childIDs: [UUID]) async throws {}

    func attachMedia(diaryID: UUID, familyID: UUID, mediaIDs: [UUID]) async throws {}

    func setDiaryDeleted(diaryID: UUID, deleted: Bool) async throws {}
}

/// 只給 SwiftUI `#Preview` 用的假 `MediaUploadService`——不打真網路。
final class PreviewMediaUploadService: MediaUploadService, @unchecked Sendable {
    func uploadPhoto( // swiftlint:disable:this function_parameter_count
        familyID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize, takenAt: Date?, mediaID: UUID?
    ) async throws -> UUID {
        mediaID ?? UUID()
    }

    func uploadVideo( // swiftlint:disable:this function_parameter_count
        familyID: UUID, fileURL: URL, fileExtension: String, pixelSize: PixelSize, takenAt: Date?, mediaID: UUID?
    ) async throws -> UUID {
        mediaID ?? UUID()
    }

    func softDeleteMedia(mediaIDs: [UUID]) async throws {}
}
#endif
