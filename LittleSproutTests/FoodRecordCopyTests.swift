import XCTest
@testable import LittleSprout

/// LS-380：03 sheet 家族的純邏輯——逐字文案（稿 `FP2An`／`ekxHM`／`Oob1d`／`NgnYl`）、日期欄格式（Notes
/// `vMFj3` MN-1）、Status Slot 候選句（Notes `hqrit` max() 規則）、03d 分段（Notes `m18MTy`）。
final class FoodRecordCopyTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!

    private func localDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = taipei
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: - 文案

    func test_headTitle_firstRecordAndEdit() {
        XCTAssertEqual(FoodRecordCopy.headTitle(childName: "小安", foodName: "芋頭", isEditing: false), "記下小安第一次吃芋頭")
        XCTAssertEqual(FoodRecordCopy.headTitle(childName: "小安", foodName: "吐司麵包", isEditing: true), "編輯吐司麵包這筆記錄")
        XCTAssertEqual(FoodRecordCopy.reactionLabel(childName: "小安"), "小安覺得怎麼樣（可不選）")
    }

    /// 今天＝省年＋「（今天）」；其他日子＝yyyy年M月d日（03b 同年也帶年，稿 `XDLD2`「2026年6月8日」）；AX 明確斷兩行。
    func test_dateValue_todayOmitsYear_otherDaysShowYear_axBreaksLines() {
        let now = localDate(2026, 8, 20)
        let midnight = localDate(2026, 8, 20, hour: 0)
        XCTAssertEqual(FoodRecordCopy.dateValue(midnight, now: now, timeZone: taipei, twoLines: false), "8月20日（今天）")
        XCTAssertEqual(FoodRecordCopy.dateValue(localDate(2026, 8, 20), now: now, timeZone: taipei, twoLines: true),
                       "8月20日\n（今天）")
        XCTAssertEqual(FoodRecordCopy.dateValue(localDate(2026, 6, 8), now: now, timeZone: taipei, twoLines: false),
                       "2026年6月8日")
        XCTAssertEqual(FoodRecordCopy.dateValue(localDate(2026, 6, 8), now: now, timeZone: taipei, twoLines: true),
                       "2026年\n6月8日")
    }

    func test_statusAndFailureCopy() {
        XCTAssertEqual(
            FoodRecordCopy.statusNormal(foodName: "芋頭", isEditing: false), "儲存後芋頭會變成彩色，家人也會在時間軸看到這一刻。"
        )
        XCTAssertEqual(FoodRecordCopy.statusNormal(foodName: "芋頭", isEditing: true), "改好後按「儲存」，時間軸上的卡片也會跟著更新。")
        XCTAssertEqual(
            FoodRecordCopy.saveFailed(.network(message: "offline")),
            "沒有存起來：網路好像斷了。填好的內容都還在，連上網路後再按一次「儲存」。", "斷線＝稿面 03e 那一句"
        )
        XCTAssertEqual(
            FoodRecordCopy.saveFailed(.rejected(message: "x", code: "LS052")), "沒有存起來：無法完成這個操作。",
            "其餘碼共用同一格，不把後端原始訊息上螢幕"
        )
    }

    /// 票文範圍 3：03c 文案逐字。
    func test_deleteCopy_matchesTicketWording() {
        XCTAssertEqual(FoodRecordCopy.deleteTitle(foodName: "吐司麵包"), "要刪除吐司麵包這筆記錄嗎？")
        XCTAssertEqual(
            FoodRecordCopy.deleteBody(foodName: "吐司麵包"), "吐司麵包會變回灰色，時間軸上的卡片也會拿掉。照片會留在家庭相簿。"
        )
        XCTAssertEqual(FoodRecordCopy.revealAnnouncement(foodName: "芋頭"), "已記下芋頭")
    }

    // MARK: - Status Slot max() 規則（票文範圍 2）

    /// 平時就把 03e 那句失敗句疊進去量高度——第一次失敗時 Slot 不長高、儲存鈕不位移。拿掉它 Slot 只量一般句，
    /// 失敗時長高、儲存鈕被往下推（`FoodRecordSheetUITests.testFailureKeepsSaveButtonInPlace_AX3` 在畫面上驗）。
    func test_statusCandidates_alwaysIncludeNormalAndDesignedFailureSentence() {
        let normal = FoodRecordStatus.normal(FoodRecordCopy.statusNormal(foodName: "芋頭", isEditing: false))
        let candidates = FoodRecordStatus.candidates(current: normal, foodName: "芋頭", isEditing: false)
        XCTAssertEqual(candidates, [normal, .failure(FoodRecordCopy.saveFailedNetwork)])
    }

    func test_statusCandidates_appendOtherFailureOnce() {
        let other = FoodRecordStatus.failure(FoodRecordCopy.saveFailed(.rejected(message: "x", code: "42501")))
        let candidates = FoodRecordStatus.candidates(current: other, foodName: "芋頭", isEditing: true)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates.last, other)

        let network = FoodRecordStatus.failure(FoodRecordCopy.saveFailedNetwork)
        XCTAssertEqual(
            FoodRecordStatus.candidates(current: network, foodName: "芋頭", isEditing: true).count, 2, "同一句不重複疊"
        )
    }

    // MARK: - 03d 分段

    private func photo(_ index: Int, takenAt: Date?, createdAt: Date) -> FamilyPhoto {
        FamilyPhoto(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            storagePath: "f/\(index).jpg", thumbPath: "f/\(index)_thumb.jpg", takenAt: takenAt, createdAt: createdAt
        )
    }

    func test_sections_todayFirstThenOthers_newestFirst_takenAtBeforeCreatedAt() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = taipei
        let now = localDate(2026, 8, 20, hour: 18)
        let todayMorning = photo(
            1, takenAt: localDate(2026, 8, 20, hour: 8), createdAt: localDate(2026, 8, 20, hour: 9)
        )
        let todayNoon = photo(2, takenAt: nil, createdAt: localDate(2026, 8, 20, hour: 12))
        // 今天才上傳、但其實是上週拍的：歸「其他照片」（taken_at 優先）。
        let lastWeek = photo(3, takenAt: localDate(2026, 8, 13), createdAt: localDate(2026, 8, 20, hour: 10))
        let lastMonth = photo(4, takenAt: nil, createdAt: localDate(2026, 7, 20))

        let sections = FamilyPhotoSections.make(
            photos: [lastMonth, todayMorning, lastWeek, todayNoon], recordDate: localDate(2026, 8, 20), now: now,
            calendar: calendar
        )

        XCTAssertEqual(sections.map(\.title), ["今天拍的", "其他照片"])
        XCTAssertEqual(sections[0].photos, [todayNoon, todayMorning])
        XCTAssertEqual(sections[1].photos, [lastWeek, lastMonth])
        XCTAssertEqual(todayMorning.displayPath, "f/1_thumb.jpg", "縮圖優先，不載原圖")
    }

    func test_sections_backfilledDateTitle_andNoEmptySection() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = taipei
        let sameDay = photo(1, takenAt: localDate(2026, 6, 8), createdAt: localDate(2026, 6, 9))

        let sections = FamilyPhotoSections.make(
            photos: [sameDay], recordDate: localDate(2026, 6, 8), now: localDate(2026, 8, 20), calendar: calendar
        )

        XCTAssertEqual(sections.map(\.title), ["6月8日那天拍的"], "回填日期：「M月d日那天拍的」；沒有其他照片就不出現那段")
    }
}
