#!/usr/bin/env python3
"""LS-232 QADriver 全屏 gate 對帳 gate 邏輯（供 qa-driver-gate-check.sh 呼叫）。

來源：兩起事故——LS-190（EULA 同意頁）／LS-217（推播權限前置頁）——`RootView.swift` 新增登入後
全屏 gate 之後，`LittleSproutUITests/QA/QADriver.swift` 沒有同步更新去 dismiss 它，讓
`qa-e2e.sh browse`／`publish` 對任何新帳號卡住（LS-217 QA R1 FAIL，Linear comment
`e4863482`）。規約句「新增登入後全屏 gate 的票 DoD 必含 QADriver 更新」原本只靠自律，兩張票
各漏一次，這支把它機械化。

## 判定規則（單一來源＝標記；掃描僅供備援提示，不影響紅／綠）

1. 「宣告的 gate」清單：掃描 `<repo>/LittleSprout/Navigation/RootView*.swift`（`RootView.swift`
   本身＋同目錄 `RootView+*.swift`——`RootView` 的「直接子 View」檔案，同 既有
   `RootView+AuthenticatedGate.swift`／`QADriver+LoginLanding.swift` 的拆檔慣例）裡的
   `// QA-GATE: <View>` 註解標記。**這是唯一計入紅／綠判定的來源**——`EULAConsentView` 是
   `eulaStore.shouldPresent` 觸發的條件式整樹替換（不是 `.fullScreenCover`／`.sheet` 綁定），
   純掃描 modifier 抓不到這種型態；只有標記能涵蓋「全屏 gate」的所有實作型態（modifier 綁定、
   條件式整樹替換……）。
2. 「已處理」清單：掃描 `<repo>/LittleSproutUITests/QA/QADriver*.swift` 裡的
   `// QA-GATE-HANDLED: <View>` 標記，同理只認標記（不掃 UI 文字／落點名——QADriver 慣例是用
   畫面上的可見文字比對而非型別名，字串掃描既抓不準也容易誤判）。
3. 差集（宣告 − 已處理）非空即紅：列出每個漏掉的 View 名（含宣告位置）＋修法提示。

## 備援掃描（純文字 heuristic；只印 ⚠，不影響 exit code）

額外對同一組 `RootView*.swift` 檔案掃 `.fullScreenCover(`／`.sheet(` 出現的行，往下最多
`BACKUP_SCAN_LOOKAHEAD` 行找第一個「大寫開頭識別字 + `(`」且不是常見 SwiftUI 容器型別
（`CONTAINER_EXCLUDE`）當作綁定的 View 型別名候選；候選不在步驟 1 的標記清單裡就印一行 ⚠
提醒「這個 modifier 綁定的 View 沒有 `// QA-GATE` 標記，若是登入後 gate 請補標記＋更新
QADriver」。這只是漏加標記的提醒（heuristic，不保證抓到每一種寫法，也不代表沒印 ⚠ 就等於
沒有全屏 gate）——`CreateChildView`（LS-113 建立家庭後可跳過的寶貝建檔步驟）目前刻意保留
`// QA-GATE`／`// QA-GATE-HANDLED` 標記（見 `RootView.swift`／`QADriver.swift`），所以不會
印這行 ⚠；若之後拿掉標記，備援掃描仍會找到它、印 ⚠ 提醒，但不會讓本 gate 轉紅——是否要求
每個 modifier 綁定都得有標記是另一個問題，票文範圍只要求「掃描為備援印 ⚠」。

用法：qa_driver_gate_check.py --repo <dir>
exit：0＝宣告的 gate 都有對應的 QADriver 已處理標記；1＝有缺漏（列出漏掉的 View 名）；
2＝參數／環境錯誤（fail closed）。
"""
import glob
import os
import re
import sys

GATE_MARKER_RE = re.compile(r'//\s*QA-GATE:\s*([A-Za-z_][A-Za-z0-9_]*)')
HANDLED_MARKER_RE = re.compile(r'//\s*QA-GATE-HANDLED:\s*([A-Za-z_][A-Za-z0-9_]*)')
MODIFIER_RE = re.compile(r'\.(fullScreenCover|sheet)\(')
VIEW_CALL_RE = re.compile(r'\b([A-Z][A-Za-z0-9_]*)\(')

# 常見 SwiftUI 容器／輔助型別——備援掃描往下找「第一個大寫識別字＋`(`」時，這些不算是被
# modifier 蓋起來的目標畫面，跳過繼續找下一個。
CONTAINER_EXCLUDE = {
    "Binding", "Group", "NavigationStack", "NavigationView", "VStack", "HStack",
    "ZStack", "ScrollView", "List", "Form", "TabView", "EmptyView", "AnyView",
    "GeometryReader", "LazyVStack", "LazyHStack", "ForEach",
}
BACKUP_SCAN_LOOKAHEAD = 20

ROOT_VIEW_GLOB = os.path.join("LittleSprout", "Navigation", "RootView*.swift")
QA_DRIVER_GLOB = os.path.join("LittleSproutUITests", "QA", "QADriver*.swift")


def fail(msg):
    sys.stderr.write("✗ qa-driver-gate-check：%s\n" % msg)
    sys.exit(2)


def find_files(repo, relglob):
    return sorted(glob.glob(os.path.join(repo, relglob)))


def read_lines(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.readlines()
    except OSError as exc:
        fail("讀不到 %s（%s）" % (path, exc))
        return []  # 不會執行到（fail 已 exit），安撫型別檢查


def scan_markers(files, pattern):
    """回傳 {View 名: [(相對路徑, 行號), ...]}（依檔案／出現順序）。"""
    found = {}
    for path in files:
        for lineno, line in enumerate(read_lines(path), start=1):
            m = pattern.search(line)
            if m:
                found.setdefault(m.group(1), []).append((path, lineno))
    return found


def scan_modifier_backup(files, declared_names):
    """備援掃描：找 `.fullScreenCover(`／`.sheet(` 綁定但沒有對應 `// QA-GATE:` 標記的 View，
    回傳警告文字清單（不影響 exit code，見檔頭）。"""
    warnings = []
    for path in files:
        lines = read_lines(path)
        for i, line in enumerate(lines):
            modifier_match = MODIFIER_RE.search(line)
            if not modifier_match:
                continue
            modifier = modifier_match.group(1)
            candidate = None
            for j in range(i, min(i + BACKUP_SCAN_LOOKAHEAD, len(lines))):
                for call_match in VIEW_CALL_RE.finditer(lines[j]):
                    name = call_match.group(1)
                    if name in CONTAINER_EXCLUDE:
                        continue
                    candidate = name
                    break
                if candidate:
                    break
            if candidate and candidate not in declared_names:
                warnings.append(
                    "%s:%d：`.%s` 疑似綁定 `%s`，沒有對應 `// QA-GATE: %s` 標記——若這是登入後"
                    "全屏 gate，請補標記並確認 QADriver 有 `// QA-GATE-HANDLED: %s`"
                    % (path, i + 1, modifier, candidate, candidate, candidate)
                )
    return warnings


def run(repo):
    if not os.path.isdir(repo):
        fail("--repo 指到的目錄不存在：%s" % repo)

    root_view_files = find_files(repo, ROOT_VIEW_GLOB)
    if not root_view_files:
        fail("找不到 %s（repo 結構是否正確？）" % os.path.join(repo, ROOT_VIEW_GLOB))
    qa_driver_files = find_files(repo, QA_DRIVER_GLOB)
    if not qa_driver_files:
        fail("找不到 %s（repo 結構是否正確？）" % os.path.join(repo, QA_DRIVER_GLOB))

    declared = scan_markers(root_view_files, GATE_MARKER_RE)
    handled = scan_markers(qa_driver_files, HANDLED_MARKER_RE)

    missing = sorted(set(declared) - set(handled))

    for warning in scan_modifier_backup(root_view_files, declared):
        print("⚠ qa-driver-gate-check：%s" % warning)

    if missing:
        print("✗ qa-driver-gate-check：QADriver 沒有處理下列登入後全屏 gate：")
        for name in missing:
            locs = "、".join("%s:%d" % (p, l) for p, l in declared[name])
            print(
                "    - %s（宣告於 %s）——在 QADriver 加落點＋dismiss（比照既有 EULA／推播前置頁"
                "處理），並在對應位置加 `// QA-GATE-HANDLED: %s` 標記" % (name, locs, name)
            )
        return False

    print(
        "✓ qa-driver-gate-check：宣告的 %d 個登入後全屏 gate（%s）QADriver 皆已標記處理"
        % (len(declared), "、".join(sorted(declared)) if declared else "無")
    )
    return True


def main(argv):
    args = argv[1:]
    repo = None
    it = iter(args)
    for a in it:
        if a in ("--help", "-h"):
            print(__doc__)
            sys.exit(0)
        if a == "--repo":
            try:
                repo = next(it)
            except StopIteration:
                fail("--repo 缺值")
            continue
        fail("未知參數 %s" % a)
    if repo is None:
        fail("用法：qa_driver_gate_check.py --repo <dir>")

    ok = run(repo)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main(sys.argv)
