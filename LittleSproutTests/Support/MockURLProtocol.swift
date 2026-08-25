import Foundation
import os

/// 攔截所有透過它安裝的 `URLSession`送出的請求，回傳測試預先寫好的回應——LS-49 的
/// `SupabaseAuthService`／`SupabaseFamilyAPIClient` 測試藉此驗證真正的 SDK 編碼/解碼與
/// 錯誤映射邏輯，同時保證「不打真網路」（見 ticket 驗收條件）。
///
/// Handler 只設一個全域 static——測試方法之間必須序列跑（XCTest 預設行為，本專案未啟用
/// parallel testing），每個測試在呼叫前才設定自己的 handler，互不重疊。
final class MockURLProtocol: URLProtocol {
    struct StubResponse: Sendable {
        let statusCode: Int
        let body: Data
        let headers: [String: String]

        init(statusCode: Int, body: Data = Data(), headers: [String: String] = ["Content-Type": "application/json"]) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }
    }

    typealias Handler = @Sendable (URLRequest) throws -> StubResponse

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)

    static func setHandler(_ handler: Handler?) {
        handlerBox.withLock { $0 = handler }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handlerBox.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let stub = try handler(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://test.invalid")!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
