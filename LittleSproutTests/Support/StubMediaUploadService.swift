import Foundation
@testable import LittleSprout
import os

/// `DiaryComposerStore` 測試用假 `MediaUploadService`——不打真網路、不碰真的檔案系統。
final class StubMediaUploadService: MediaUploadService, @unchecked Sendable {
    typealias UploadPhotoHandler = @Sendable (UUID, Data, String, PixelSize) async throws -> UUID
    typealias UploadVideoHandler = @Sendable (UUID, URL, String, PixelSize) async throws -> UUID
    typealias SoftDeleteMediaHandler = @Sendable ([UUID]) async throws -> Void

    struct UploadPhotoCall: Equatable {
        let familyID: UUID
        let fileExtension: String
        let pixelSize: PixelSize
    }

    struct UploadVideoCall: Equatable {
        let familyID: UUID
        let fileURL: URL
        let fileExtension: String
        let pixelSize: PixelSize
    }

    /// LS-212：`DiaryComposerStore.cleanupRemovedDrafts` 軟刪已上傳孤兒 media 的呼叫記錄。
    struct SoftDeleteMediaCall: Equatable {
        let mediaIDs: [UUID]
    }

    private struct Box {
        var uploadPhotoHandler: UploadPhotoHandler = { _, _, _, _ in UUID() }
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

    func setUploadVideoHandler(_ handler: @escaping UploadVideoHandler) {
        box.withLock { $0.uploadVideoHandler = handler }
    }

    func setSoftDeleteMediaHandler(_ handler: @escaping SoftDeleteMediaHandler) {
        box.withLock { $0.softDeleteMediaHandler = handler }
    }

    func uploadPhoto(familyID: UUID, data: Data, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
        let call = UploadPhotoCall(familyID: familyID, fileExtension: fileExtension, pixelSize: pixelSize)
        box.withLock { $0.uploadPhotoCalls.append(call) }
        let handler = box.withLock { $0.uploadPhotoHandler }
        return try await handler(familyID, data, fileExtension, pixelSize)
    }

    func uploadVideo(familyID: UUID, fileURL: URL, fileExtension: String, pixelSize: PixelSize) async throws -> UUID {
        let call = UploadVideoCall(
            familyID: familyID, fileURL: fileURL, fileExtension: fileExtension, pixelSize: pixelSize
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
