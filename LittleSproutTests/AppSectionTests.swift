import UIKit
import XCTest
@testable import LittleSprout

/// `AppSection` 是導航 selection 的單一來源，compact 的 TabView 與 regular 的
/// NavigationSplitView 都由它驅動。這些測試鎖住的是「導航長什麼樣」的意圖，
/// 所以任何人增刪區塊、改順序或改圖示時都會先被這裡擋下來。
final class AppSectionTests: XCTestCase {
    func testSectionsAndOrderMatchTheNavigationLayout() {
        XCTAssertEqual(
            AppSection.allCases,
            [.timeline, .albums, .children, .settings],
            "四個區塊與其順序同時決定 TabView 分頁順序與 sidebar 排序，改動需連同版面與設計稿一起確認"
        )
    }

    func testEverySectionHasANonEmptyTitle() {
        for section in AppSection.allCases {
            XCTAssertFalse(
                section.title.isEmpty,
                "\(section) 沒有標題，分頁與 sidebar 會出現無法辨識的空白項目"
            )
        }
    }

    /// 第二道防線：符號名稱本身要合法（存在於當下 runtime 的 SF Symbols 表內）。
    /// 這條測不出「版本太新」的問題（見下面 `testEverySectionSymbolIntroducedAtOrBeforeDeploymentTarget`
    /// 的說明），只防打錯字。
    func testEverySectionSymbolExistsInSFSymbols() {
        for section in AppSection.allCases {
            XCTAssertNotNil(
                UIImage(systemName: section.systemImage),
                "SF Symbol「\(section.systemImage)」不存在；系統會靜默回傳 nil，"
                    + "使用者看到的是沒有圖示的分頁而不是錯誤"
            )
        }
    }

    /// LS-160：上面那條測試只驗「符號在**當下跑測試的那個 runtime** 存在」——本機與 CI 只裝
    /// iOS 26.x，如果有人填一個 iOS 18 才引入的符號，`UIImage(systemName:)` 在 26.x 上照樣
    /// 回傳非 nil，測試照樣綠；但 app 實際部署的最低版本是 iOS 17（`project.yml:12-13`
    /// `deploymentTarget.iOS`），使用者的 iOS 17 裝置會對這個符號靜默顯示空白圖示——
    /// 正是舊測試的註解宣稱要防、卻防不到的事故（LS-150 review R1 I3）。
    ///
    /// 這裡改讀 SF Symbols 的權威版本表（CoreGlyphs 的 `name_availability.plist`，
    /// 每個符號名稱對應一個「year」代碼，`year_to_release` 再把 year 代碼換算成各平台的
    /// 最低系統版本），斷言每個 `AppSection.systemImage` 的最低 iOS 版本 ≤ deployment target。
    func testEverySectionSymbolIntroducedAtOrBeforeDeploymentTarget() {
        guard let plistURL = Self.findNameAvailabilityPlist() else {
            XCTFail(
                "找不到 CoreGlyphs 的 name_availability.plist（查找順序見" +
                " findNameAvailabilityPlist() 註解）——找不到版本表就無法確認符號安全，" +
                "不能靜默略過這條測試"
            )
            return
        }

        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let symbolYears = root["symbols"] as? [String: String],
              let yearToRelease = root["year_to_release"] as? [String: [String: String]] else {
            XCTFail("name_availability.plist（\(plistURL.path)）格式不是預期的 symbols／year_to_release 結構")
            return
        }

        guard let deploymentTarget = Self.actualDeploymentTargetIOSVersion() else {
            XCTFail(
                "讀不到 Bundle.main.infoDictionary[\"MinimumOSVersion\"]——無法確認 app 實際的" +
                " deployment target，不能拿常數頂替（merge-review R1 N2：常數只用來偵測跟" +
                " project.yml 不同步，不是判斷依據本身）"
            )
            return
        }

        for section in AppSection.allCases {
            let symbol = section.systemImage

            guard let year = symbolYears[symbol] else {
                XCTFail("SF Symbol「\(symbol)」不在 CoreGlyphs 版本表內，無法確認引入版本——找不到就當作有風險")
                continue
            }

            guard let introducedIOSVersion = yearToRelease[year]?["iOS"] else {
                XCTFail("符號「\(symbol)」對應的 year「\(year)」在 year_to_release 表內查無 iOS 版本")
                continue
            }

            XCTAssertTrue(
                Self.isVersion(introducedIOSVersion, lessThanOrEqualTo: deploymentTarget),
                "SF Symbol「\(symbol)」是 iOS \(introducedIOSVersion) 才引入，晚於 app 的 deployment target" +
                    " \(deploymentTarget)——低於這個版本的裝置會看到空白圖示"
            )
        }
    }

    /// merge-review R1 N2：上面那條測試判斷符號安全與否，用的是這裡讀到的**實際** deployment
    /// target（`actualDeploymentTargetIOSVersion()`），不是下面的常數——常數只在這一條測試裡
    /// 拿來跟實際值互相校驗。這樣 `project.yml:12` 的 deployment target 改了、這裡的常數卻沒
    /// 同步時，會在這裡大聲提醒，而不是讓上面那條測試悄悄用一個過期的門檻。
    func testDeploymentTargetConstantMatchesActualBuildSetting() {
        guard let deploymentTarget = Self.actualDeploymentTargetIOSVersion() else {
            XCTFail("讀不到 Bundle.main.infoDictionary[\"MinimumOSVersion\"]")
            return
        }
        XCTAssertEqual(
            deploymentTarget, Self.deploymentTargetIOSVersion,
            "project.yml:12 的 deploymentTarget.iOS 改了，但 AppSectionTests 這裡的常數沒同步——" +
                "上面那條符號版本測試用的是實際值，不受影響，但這個常數本身的註解會誤導人"
        )
    }

    /// App 的最低支援 iOS 版本，對應 `project.yml:12-13` 的 `deploymentTarget.iOS: \"17.0\"`。
    /// 只用於 `testDeploymentTargetConstantMatchesActualBuildSetting` 的互相校驗，不是符號版本
    /// 判斷的依據本身（見 `actualDeploymentTargetIOSVersion()`）。
    private static let deploymentTargetIOSVersion = "17.0"

    /// merge-review R1 N2：build 系統會把 `IPHONEOS_DEPLOYMENT_TARGET` 合成進 app 的
    /// `Info.plist`（`MinimumOSVersion` 這個 key，PlistBuddy／reviewer 實測 `= 17.0`）——
    /// unit test 由 app host，`Bundle.main` 就是 app bundle，讀得到。
    private static func actualDeploymentTargetIOSVersion() -> String? {
        Bundle.main.infoDictionary?["MinimumOSVersion"] as? String
    }

    /// merge-review R1 N1：優先序 1——測試行程本身就跑在模擬器裡，`SIMULATOR_ROOT` 環境變數
    /// 直接是「當下這個 runtime」的 RuntimeRoot（reviewer 實測
    /// `SIMULATOR_ROOT=.../iOS 26.0.simruntime/Contents/Resources/RuntimeRoot`、對應的 plist
    /// `exists=true`）——比優先序 2 的「掃描＋字典序取最後」精準：字典序（`iOS_23A8464` 對
    /// `iOS_23F77`）只是碰巧跟版本號同向，選錯 runtime 的表在今天無害（版本表是累積性的），
    /// 但邏輯上不保證未來一直成立。找不到 `SIMULATOR_ROOT`（例如未來測試行程不在模擬器裡跑）
    /// 才退回優先序 2。
    ///
    /// 優先序 2（實測 `find / -iname name_availability.plist` 找到的實際位置，本機兩個
    /// runtime——iOS 26.0／26.5——皆同構）：Xcode 15+ 的 cryptex 掛載路徑
    /// `/Library/Developer/CoreSimulator/Volumes/<volume>/Library/Developer/CoreSimulator/Profiles/`
    /// `Runtimes/<runtime>.simruntime/…`——`xcrun simctl runtime list -j` 印出的
    /// `runtimeBundlePath` 也對應到這裡，GitHub Actions macOS runner 現行 Xcode 版本同樣走這套
    /// cryptex 掛載機制。runtime 目錄再往下固定接 `Contents/Resources/RuntimeRoot/System/`
    /// `Library/PrivateFrameworks/SFSymbols.framework/CoreGlyphs.bundle/name_availability.plist`
    /// （注意是 `CoreGlyphs.bundle`，不是同層的 `CoreGlyphsPrivate.bundle`——後者裝的是內部
    /// 符號，不含 app 實際用得到的公開符號，實測 `stroller.fill` 等四顆都查不到）。同時裝了
    /// 多個 runtime 時取路徑排序最後者（通常對應版本號較新的 runtime）：版本表本身是累積性的
    /// 歷史紀錄，新 runtime 附的表只會更完整、不會更少。
    ///
    /// 沒有再加一條「舊式直接安裝路徑」的退路：那條路徑要用 host Mac 使用者的家目錄組出來，
    /// 但 `FileManager.homeDirectoryForCurrentUser` 在 iOS 上不可用（編譯期錯誤），而
    /// `NSHomeDirectory()`／`ProcessInfo.environment["HOME"]` 在 Simulator 行程裡拿到的是
    /// app sandbox 容器路徑，不是 host 使用者家目錄，組出來的路徑不會存在——加了也只是
    /// 看起來多一層保險、實際上跑不出任何東西，不如不加（Xcode 15+ 一律走 cryptex 掛載，
    /// 這個退路本來就沒有現行環境會用到）。
    private static func findNameAvailabilityPlist() -> URL? {
        plistViaSimulatorRoot() ?? plistViaCryptexScan()
    }

    private static func plistViaSimulatorRoot() -> URL? {
        guard let simulatorRoot = ProcessInfo.processInfo.environment["SIMULATOR_ROOT"] else {
            return nil
        }
        let plist = URL(fileURLWithPath: simulatorRoot).appendingPathComponent(
            "System/Library/PrivateFrameworks/SFSymbols.framework/CoreGlyphs.bundle/name_availability.plist"
        )
        return FileManager.default.fileExists(atPath: plist.path) ? plist : nil
    }

    private static func plistViaCryptexScan() -> URL? {
        let fileManager = FileManager.default
        let cryptexVolumesRoot = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes")

        var runtimesDirs: [URL] = []
        if let volumes = try? fileManager.contentsOfDirectory(at: cryptexVolumesRoot, includingPropertiesForKeys: nil) {
            runtimesDirs += volumes.map {
                $0.appendingPathComponent("Library/Developer/CoreSimulator/Profiles/Runtimes")
            }
        }

        var found: [URL] = []
        for runtimesDir in runtimesDirs {
            guard let runtimes = try? fileManager.contentsOfDirectory(
                at: runtimesDir, includingPropertiesForKeys: nil
            ) else {
                continue
            }
            for runtime in runtimes where runtime.pathExtension == "simruntime" {
                let plist = runtime.appendingPathComponent(
                    "Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks/SFSymbols.framework"
                        + "/CoreGlyphs.bundle/name_availability.plist"
                )
                if fileManager.fileExists(atPath: plist.path) {
                    found.append(plist)
                }
            }
        }
        return found.sorted { $0.path > $1.path }.first
    }

    /// 逐點比較「a.b.c」型式的版本字串（純數字分段，SF Symbols 版本表與 deployment target
    /// 都是這種格式），缺的分段當 0。merge-review R1 N3：分段解析失敗不再靜默當 0（那會被誤判
    /// 成「極舊版本」而讓比較通過）——一律 XCTFail。今天兩個 runtime 的 `year_to_release` 表
    /// 全為純數字分段，測不到這條防線，但保留住 fail loud 的宗旨。
    private static func isVersion(_ lhs: String, lessThanOrEqualTo rhs: String) -> Bool {
        func components(_ version: String) -> [Int] {
            version.split(separator: ".").map { part -> Int in
                guard let value = Int(part) else {
                    XCTFail("版本字串「\(version)」的分段「\(part)」不是純數字，無法比較版本")
                    return 0
                }
                return value
            }
        }
        let lhsComponents = components(lhs)
        let rhsComponents = components(rhs)
        for index in 0..<max(lhsComponents.count, rhsComponents.count) {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue != rhsValue {
                return lhsValue < rhsValue
            }
        }
        return true
    }
}
