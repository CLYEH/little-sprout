import Foundation
@testable import LittleSprout
import os

/// `ChildrenStore` 測試用假 `ChildAvatarUploadService`——不做真的裁方／編碼，用可設定的
/// handler 決定表現（同 `StubChildAPIClient` 的模式，見該檔）。
final class StubChildAvatarUploadService: ChildAvatarUploadService, @unchecked Sendable {
    typealias UploadAvatarHandler = @Sendable (UUID, UUID, Data) async throws -> String

    enum StubError: Error {
        case unconfigured
    }

    struct UploadAvatarCall: Equatable {
        let familyID: UUID
        let childID: UUID
        let imageData: Data
    }

    private struct Box {
        var handler: UploadAvatarHandler = { _, _, _ in throw StubError.unconfigured }
        var calls: [UploadAvatarCall] = []
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var calls: [UploadAvatarCall] {
        box.withLock { $0.calls }
    }

    func setUploadAvatarHandler(_ handler: @escaping UploadAvatarHandler) {
        box.withLock { $0.handler = handler }
    }

    func uploadAvatar(familyID: UUID, childID: UUID, imageData: Data) async throws -> String {
        let call = UploadAvatarCall(familyID: familyID, childID: childID, imageData: imageData)
        box.withLock { $0.calls.append(call) }
        let handler = box.withLock { $0.handler }
        return try await handler(familyID, childID, imageData)
    }
}
