#!/bin/bash
# handoff-evidence-check.sh／handoff_evidence_check.py 的自測（LS-211）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若「已驗證」段落偵測退化成只認字面「已驗證」（QA 慣例的
# 「逐條驗收」抓不到）、每項證據判定被拿掉、或「測試名存在」驗證被拿掉（假測試名矇混過關），這裡
# 會紅。另附兩個真實樣本（LS-191 QA comment c541cd06 應紅、LS-192 QA comment 88fb24bc 應綠）——
# 來源見 LS-96 池項 1ff7b8d8／LS-211 票文驗收條件。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/handoff-evidence-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---- 合成 fixture repo：--repo 指到這裡，git grep 驗「測試名存在」用固定、可控的內容，不依賴真
#      LittleSprout 原始碼（真原始碼會隨其他票變動，讓自測結果漂移）。----
R="$work/repo"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$R/Fixture"
git -C "$R" init -q -b main
cat > "$R/Fixture/FooTests.swift" <<'EOF'
import XCTest
final class FooTests: XCTestCase {
    func testBar() {
        XCTAssertTrue(true)
    }
}
EOF
git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false add -A
git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m 'chore(harness): LS-211 fixture'

# expect <期望 exit code> <樣本名稱> <輸出必含字串|''> <handoff 內容>
expect() {
  local want=$1 name=$2 must=$3 body=$4 out got
  printf '%s' "$body" > "$work/handoff.md"
  out="$(bash "$check" "$work/handoff.md" --repo "$R" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# ==== ① 正樣本（≥4）====
expect 0 '①a ios-dev handoff：## 已驗證，dash 列點，測試名存在' '' \
'## 已驗證
- 驗收條件 1：`FooTests.testBar` 綠
'

expect 0 '①b **已驗證** 粗體標題，路徑證據（.png）' '' \
'**已驗證**
- 條件 1：截圖 `scratchpad/LS-1-check.png`
'

expect 0 '①c 純文字「已驗證」開頭起段，command 證據（xcodebuild）' '' \
'已驗證：
- 條件 1：`xcodebuild test -only-testing:Fixture/FooTests` 全綠
'

expect 0 '①d QA 風格「## 逐條驗收」數字編號，測試名存在' '' \
'## 逐條驗收

1. **入口** ✓：`FooTests` 全綠。
2. **回歸** ✓：`bash scripts/gates/foo.sh` exit 0。
'

expect 0 '①e 數字編號項底下接 dash 子列點，證據在子列點內（吸收進同一項）' '' \
'## 逐條驗收

1. **錯誤路徑** ✓
- 子項 a：`evidence/case-a.log` 核對
- 子項 b：程式碼審查（`FamilyThing.swift:12`）
'

expect 0 '①f 命令證據 bash scripts/…' '' \
'## 已驗證
- 條件 1：`bash scripts/ops/foo.sh` 輸出正常
'

# ==== ② 負樣本（≥4）====
expect 1 '②a 列項缺任何證據（無測試名／路徑／命令）' '缺『怎麼驗』證據' \
'## 已驗證
- 條件 1：肉眼看起來沒問題
'

expect 1 '②b 引用不存在的測試名 → 紅（假測試名矇混不過）' 'BogusTests' \
'## 已驗證
- 條件 1：`BogusTests` 全綠
'

expect 2 '②c 找不到「已驗證」（或含「驗收」）段落 → fail closed（exit 2）' '找不到' \
'## 摘要
沒有驗證段落
'

expect 1 '②d 兩項一好一壞：只點名壞的那項行號' '`BogusTests`' \
'## 已驗證
- 條件 1：`FooTests` 全綠
- 條件 2：`BogusTests` 全綠
'

expect 2 '②e 段落內沒有任何列項（只有段落標題）→ fail closed（exit 2）' '沒有任何列項' \
'## 已驗證
純文字說明，沒有 - 或數字列點。
'

# ==== ③ --help／參數 ====
out3a="$(bash "$check" --help 2>&1)"; got3a=$?
if [ "$got3a" -eq 0 ] && printf '%s' "$out3a" | grep -qF -- '用法：'; then
  echo "✓ ③a --help → exit 0，印用法"
else
  echo "✗ ③a --help（期望 exit 0，實得 ${got3a}）" >&2; printf '%s\n' "$out3a" | sed 's/^/    /' >&2; fail=1
fi

out3b="$(bash "$check" 2>&1)"; got3b=$?
if [ "$got3b" -eq 2 ] && printf '%s' "$out3b" | grep -qF -- '用法'; then
  echo "✓ ③b 缺檔參數 → exit 2"
else
  echo "✗ ③b 缺檔參數（期望 exit 2，實得 ${got3b}）" >&2; printf '%s\n' "$out3b" | sed 's/^/    /' >&2; fail=1
fi

out3c="$(printf 'x' > "$work/x.md"; bash "$check" "$work/x.md" --repo "$work/no-such-repo-dir" 2>&1)"; got3c=$?
if [ "$got3c" -eq 2 ]; then
  echo "✓ ③c --repo 指到不存在目錄 → exit 2（找不到段落也一併 fail closed，同 exit 2）"
else
  echo "✗ ③c --repo 錯誤目錄（期望 exit 2，實得 ${got3c}）" >&2; printf '%s\n' "$out3c" | sed 's/^/    /' >&2; fail=1
fi

# ==== ④ 兩個真實樣本（LS-211 票文驗收條件）====
# 直接在本檔內嵌真實 comment 原文（存 handoff-evidence-check.test.sh 才不怕暫存檔被平行 agent 覆寫）。
# 這裡對真的 LittleSprout repo（root）跑，不是合成 fixture——因為要驗的正是這些測試類別在真 repo 內
# 是否存在（LegalDocumentSheetUITests／SettingsViewIPadTests 等，皆已確認存在於 origin/main）。
cat > "$work/ls191-c541cd06.md" <<'REALSAMPLE1'
**QA 裁決（09-06 06:20）— PASS**

Base：`test` tip `6a5db27`（＝`origin/test`，PR #326 併入）；worktree `qa-test` `git checkout --detach 6a5db27` 驗證；`git diff 6871db3..6a5db27 --stat`（本票全部 delta）16 檔，全落在 `Features/Legal/`、`WelcomeView+Legal`、TapTargetGate 註冊、測試、`docs/legal/`、`project.yml`/pbxproj；`-- supabase/migrations design/littlesprout.pen` 空 diff（**無 migration、無 .pen 變更**）；`xcodegen generate` 後 `git status --porcelain` 僅剩 ignored `scratchpad/`（零漂移）。

**逐條驗收**

1. **入口** ✓：`LegalDocumentSheetUITests`（歡迎頁點《使用條款》/《隱私權政策》→ sheet 出現→關閉；privacy 開對文件）在 iPhone（`qa-test-iPhone17Pro`, iOS 26.0）與 iPad（`qa-test-iPadAir11M3`, iOS 26.0）皆跑過、全綠。標題／版本／生效日期解析正確：截圖顯示「版本 v0.1（草稿，尚未生效）· 生效日期：核可後公布」（無日期 fallback 生效）。設定頁法律區（LS-188）與 EULA 入口（LS-190）依票文明講尚未接線，本票只保證 `LegalDocumentSheet(kind:)` API＋歡迎頁入口，已確認 API 穩定可用（`LegalDocumentSheetUITests`/`TapTargetGateHarness+Legal.swift` 皆以此 API 呼叫）。

2. **內容渲染** ✓：`LegalMarkdownDocumentTests` 本機重跑 **15/15 全綠**（含兩份 bundled 全文零錯誤載入、marker 保留 vs 條款編號區分、表格分隔列、inline 粗體、無日期 fallback）。截圖實測（iPhone light/dark/AX3 三態）確認「1. 條款的接受與適用」標題保留編號、且其下「1.1」「1.2」子項編號未被清單語法吃掉——與 R1 F2 修復後的行為一致。附帶觀察（非本票缺陷）：本文仍含未替換的 `[[SUPPORT_URL]]`/`[[OPERATOR_NAME]]` 模板佔位字面，屬 LS-132 法務文本範圍，票文明寫「不做：法務文本修訂」。

3. **iPhone 標準字級** ✓：`qa-test-iPhone17Pro` 亮色／深色截圖對稿，間距字級層次正常；深色 `$print-paper` 為暖深紫（非黑）符合設計決策。Footer 關閉鈕像素量測 **353.7×~55pt**（≥48pt 達標，與 R1/R2 reviewer 量到的 354×57.33pt 數量級一致）。detent：由下往上的 bottom sheet，符合設計決策（非推進頁）。Grabber：iPhone 顯示自畫 Capsule grabber（`showsGrabber:true`）——這是 4 輪 merge-review 已知並接受的 informational 偏離（Notes `H8h08` 字面上是系統 grabber 樣式，自畫版是為了不誤觸 tap-target-check 對系統 grabber 的量測；R1/R2 均已核可、不重複開票）。

4. **AX3（accessibility-extra-large）** ✓：`simctl ui content_size accessibility-extra-large`，全程無裁切、無重疊；用 29 次小步 swipe 完整捲到全文最末（附錄「個人資料保護法」連結列，對應 `k6Rlt` 板描述），footer 全程可見且可點（element 量測 354×80pt）。截圖：`LS-191-qa-ax3-top.png`／`LS-191-qa-ax3-check.png`／`LS-191-qa-ax3-check2.png`／`LS-191-qa-ax3-check3.png`（捲到底）。

5. **iPad** ✓：`LegalDocumentSheetUITests` 在 `qa-test-iPadAir11M3` **4/4 全綠、0 skip**（含 iPad 專屬 520/345 斷言與 320 窄容器 proxy 斷言都是真的執行，不是 skip——本 feature 沒有獨立 `*IPadTests` 類別，iPad 專屬斷言用 `XCTSkipUnless` 掛在 `LegalDocumentSheetUITests` 內，本次在 iPad 機上跑到 0 skip 即滿足票文「不能只有 skipped」）。我自己額外做像素級量測（非引用先前 review 數字）：系統 form sheet 寬 **580pt**、整張紙色無白邊（單一顏色 transition，無中間白帶）；footer 鈕寬 **344.5pt**（＝345±4）、高 **57pt**；紙色左緣到鈕左緣內距 **117.5pt**（＝30 置中偏移＋87.5 內距，與規格精確吻合）；卡頂 163pt 高度範圍內 0 個非紙色像素（**無 grabber**，符合 iPad 分支 `showsGrabber:false`）。回歸：`SettingsViewIPadTests` 6/6 全綠（LS-188 相鄰功能未受影響）。

6. **窄容器** ✓：`LegalDocumentSheetLayoutTests` 本機重跑 **6/6 全綠**（純函式：520→87.5、320→24/272、393 臨界、450 內插、bounds 不變量、超寬 cap）。票文寫「7 則」，實測程式碼確認只有 6 個 test method（`grep -c "func test"` = 6），與 R4 merge-review 的計數一致——判斷為票文措辭誤植，非缺陷。

7. **回歸** ✓：`tap-target-check.sh 5F59FF04… LittleSprout` exit 0（全部已註冊畫面 ≥44×44pt，含 `TapTargetGateTests.testLegalDocumentSheet`／`testLegalDocumentNarrowContainer` 皆綠，legal 相關兩個 case rawValue 不以「View」結尾不進摘要文字但確有跑到且通過，同 R1 handoff 已知瑣事）；`SettingsViewTests` 7/7 全綠；diff/migration/.pen 檢查如上。

**未驗與原因（⊘）**
- **Pencil MCP 逐板像素比對未執行**：`bash scripts/ops/pen-read.sh` 對 qa-test worktree 回 **exit 1（fail-closed）**——工具可用性缺口，非程式碼缺陷。

**風險**：無。無 migration、無執行期並發變更、無 breaking API 變更。
REALSAMPLE1

out_real1="$(bash "$check" "$work/ls191-c541cd06.md" --repo "$root" 2>&1)"; rc_real1=$?
if [ "$rc_real1" -eq 1 ]; then
  echo "✓ ④a 真實樣本 LS-191 QA comment c541cd06 → exit 1（應紅，項 3「iPhone 標準字級」無測試名／路徑／命令證據）"
else
  echo "✗ ④a 真實樣本 c541cd06 應紅（期望 exit 1，實得 ${rc_real1}）" >&2
  printf '%s\n' "$out_real1" | sed 's/^/    /' >&2
  fail=1
fi

cat > "$work/ls192-88fb24bc.md" <<'REALSAMPLE2'
**QA（09-06 08:51）**：**PASS**。test tip `b5f87b9`（＝origin/test，checkout 於 `.claude/worktrees/qa-test`）。逐條獨立重驗（未照抄 merge-review 結論，兩帳號／多家庭真後端 E2E＋backend 查表核對），證據存 `/private/tmp/claude-501/-Users-clyeh-little-sprout/e6972486-fec6-43c0-b8f4-28b43b01a5a0/scratchpad/LS-192-qa-*.png`。

## 自動測試

- `xcodebuild test -only-testing:LittleSproutTests`（`qa-test-iPhone17Pro` 5F59FF04，iOS 26.0）→ **723 tests, 0 failures**，`** TEST SUCCEEDED **`。

## 逐條驗收

**1. 02 編輯顯示名稱與頭像 —— ✓**
怎麼驗：登入 `ls192-owner2` → 設定 →「個人資料」。改名「陳二號」→「陳二號改名」儲存後：設定頁「個人」列即時顯示新名（`LS-192-qa-02-namechange-settings.png`）。AX3（長名字「李王美麗美惠子」）不破版（`LS-192-qa-02-ax3.png`）。深色一張（`LS-192-qa-02-dark.png`）版面正常。
证据：`LS-192-qa-02-profile-light.png`／`-02-dark.png`／`-02-ax3.png`／`-02-namechange-settings.png`。

**2. 03 家庭成員管理 —— ✓**
怎麼驗：owner／member 分別登入查看列表。iPad：`SettingsViewIPadTests` 6 支自動測試綠（含 `testProfileSectionEntryPushesAndBackReturns`／`testSidebarSelectionIsAccessibleAndDistinguishable`）。
证据：`LS-192-qa-03-owner-view.png`／`-03-member-view.png`／`-03-dark.png`／`-03-ax3-longname.png`／`-ipad-launch2.png`。

**3. 03b 移除成員確認 —— ✓**
怎麼驗：owner1 對 member1 執行移出。backend 查表核對確實少一列。
证据：`LS-192-qa-03b-remove-confirm.png`／`-03-after-remove.png`。

**4. 03c 轉移家庭管理者 —— ✓**
怎麼驗：owner3 對 member3 執行轉移。backend 查表核對角色互換。
证据：`LS-192-qa-03c-transfer-confirm.png`／`-03-after-transfer.png`。

**5. 退出家庭三態（真後端、雙帳號＋多帳號）—— ✓（三態全驗）**
- (a) 一般成員退出：確認後成功回三岔路頁（`LS-192-qa-post-leave-threefork.png`）。
证据：`LS-192-qa-03d-leave-confirm.png`／`-03e-musttransfer.png`／`-03e-solemember.png`／`-post-leave-threefork.png`。

**6. 錯誤路徑 —— ✓（部分經真後端觸發，部分經 code review 確認映射）**
- LS057（owner 有其他成員時嘗試退出）：獨立以 HTTP DELETE 重現，並在 UI 上實際點擊觸發同一路徑。
- LS058／LS059／LS060（非 owner 轉移／目標非成員／轉給自己）：`FamilyMemberActionVisibility.swift:89-100` code review 確認 `familyMemberActionMessage` 對五碼皆有專屬文案。
- 斷網情境（"不卡 spinner"）：**⊘ 未實機驗證**——改以 code review 確認：`FamilyStore+Members.swift` 四個動作皆 `guard !isSubmitting` → `.submitting` → `try/catch`。

**7. 回歸 —— ✓**
- `git diff 6a5db27..b5f87b9 --stat`：34 檔皆屬 LS-192 範圍，無 migration、無 `.pen`。
- `TapTargetGateTests` 全量 17 支（含既有 `testSettingsView`／`testTimelineViewDefaultState`／`testUploadQueueSheetView` 等既有畫面）0 failures。

## 未驗與原因

- iPad 互動式截圖：mobile-mcp 對 `qa-test-iPadAir11M3` WDA 連線逾時，改採自動測試（6/6 綠）。

## 環境

- 模擬器已關：`5F59FF04-D2C6-413D-B31A-AFD39B257FB3`（qa-test-iPhone17Pro）。
REALSAMPLE2

out_real2="$(bash "$check" "$work/ls192-88fb24bc.md" --repo "$root" 2>&1)"; rc_real2=$?
if [ "$rc_real2" -eq 0 ]; then
  echo "✓ ④b 真實樣本 LS-192 QA comment 88fb24bc → exit 0（應綠，逐項皆有 .png／測試名／.swift 引用證據）"
else
  echo "✗ ④b 真實樣本 88fb24bc 應綠（期望 exit 0，實得 ${rc_real2}）" >&2
  printf '%s\n' "$out_real2" | sed 's/^/    /' >&2
  fail=1
fi

# ==== ⑤ mutation 負控：拿掉「測試名存在」檢查 → 假測試名樣本改判綠，證明紅是這條檢查造成的 ====
py="${root}/scripts/gates/handoff_evidence_check.py"
mutant="$work/handoff_evidence_check.mutant.py"
if sed 's/bad_names = \[n for n in test_name_candidates(block) if not test_name_exists(repo, n)\]  # HANDOFF-BADNAMES-CHECK/bad_names = []  # HANDOFF-BADNAMES-CHECK/' "$py" > "$mutant" \
   && grep -q 'bad_names = \[\]  # HANDOFF-BADNAMES-CHECK' "$mutant"; then
  bogus_body='## 已驗證
- 條件 1：`BogusTests` 全綠
'
  printf '%s' "$bogus_body" > "$work/bogus.md"
  out_mut="$(python3 "$mutant" "$work/bogus.md" --repo "$R" 2>&1)"; rc_mut=$?
  if [ "$rc_mut" -eq 0 ]; then
    echo "✓ ⑤ mutant（拿掉『測試名存在』檢查）：假測試名 BogusTests 樣本改判綠——證明②b 的紅是這條檢查造成的"
  else
    echo "✗ ⑤ mutant 未如預期翻轉（實得 exit ${rc_mut}）" >&2
    printf '%s\n' "$out_mut" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ⑤ mutate：找不到 HANDOFF-BADNAMES-CHECK 標記，負控本身無效" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ handoff-evidence-check 自測通過"
fi
exit "$fail"
