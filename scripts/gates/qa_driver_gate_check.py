#!/usr/bin/env python3
"""LS-232 QADriver 全屏 gate 對帳 gate 邏輯（供 qa-driver-gate-check.sh 呼叫）。

來源：兩起事故——LS-190（EULA 同意頁）／LS-217（推播權限前置頁）——`RootView.swift` 新增登入後
全屏 gate 之後，`LittleSproutUITests/QA/QADriver.swift` 沒有同步更新去 dismiss 它，讓
`qa-e2e.sh browse`／`publish` 對任何新帳號卡住（LS-217 QA R1 FAIL，Linear comment
`e4863482`）。規約句「新增登入後全屏 gate 的票 DoD 必含 QADriver 更新」原本只靠自律，兩張票
各漏一次，這支把它機械化。

## 判定規則（LS-232 R2：merge-review R1 M1 修正——備援掃描的候選現在也計入紅／綠，不再只印 ⚠）

1. 「宣告的 gate」清單：掃描 `<repo>/LittleSprout/Navigation/RootView*.swift`（`RootView.swift`
   本身＋同目錄 `RootView+*.swift`——`RootView` 的「直接子 View」檔案，同既有
   `RootView+AuthenticatedGate.swift`／`QADriver+LoginLanding.swift` 的拆檔慣例）裡的
   `// QA-GATE: <View>` 註解標記。`EULAConsentView` 是 `eulaStore.shouldPresent` 觸發的條件式
   整樹替換（不是 `.fullScreenCover`／`.sheet` 綁定），純掃描 modifier 抓不到這種型態；只有
   標記能涵蓋「全屏 gate」的所有實作型態（modifier 綁定、條件式整樹替換……）。
2. 「已處理」清單：掃描 `<repo>/LittleSproutUITests/QA/QADriver*.swift` 裡的
   `// QA-GATE-HANDLED: <View>` 標記，同理只認標記（不掃 UI 文字／落點名——QADriver 慣例是用
   畫面上的可見文字比對而非型別名，字串掃描既抓不準也容易誤判）。
3. 「豁免」清單：掃描同一組 `RootView*.swift` 檔案裡的 `// QA-GATE-EXEMPT: <View>` 標記——用來
   宣告「這個 modifier 綁定的 View 不是登入後全屏 gate」（例如純提示用的 `.sheet`），把它從
   下面第 5 步的候選集合裡排除。
4. 差集（宣告 − 已處理）非空即紅：列出每個漏掉的 View 名（含宣告位置）＋修法提示。這條規則
   不變。
5. **備援掃描候選（見下）－ 宣告 － 豁免，非空即紅**（LS-232 merge-review R1 M1：兩起事故
   ——LS-190／LS-217——的實際形態都是「新增 gate 的人根本沒想到要寫 `// QA-GATE:` 標記」，
   若紅／綠只看標記，這條規則本身變成一條沒有 gate 擋著、只能靠自律遵守的規則，正是本票要
   取代的東西。修法前這裡只印 ⚠、不影響 exit code——對「未 patch 的 LS-217 事故 head
   `938e854`」實測會是 **綠 exit 0**，等於這支 gate 放行了它被建出來要擋的那個 commit）。
   列出每個未標記候選的 View 名＋位置，並提示「補 `// QA-GATE:` 標記＋更新 QADriver＋補
   `// QA-GATE-HANDLED:`，或這不是登入後 gate 就補 `// QA-GATE-EXEMPT: <View>` 並寫理由」。

## 備援掃描（純文字 heuristic）

對 `RootView*.swift` 檔案掃 `.fullScreenCover(`／`.sheet(` 出現的行，往下最多
`BACKUP_SCAN_LOOKAHEAD` 行找第一個「大寫開頭識別字 + `(`」且不是常見 SwiftUI 基本／容器型別
（`CONTAINER_EXCLUDE`）當作綁定的 View 型別名候選。這是 heuristic，不保證抓到每一種寫法（例如
型別名用變數組出來、巢狀更深的寫法可能找不到候選；`.fullScreenCover { VStack { Text…; Button… } }`
這種把 gate 直接寫在 closure 裡、不抽成具名 View 的寫法，closure 內只剩 `CONTAINER_EXCLUDE`
型別，一律找不到候選——LS-232 R2 merge-review N3，兩起真實事故 `EULAConsentView`／
`PushPrepromptView` 皆為具名 View，專案慣例也是具名，故列已知盲區不列必修）——找不到候選
不代表沒有全屏 gate，仍要靠 code review／DoD 自律補位；標記（步驟 1）才是能涵蓋所有實作型態
的來源。另外，這是**線性文字掃描、不認 modifier closure 邊界**：視窗若跨過該 modifier 的收合
`}` 仍會繼續找，可能把 closure 外的無關型別誤判成候選（假紅）；視窗太短也可能漏抓真候選（該紅
沒紅）——LS-232 R2 merge-review N2／N6，已記入待辦池 LS-96（comment `4c7a7d7e`），非本輪必修。

`CONTAINER_EXCLUDE`（LS-232 R2 m1：merge-review R1 實測 `.sheet { Text(…) }` 會把 `Text` 當
候選，M1 把備援掃描候選轉紅之後這種型別若不排除就是假紅——必須在此列出所有常見的 SwiftUI
基本型別，而非只列容器型別）：`Text`／`Button`／`Image` 這三個是 R2 新補的最小集合（票文
LS-232 R2 指定的至少清單，另外 `VStack`／`HStack`／`ZStack`／`Group`／`NavigationStack`／
`ScrollView`／`Form`／`List`／`EmptyView`／`AnyView` 原本就在清單內）。日後若又遇到其他 SwiftUI
基本型別被誤判成候選，比照本次做法補進這個集合，不要繞道用行號／字串長度之類的間接判斷。

用法：qa_driver_gate_check.py --repo <dir>
exit：0＝宣告的 gate 都有對應的 QADriver 已處理標記、且沒有未標記／未豁免的備援掃描候選；
1＝有缺漏或未標記候選（列出 View 名＋修法提示）；2＝參數／環境錯誤（fail closed）。
"""
import glob
import os
import re
import sys

GATE_MARKER_RE = re.compile(r'//\s*QA-GATE:\s*([A-Za-z_][A-Za-z0-9_]*)')
HANDLED_MARKER_RE = re.compile(r'//\s*QA-GATE-HANDLED:\s*([A-Za-z_][A-Za-z0-9_]*)')
EXEMPT_MARKER_RE = re.compile(r'//\s*QA-GATE-EXEMPT:\s*([A-Za-z_][A-Za-z0-9_]*)')
MODIFIER_RE = re.compile(r'\.(fullScreenCover|sheet)\(')
VIEW_CALL_RE = re.compile(r'\b([A-Z][A-Za-z0-9_]*)\(')

# 常見 SwiftUI 容器／基本型別——備援掃描往下找「第一個大寫識別字＋`(`」時，這些不算是被
# modifier 蓋起來的目標畫面，跳過繼續找下一個。LS-232 R2 m1：`Text`／`Button`／`Image` 是
# 新補的基本型別（見檔頭「備援掃描」段）——備援掃描候選現在會影響 exit code（M1），漏排除
# 這些常見型別會變成假紅。
CONTAINER_EXCLUDE = {
    "Binding", "Group", "NavigationStack", "NavigationView", "VStack", "HStack",
    "ZStack", "ScrollView", "List", "Form", "TabView", "EmptyView", "AnyView",
    "GeometryReader", "LazyVStack", "LazyHStack", "ForEach",
    "Text", "Button", "Image",
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


def scan_modifier_backup(files):
    """備援掃描：找 `.fullScreenCover(`／`.sheet(` 綁定、往下最多 `BACKUP_SCAN_LOOKAHEAD` 行內
    第一個非 `CONTAINER_EXCLUDE` 的大寫識別字呼叫，視為候選 View。回傳
    `[(候選 View 名, 相對路徑, 1-index 行號, modifier 名), ...]`——不做任何清單比對（是否計入
    紅／綠交給 `run()`，見 M1）。"""
    candidates = []
    for path in files:
        lines = read_lines(path)
        for i, line in enumerate(lines):
            modifier_match = MODIFIER_RE.search(line)
            if not modifier_match:
                continue
            modifier = modifier_match.group(1)
            candidate = None
            candidate_lineno = None
            for j in range(i, min(i + BACKUP_SCAN_LOOKAHEAD, len(lines))):
                for call_match in VIEW_CALL_RE.finditer(lines[j]):
                    name = call_match.group(1)
                    if name in CONTAINER_EXCLUDE:
                        continue
                    candidate = name
                    candidate_lineno = j + 1
                    break
                if candidate:
                    break
            if candidate:
                candidates.append((candidate, path, candidate_lineno, modifier))
    return candidates


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
    exempt = scan_markers(root_view_files, EXEMPT_MARKER_RE)

    missing = sorted(set(declared) - set(handled))

    # M1：備援掃描候選 － 宣告 － 豁免，非空即紅（候選已宣告的走上面 missing／handled 差集邏輯，
    # 這裡不重複列）。
    unmarked = {}
    for name, path, lineno, modifier in scan_modifier_backup(root_view_files):
        if name in declared or name in exempt:
            continue
        unmarked.setdefault(name, []).append((path, lineno, modifier))

    if missing or unmarked:
        if missing:
            print("✗ qa-driver-gate-check：QADriver 沒有處理下列登入後全屏 gate：")
            for name in missing:
                locs = "、".join("%s:%d" % (p, l) for p, l in declared[name])
                print(
                    "    - %s（宣告於 %s）——在 QADriver 加落點＋dismiss（比照既有 EULA／推播前置頁"
                    "處理），並在對應位置加 `// QA-GATE-HANDLED: %s` 標記" % (name, locs, name)
                )
        if unmarked:
            print(
                "✗ qa-driver-gate-check：偵測到疑似登入後全屏 gate 但未標記（%d 個）："
                % len(unmarked)
            )
            for name in sorted(unmarked):
                locs = "、".join("%s:%d（`.%s`）" % (p, l, m) for p, l, m in unmarked[name])
                print(
                    "    - %s（%s）——若這是登入後全屏 gate，請加 `// QA-GATE: %s` 標記＋在"
                    "QADriver 加落點＋dismiss 處理＋加 `// QA-GATE-HANDLED: %s` 標記；若不是，"
                    "請加 `// QA-GATE-EXEMPT: %s` 並寫明理由" % (name, locs, name, name, name)
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
