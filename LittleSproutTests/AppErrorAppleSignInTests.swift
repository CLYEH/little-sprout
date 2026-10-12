import AuthenticationServices
import Foundation
@testable import LittleSprout
import XCTest

/// LS-498：Apple 原生登入失敗的 AppError 映射（獨立一支檔案，`AppErrorTests` 已逼近 SwiftLint type_body_length 上限）。
final class AppErrorAppleSignInTests: XCTestCase {
    /// 為什麼：build 缺 Sign in with Apple entitlement 時真機只回 `ASAuthorizationError.unknown`（1000），
    /// 過去落 `.server` 顯示「伺服器發生問題」，使用者與我們都看不出是裝置端問題。非取消的 Apple 錯誤
    /// 必須帶出 Apple 代碼；使用者主動取消仍靜默（不是錯誤）。
    func test_fromAppleSignIn_nonCanceledErrorsKeepAppleCode_andCanceledIsSilent() {
        let cases: [(ASAuthorizationError.Code, Int)] = [
            (.unknown, 1000), (.failed, 1004), (.invalidResponse, 1002), (.notHandled, 1003)
        ]
        for (code, expected) in cases {
            let mapped = AppError.fromAppleSignIn(ASAuthorizationError(code))
            XCTAssertEqual(mapped, .appleSignInFailed(code: expected), "code \(expected) 應映射到 .appleSignInFailed")
            XCTAssertTrue(
                mapped?.userFacingMessage.contains("代碼 \(expected)") == true,
                "文案應含 Apple 代碼 \(expected)，實際：\(mapped?.userFacingMessage ?? "nil")"
            )
        }
        XCTAssertNil(AppError.fromAppleSignIn(ASAuthorizationError(.canceled)), ".canceled 不得產生 AppError（靜默）")
    }
}
