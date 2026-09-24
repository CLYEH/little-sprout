import XCTest

/// LS-335 範圍 8（來源 LS-334 merge-review R2 m1 `c3e7fd18`）：`ageDescriptionForTesting` 只准測試呼叫——
/// production 入口改走 private `ageDescriptionCore`。mutation：`ageDescription(timeZone:)` 改回呼叫
/// `ageDescriptionForTesting`，這支測試轉紅。
final class AgeDescriptionForTestingCallerGuardTests: XCTestCase {
    func test_ageDescriptionForTesting_hasNoProductionCaller() throws {
        let appRoot = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LittleSprout")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var callers: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            for line in lines where line.contains("ageDescriptionForTesting(")
                && !line.contains("static func ageDescriptionForTesting(")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                callers.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(callers, [], "ageDescriptionForTesting 只准測試呼叫——production 走 ageDescriptionCore（LS-335 範圍 8）")
    }
}
