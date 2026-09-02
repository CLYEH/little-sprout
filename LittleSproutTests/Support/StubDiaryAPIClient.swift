import Foundation
@testable import LittleSprout
import os

/// `DiaryComposerStore` 測試用假 `DiaryAPIClient`——不打真網路（同 `StubChildAPIClient` 的模式，
/// 見該檔）。
final class StubDiaryAPIClient: DiaryAPIClient, @unchecked Sendable {
    typealias CreateHandler = @Sendable (UUID, String, Date, [UUID]) async throws -> UUID
    typealias UpdateHandler = @Sendable (UUID, String, Date, [UUID]) async throws -> Void
    typealias AttachMediaHandler = @Sendable (UUID, UUID, [UUID]) async throws -> Void

    enum StubError: Error {
        case unconfigured
    }

    struct CreateCall: Equatable {
        let familyID: UUID
        let body: String
        let entryDate: Date
        let childIDs: [UUID]
    }

    struct AttachMediaCall: Equatable {
        let diaryID: UUID
        let familyID: UUID
        let mediaIDs: [UUID]
    }

    /// merge-review R2 N1：`updateDiaryEntry` 先前是全專案唯一沒有呼叫端的方法，這裡補上
    /// 呼叫紀錄，才有辦法在測試裡斷言「重試時內容變了，有沒有把新內容送上去」。
    struct UpdateCall: Equatable {
        let diaryID: UUID
        let body: String
        let entryDate: Date
        let childIDs: [UUID]
    }

    private struct Box {
        var createHandler: CreateHandler = { _, _, _, _ in UUID() }
        var updateHandler: UpdateHandler = { _, _, _, _ in }
        var attachMediaHandler: AttachMediaHandler = { _, _, _ in }
        var createCalls: [CreateCall] = []
        var updateCalls: [UpdateCall] = []
        var attachMediaCalls: [AttachMediaCall] = []
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var createCalls: [CreateCall] { box.withLock { $0.createCalls } }
    var updateCalls: [UpdateCall] { box.withLock { $0.updateCalls } }
    var attachMediaCalls: [AttachMediaCall] { box.withLock { $0.attachMediaCalls } }

    func setCreateHandler(_ handler: @escaping CreateHandler) {
        box.withLock { $0.createHandler = handler }
    }

    func setUpdateHandler(_ handler: @escaping UpdateHandler) {
        box.withLock { $0.updateHandler = handler }
    }

    func setAttachMediaHandler(_ handler: @escaping AttachMediaHandler) {
        box.withLock { $0.attachMediaHandler = handler }
    }

    func createDiaryEntry(familyID: UUID, body: String, entryDate: Date, childIDs: [UUID]) async throws -> UUID {
        let call = CreateCall(familyID: familyID, body: body, entryDate: entryDate, childIDs: childIDs)
        box.withLock { $0.createCalls.append(call) }
        let handler = box.withLock { $0.createHandler }
        return try await handler(familyID, body, entryDate, childIDs)
    }

    func updateDiaryEntry(diaryID: UUID, body: String, entryDate: Date, childIDs: [UUID]) async throws {
        let call = UpdateCall(diaryID: diaryID, body: body, entryDate: entryDate, childIDs: childIDs)
        box.withLock { $0.updateCalls.append(call) }
        let handler = box.withLock { $0.updateHandler }
        try await handler(diaryID, body, entryDate, childIDs)
    }

    func attachMedia(diaryID: UUID, familyID: UUID, mediaIDs: [UUID]) async throws {
        let call = AttachMediaCall(diaryID: diaryID, familyID: familyID, mediaIDs: mediaIDs)
        box.withLock { $0.attachMediaCalls.append(call) }
        let handler = box.withLock { $0.attachMediaHandler }
        try await handler(diaryID, familyID, mediaIDs)
    }
}
