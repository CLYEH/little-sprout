import CoreGraphics
import Foundation

/// LS-404（`design/littlesprout.pen` LS-402 Notes `kHDk4`）：設定頁最上方「正在新增照片」入口列的
/// 純邏輯——四態判定、文案、停留期間的狀態機。不含任何 View／async 依賴，XCTest 直接覆蓋
/// （同 `SettingsContentSafetyComposition` 的既有慣例）。

/// 入口列的四態（Notes `OT5n9` 四態文案矩陣）。
enum UploadQueueEntryPhase: Hashable {
    case inProgress
    case inProgressWithFailure
    case onlyFailed
    /// 停留中的過渡態（Notes `bqnO1`）：全部完成，下一個情境邊界才隱藏。
    case allDone

    /// 稿面行數類別（Notes `bqnO1`）：兩行態＝進行中／只剩失敗／全部完成，三行態＝進行中＋失敗。
    /// 停留期間「不增減行」——行數類別不同的轉換一律等情境邊界，不看實測列高。
    var lineCount: Int { self == .inProgressWithFailure ? 3 : 2 }
}

/// 入口列讀的佇列快照（Notes `kI2bt` ②：只讀 `UploadQueueStore` 既有欄位）。
struct UploadQueueEntryCounts: Equatable {
    var waiting = 0
    var uploading = 0
    var failed = 0
    /// 全部完成態的 K（Notes `OT5n9`）：`store.completedCount`，store 保留的已完成數，跨批次累加。
    var completed = 0

    static let zero = UploadQueueEntryCounts()

    /// 進行中的張數（等候＋上傳中）。
    var inFlight: Int { waiting + uploading }
    /// 「還有 N 張還沒完成」的 N＝等候＋上傳中＋失敗（完成的不算，`UploadQueueStore.remainingCount`）。
    var remaining: Int { inFlight + failed }

    /// 依佇列現況該顯示哪一態；`nil`＝沒有東西可顯示（佇列空、或全部完成但本次啟動沒有完成過任何一張）。
    var phase: UploadQueueEntryPhase? {
        if remaining == 0 { return completed > 0 ? .allDone : nil }
        if failed == 0 { return .inProgress }
        return inFlight > 0 ? .inProgressWithFailure : .onlyFailed
    }
}

/// 停留期間的狀態機（Notes `bqnO1`，C1a 條件句）。
///
/// 停在設定頁期間，列的「態」與行數只在**情境邊界**（設定頁 onAppear、佇列 sheet 關閉、App 回前景）
/// 重新評估；停留期間只更新數字，不增減行、不移除列（brand 十條 #10）。判準：列高相同才原地換態，
/// 否則等下一個情境邊界（例：iPad 側欄 100→125、中間字級 Label 換行）。
struct UploadQueueEntryState: Equatable {
    /// 目前畫面上顯示的態；`nil`＝列隱藏。
    private(set) var phase: UploadQueueEntryPhase?

    /// 情境邊界：依佇列現況重新評估。
    /// - 還有未完成項：直接換成現況的態。
    /// - 沒有未完成項（全部完成，或失敗項在 sheet 被全部移除）：**一律隱藏**——「全部完成」過渡態只在停留期間原地換態
    ///   （`liveChanged`）出現，邊界即隱藏（Notes `bqnO1`／`Fq494`，LS-404 merge-review m2 與 LS-410 i2：邊界不再多顯示一次
    ///   「照片都加好了」，對剛放棄的照片也不成立）。
    mutating func contextBoundary(_ counts: UploadQueueEntryCounts) {
        phase = counts.remaining > 0 ? counts.phase : nil
    }

    /// 停留期間佇列有變化：只有「行數類別相同且實測列高相同」才原地換態，否則維持現態等下一個情境邊界。
    /// `rowHeight` 回 `nil`（還沒量到）視同不相同——寧可晚一點換，不在不確定時搬動頁面。
    mutating func liveChanged(_ counts: UploadQueueEntryCounts, rowHeight: (UploadQueueEntryPhase) -> CGFloat?) {
        guard let current = phase, let target = counts.phase, target != current,
              current.lineCount == target.lineCount,
              let currentHeight = rowHeight(current), let targetHeight = rowHeight(target),
              abs(currentHeight - targetHeight) < 0.5 else { return }
        phase = target
    }
}

/// 四態文案（Notes `OT5n9`，逐字取自稿面）：數字與「張」之間 U+00A0，字間 U+2060 只留語意斷點。
enum UploadQueueEntryCopy {
    private static let joiner = "\u{2060}"
    private static let space = "\u{00A0}"

    static func label(_ phase: UploadQueueEntryPhase, _ counts: UploadQueueEntryCounts) -> String {
        switch phase {
        case .inProgress, .inProgressWithFailure:
            "正\(joiner)在新\(joiner)增\(joiner)照\(joiner)片"
        case .onlyFailed:
            "有\(space)\(counts.failed)\(space)張\(joiner)照\(joiner)片沒\(joiner)有\(joiner)加\(joiner)進\(joiner)去"
        case .allDone:
            "照\(joiner)片\(joiner)都加\(joiner)好\(joiner)了"
        }
    }

    static func value(_ phase: UploadQueueEntryPhase, _ counts: UploadQueueEntryCounts) -> String {
        switch phase {
        case .inProgress, .inProgressWithFailure:
            "還有\(space)\(counts.remaining)\(space)張還\(joiner)沒\(joiner)完\(joiner)成"
        case .onlyFailed:
            "看\(joiner)原\(joiner)因\(joiner)，再\(joiner)試\(joiner)或\(joiner)移\(joiner)除"
        case .allDone:
            "\(counts.completed)\(space)張\(joiner)都加\(joiner)進\(joiner)相\(joiner)簿\(joiner)了"
        }
    }

    /// 進行中＋失敗態的第三行（`$danger` 600）；其餘態沒有。
    static func failureLine(_ phase: UploadQueueEntryPhase, _ counts: UploadQueueEntryCounts) -> String? {
        guard phase == .inProgressWithFailure else { return nil }
        return "\(counts.failed)\(space)張沒\(joiner)有\(joiner)成\(joiner)功"
    }

    /// VoiceOver／UITest 用的乾淨文案：拿掉 U+2060、NBSP 換一般空白，各行以逗號相接。
    static func accessibilityLabel(_ phase: UploadQueueEntryPhase, _ counts: UploadQueueEntryCounts) -> String {
        [label(phase, counts), value(phase, counts), failureLine(phase, counts)]
            .compactMap { $0 }
            .map { $0.replacingOccurrences(of: joiner, with: "").replacingOccurrences(of: space, with: " ") }
            .joined(separator: "，")
    }
}
