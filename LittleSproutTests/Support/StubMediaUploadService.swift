import Foundation
@testable import LittleSprout
import os

/// `DiaryComposerStore` 測試用假 `MediaUploadService`——不打真網路、不碰真的檔案系統。
final class StubMediaUploadService: MediaUploadService, @unchecked Sendable {
    typealias UploadPhotoHandler = @Sendable (UUID, Data, String, PixelSize) async throws -> UUID
    typealias UploadPhotoMediaIDHandler = @Sendable (UUID?, Data) async throws -> UUID
    typealias UploadVideoHandler = @Sendable (UUID, URL, String, PixelSize) async throws -> UUID
    typealias SoftDeleteMediaHandler = @Sendable ([UUID]) async throws -> Void

    struct UploadPhotoCall: Equatable {
        let familyID: UUID
        let fileExtension: String
        let pixelSize: PixelSize
        /// LS-304：批次匯入把 EXIF 分組日期／使用者覆寫傳進來的 `taken_at`——既有呼叫端
        /// （日記編輯器）不帶這個參數，走 `MediaUploadService` 4-arg 便利多載，記錄下來一律
        /// `nil`，見該協定文件註解。
        let takenAt: Date?
        /// LS-397 R1 M3：呼叫端指定的 `media.id`（佇列重送沿用同一個；其餘呼叫端為 `nil`）。
        let mediaID: UUID?
    }

    struct UploadVideoCall: Equatable {
        let familyID: UUID
        let fileURL: URL
        let fileExtension: String
        let pixelSize: PixelSize
        let takenAt: Date?
        let mediaID: UUID?
    }

    /// LS-212：`DiaryComposerStore.cleanupRemovedDrafts` 軟刪已上傳孤兒 media 的呼叫記錄。
    struct SoftDeleteMediaCall: Equatable {
        let mediaIDs: [UUID]
    }

    private struct Box {
        var uploadPhotoHandler: UploadPhotoHandler = { _, _, _, _ in UUID() }
        /// LS-397 R1 M3：想在假伺服器裡依 `mediaID` 模擬主鍵去重的測試用——設了就優先於 `uploadPhotoHandler`。
        var uploadPhotoMediaIDHandler: UploadPhotoMediaIDHandler?
        var uploadVideoHandler: UploadVideoHandler = { _, _, _, _ in UUID() }
        var softDeleteMediaHandler: SoftDeleteMediaHandler = { _ in }
        var uploadPhotoCalls: [UploadPhotoCall] = []
        var uploadVideoCalls: [UploadVideoCall] = []
        var softDeleteMediaCalls: [SoftDeleteMediaCall] = []
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var uploadPhotoCalls: [UploadPhotoCall] { box.withLock { $0.uploadPhotoCalls } }
    var uploadVideoCalls: [UploadVideoCall] { box.withLock { $0.uploadVideoCalls } }
    var softDeleteMediaCalls: [SoftDeleteMediaCall] { box.withLock { $0.softDeleteMediaCalls } }

    func setUploadPhotoHandler(_ handler: @escaping UploadPhotoHandler) {
        box.withLock { $0.uploadPhotoHandler = handler }
    }

    func setUploadPhotoMediaIDHandler(_ handler: @escaping UploadPhotoMediaIDHandler) {
        box.withLock { $0.uploadPhotoMediaIDHandler = handler }
    }

    func setUploadVideoHandler(_ handler: @escaping UploadVideoHandler) {
        box.withLock { $0.uploadVideoHandler = handler }
    }

    func setSoftDeleteMediaHandler(_ handler: @escaping SoftDeleteMediaHandler) {
        box.withLock { $0.softDeleteMediaHandler = handler }
    }

    func uploadPhoto( // swiftlint:disable:this function_parameter_count
        familyID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize, takenAt: Date?, mediaID: UUID?
    ) async throws -> UUID {
        let call = UploadPhotoCall(
            familyID: familyID, fileExtension: fileExtension, pixelSize: pixelSize, takenAt: takenAt, mediaID: mediaID
        )
        box.withLock { $0.uploadPhotoCalls.append(call) }
        if let idHandler = box.withLock({ $0.uploadPhotoMediaIDHandler }) {
            return try await idHandler(mediaID, data)
        }
        let handler = box.withLock { $0.uploadPhotoHandler }
        return try await handler(familyID, data, fileExtension, pixelSize)
    }

    func uploadVideo( // swiftlint:disable:this function_parameter_count
        familyID: UUID, fileURL: URL, fileExtension: String, pixelSize: PixelSize, takenAt: Date?, mediaID: UUID?
    ) async throws -> UUID {
        let call = UploadVideoCall(
            familyID: familyID, fileURL: fileURL, fileExtension: fileExtension, pixelSize: pixelSize, takenAt: takenAt,
            mediaID: mediaID
        )
        box.withLock { $0.uploadVideoCalls.append(call) }
        let handler = box.withLock { $0.uploadVideoHandler }
        return try await handler(familyID, fileURL, fileExtension, pixelSize)
    }

    func softDeleteMedia(mediaIDs: [UUID]) async throws {
        let call = SoftDeleteMediaCall(mediaIDs: mediaIDs)
        box.withLock { $0.softDeleteMediaCalls.append(call) }
        let handler = box.withLock { $0.softDeleteMediaHandler }
        try await handler(mediaIDs)
    }
}
