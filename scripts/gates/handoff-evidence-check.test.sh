#!/bin/bash
# handoff-evidence-check.sh／handoff_evidence_check.py 的自測（LS-211）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若「已驗證」段落偵測退化成只認字面「已驗證」（QA 慣例的
# 「逐條驗收」抓不到）、每項證據判定被拿掉、或「測試名存在」驗證被拿掉（假測試名矇混過關），這裡
# 會紅。另附兩個真實樣本（LS-191 QA comment c541cd06 應紅、LS-192 QA comment 88fb24bc 應綠）——
# 來源見 LS-96 池項 1ff7b8d8／LS-211 票文驗收條件。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/handoff-evidence-check.sh"
py="${root}/scripts/gates/handoff_evidence_check.py"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# R3（merge-review R2 i5）：印精確的「n 組樣本」總結——之前是手數（申報「37 組」，實跑其實是 30
# 條 ✓），跟其他自測檔（如 agent-tools-check.test.sh 的 `ok()` 計數器）比起來會漂移。這裡不改寫每個
# 既有 `echo "✓ …"` 呼叫點，改用 `tee` 把全部 stdout 另存一份，收工時對這份存檔數 `^✓` 開頭的行數
# ——不管前面加了幾組新樣本、少了幾組，這行永遠是實跑當下的真實數字。
count_log="$work/counts.log"
exec > >(tee "$count_log")

# ---- 合成 fixture repo：--repo 指到這裡，git grep 驗「測試名存在」用固定、可控的內容，不依賴真
#      LittleSprout 原始碼（真原始碼會隨其他票變動，讓自測結果漂移）。----
R="$work/repo"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$R/Fixture" "$R/FixtureTests"
git -C "$R" init -q -b main
cat > "$R/Fixture/FooTests.swift" <<'EOF'
import XCTest
final class FooTests: XCTestCase {
    func testBar() {
        XCTAssertTrue(true)
    }
}
EOF
# R2（merge-review R1 F1-1）：檔名與內部宣告型別不同名的檔案（真實案例 TimelineStoreVideoTests.swift
# 內部其實是 `extension TimelineStoreTests`）——這裡故意讓檔名 FixtureExtTests.swift 內部宣告的是
# `extension FooTests`，驗「檔名存在即算」（規則 2）獨立於「宣告存在即算」（規則 1）成立。
cat > "$R/Fixture/FixtureExtTests.swift" <<'EOF'
import XCTest
extension FooTests {
    func testExtra() {
        XCTAssertTrue(true)
    }
}
EOF
# R2（merge-review R1 F1-1）：目錄名（測試 target 名，如 LittleSproutTests）存在即算（規則 3）。
printf 'import XCTest\n' > "$R/FixtureTests/Placeholder.swift"

# R2（merge-review R1 N7）：兩個真實樣本（④a／④b）改對這份合成 fixture 跑，不再對真 LittleSprout
# repo 跑——耦合 8 個生產符號（SettingsViewIPadTests／TapTargetGateTests 等）會讓「日後任何一個改名」
# 就在無關 PR 上把 rules job 拉紅，訊息又難定位回 handoff-evidence-check。這裡建的是這兩份 comment
# 原文實際引用到的全部測試名稱／檔案的最小 stub（值與行為不重要，只要「存在」這件事成立）。
mkdir -p "$R/RealSampleFixture"
cat > "$R/RealSampleFixture/LegalDocumentSheetUITests.swift" <<'EOF'
import XCTest
final class LegalDocumentSheetUITests: XCTestCase {
    func testLegalDocumentSheet() {}
    func testLegalDocumentNarrowContainer() {}
}
EOF
cat > "$R/RealSampleFixture/LegalMarkdownDocumentTests.swift" <<'EOF'
import XCTest
final class LegalMarkdownDocumentTests: XCTestCase {}
EOF
cat > "$R/RealSampleFixture/LegalDocumentSheetLayoutTests.swift" <<'EOF'
import XCTest
final class LegalDocumentSheetLayoutTests: XCTestCase {}
EOF
cat > "$R/RealSampleFixture/SettingsViewIPadTests.swift" <<'EOF'
import XCTest
final class SettingsViewIPadTests: XCTestCase {
    func testProfileSectionEntryPushesAndBackReturns() {}
    func testSidebarSelectionIsAccessibleAndDistinguishable() {}
}
EOF
cat > "$R/RealSampleFixture/TapTargetGateTests.swift" <<'EOF'
import XCTest
final class TapTargetGateTests: XCTestCase {
    func testSettingsView() {}
    func testTimelineViewDefaultState() {}
    func testUploadQueueSheetView() {}
}
EOF
cat > "$R/RealSampleFixture/SettingsViewTests.swift" <<'EOF'
import XCTest
final class SettingsViewTests: XCTestCase {}
EOF

# R3（merge-review R2 i2）：.test.sh 內嵌的假型別宣告——存在性驗證須把這種自測 fixture 排除，
# 否則任何寫在 heredoc 裡的假名都會被 git grep 判定「存在」。必須在 `git add -A` 之前建立，否則
# 這個檔案根本沒進 git index，`git grep`／`git ls-files` 本來就看不到它，②h 那組樣本會因為錯誤的
# 理由通過（檔案沒追蹤，不是排除規則生效）。
cat > "$R/Fixture/fake.test.sh" <<'EOF'
#!/bin/bash
cat <<'INNER'
final class ExcludedFixtureOnlyTests: XCTestCase {}
INNER
EOF

# R4（LS-228，來源 LS-96 池項 acb4e2df）：白名單目錄路徑（PATH_ANCHOR_RE）的存在性驗證用 os.path.isfile
# 對 --repo 檔案系統直接檢查，不靠 git ls-files——這裡仍把 fixture 建在合成 repo 裡（同 R2/N7 的理由：
# 不耦合真 LittleSprout 路徑，未來 supabase/functions 底下任何檔案改名都不該讓這支自測連坐轉紅）。
mkdir -p "$R/supabase/functions/fixture" "$R/supabase/migrations" "$R/supabase/tests" "$R/docs/legal" "$R/.claude/agents" "$R/scripts/fixture" "$R/.github/workflows"
printf 'export const fixture = true;\n' > "$R/supabase/functions/fixture/example.ts"
printf -- '-- fixture migration\n' > "$R/supabase/migrations/20260101000000_fixture.sql"
printf -- '-- fixture test\n' > "$R/supabase/tests/00_fixture.sql"
printf '# Fixture doc\n' > "$R/docs/fixture.md"
printf '#!/bin/bash\necho fixture\n' > "$R/scripts/fixture/example.sh"
printf 'name: fixture\n' > "$R/.github/workflows/fixture.yml"
# R5（LS-228 R2，F2）：docs/**/*.md（巢狀子目錄）與 .claude/**/*.md 白名單路徑存在性驗證用 fixture。
printf '# Legal fixture\n' > "$R/docs/legal/fixture.md"
printf '# Agent fixture\n' > "$R/.claude/agents/fixture.md"
# R5（LS-228 R2，F1）：supabase/**/*.sh 白名單路徑——同時是 merge-review R1 F1(a) 點名的真實回歸樣本
# （規約必引的 `bash supabase/tests/run.sh`），這裡建一支同名真實存在的 fixture。
printf '#!/bin/bash\necho run\n' > "$R/supabase/tests/run.sh"

git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false add -A
git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m 'chore(harness): LS-211 fixture'

# R5（LS-228 R2，F5）：--repo 之外建一個真實存在的檔案，證明 `..` 逃逸不能拿它來蒙混存在性檢查——
# 這個檔案刻意留在 $work（$R 的上層目錄），不進 $R 的 git repo。
printf '#!/bin/bash\necho outside\n' > "$work/outside-escape.sh"

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

expect 0 '①g（R2，F3）merge-review verdict 骨架：標題含「查實」（如「逐條查實」）也算段落起點' '' \
'## Findings

問題描述在這裡，不算逐項證據段。

## 逐條查實

1. **範圍 1** ✓：`bash scripts/gates/foo.test.sh` 17 組全綠（實跑 exit 0）。
2. **範圍 2** ✓：`FooTests` 全綠，另見 `gh run view --job 123 --log` 核對 CI。
'

expect 0 '①h（R2，F1）.test.sh／gh run view／.xcresult 算證據' '' \
'## 已驗證
- 條件 1：`bash scripts/gates/foo.test.sh` 全綠
- 條件 2：`gh run view --job 123 --log` 核對
- 條件 3：`result.xcresult` 檔內測試皆通過
'

expect 0 '①i（R2，F1）檔名存在即算——檔內宣告型別與檔名不同名（真實案例：extension 檔）' '' \
'## 已驗證
- 條件 1：`FixtureExtTests` 全綠（見 Fixture/FixtureExtTests.swift，檔內實為 `extension FooTests`）
'

expect 0 '①j（R2，F1）目錄名（測試 target 名）→ 測試名存在性驗證通過' '' \
'## 已驗證
- 條件 1：`xcodebuild test -only-testing:FixtureTests` 全綠
'

expect 0 '①k（R2，F1）glob 形狀（緊鄰 *）不驗存在性——正確的「找不到這個東西」陳述' '' \
'## 已驗證
- 條件 1：本 feature 沒有獨立 `*NoSuchIPadTests` 類別，`FooTests` 已涵蓋
'

expect 0 '①l（R2，F1）同句含否定詞「沒有」不驗存在性——即使沒有 * 字面' '' \
'## 已驗證
- 條件 1：這裡沒有 NoSuchWeirdTests 這個類別，改用 `FooTests` 驗證
'

expect 0 '①m（R2，F1）mutation 語境的假名不驗存在性（ios-dev「每支 mutation 必列三段」硬規則不受影響）' '' \
'## 已驗證
- 條件 1：拿掉某條檢查 → mutation 樣本 `BogusMutationOnlyTests` 改判過，斷言原文：`✓ mutant → 紅`
'

expect 0 '①n（R3，m3；R5／LS-228 R2 還原 .sh/.md/.yml 後，PATH_RE 完整涵蓋 .py/.json 這兩個既有副檔名——.sh/.md/.yml 另見 ①x-①z）PATH_RE 認 .py/.json 路徑為證據' '' \
'## 已驗證
- 條件 1：核對過 `handoff_evidence_check.py:191` 的實作
- 條件 2：核對過 `some/config.json` 的內容
'

expect 0 '①o（R3，m4）verdict 圈號編號形狀（**① 標題**：…，無句點）不再 exit 2' '' \
'## 逐條查實

**① 範圍 1**：`FooTests` 全綠。

**② 範圍 2**：`bash scripts/gates/foo.test.sh` 全綠。
'

expect 0 '①p（R3，m4）全形數字編號（１.）也算列項起點' '' \
'## 已驗證
１. `FooTests` 全綠。
'

expect 0 '①q（R3，i3）否定詞在候選之後也跳過存在性（`FooBarTests` 這個類別不存在）' '' \
'## 已驗證
- 條件 1：`FooBarTests` 這個類別不存在，改用 `FooTests` 驗證
'

# R4（LS-228，來源 LS-96 池項 acb4e2df）：白名單目錄路徑（supabase/functions/**/*.ts、
# supabase/migrations/*.sql、supabase/tests/*.sql、docs/*.md、scripts/**/*.sh、
# .github/workflows/*.yml）——這批必須驗證檔案在合成 repo（$R）內真的存在（os.path.isfile），
# 不像 ①n 的 .py/.json 只是子字串比對。

expect 0 '①r（R4，LS-228）supabase/functions/**/*.ts 白名單路徑，存在' '' \
'## 已驗證
- 條件 1：`supabase/functions/fixture/example.ts:1` 核對通過
'

expect 0 '①s（R4，LS-228）supabase/migrations/*.sql 白名單路徑，存在' '' \
'## 已驗證
- 條件 1：`supabase/migrations/20260101000000_fixture.sql:1` 核對通過
'

expect 0 '①t（R4，LS-228）supabase/tests/*.sql 白名單路徑，存在' '' \
'## 已驗證
- 條件 1：`supabase/tests/00_fixture.sql:1` 核對通過
'

expect 0 '①u（R4，LS-228）docs/*.md 白名單路徑，存在' '' \
'## 已驗證
- 條件 1：`docs/fixture.md:1` 核對通過
'

expect 0 '①v（R4，LS-228）scripts/**/*.sh 白名單路徑，存在' '' \
'## 已驗證
- 條件 1：`scripts/fixture/example.sh:1` 核對通過
'

expect 0 '①w（R4，LS-228）.github/workflows/*.yml 白名單路徑，存在' '' \
'## 已驗證
- 條件 1：`.github/workflows/fixture.yml:1` 核對通過
'

# R5（LS-228 R2，F1；merge-review R1 43e2f60e）：PATH_RE 還原 .sh/.md/.yml 三個副檔名——①x/①y/①z
# 對應 F1 report 點名的三種真實回歸情境（規約必引的 bash supabase/tests/run.sh、根目錄 .yml、裸檔名
# .sh），這三個副檔名都不落在任何 PATH_ANCHOR_RE 白名單目錄前綴內，只能靠 PATH_RE 的無條件子字串放行。

expect 0 '①x（R5，LS-228 R2，F1(a)）本 repo 規約必引的「bash supabase/tests/run.sh」形狀，PATH_RE 的 .sh 放行' '' \
'## 已驗證
- 條件 1：跑了 `bash supabase/tests/run.sh` 全綠，連線方式：host psql
'

expect 0 '①y（R5，LS-228 R2，F1(b)）根目錄 .yml（project.yml），PATH_RE 的 .yml 放行' '' \
'## 已驗證
- 條件 1：核對過 `project.yml` 的內容
'

expect 0 '①z（R5，LS-228 R2，F1(c)）裸檔名 .sh（不在任何白名單目錄前綴下），PATH_RE 的 .sh 放行' '' \
'## 已驗證
- 條件 1：跑了 `db-reset-retry.sh` 全綠
'

# R5（LS-228 R2，F2）：docs/**/*.md（巢狀子目錄）與 .claude/**/*.md 兩個新白名單類別，皆驗證真的存在。

expect 0 '①aa（R5，LS-228 R2，F2）docs/**/*.md 巢狀子目錄白名單路徑，存在' '' \
'## 已驗證
- 條件 1：`docs/legal/fixture.md:1` 核對通過
'

expect 0 '①ab（R5，LS-228 R2，F2）.claude/**/*.md 白名單路徑，存在' '' \
'## 已驗證
- 條件 1：`.claude/agents/fixture.md:1` 核對通過
'

expect 0 '①ac（R5，LS-228 R2，F2）supabase/**/*.sh 白名單路徑（非 bash 前綴、直接引用），存在' '' \
'## 已驗證
- 條件 1：`supabase/tests/run.sh:1` 核對通過
'

# R5（LS-228 R2，F4）：path_anchor_candidates() 的 skip 判準補上 is_negated／is_mutation_context——
# 白名單路徑候選在同句含否定詞、或同行為 mutation 語境時不驗存在性（比照 (a) 測試名候選既有判準）。

expect 0 '①ad（R5，LS-228 R2，F4）白名單路徑候選同句含否定詞「不存在」→ 不驗存在性（正確的否定陳述）' '' \
'## 已驗證
- 條件 1：`supabase/migrations/20990101000000_x.sql` 這個檔不存在，gate 正確判紅
'

expect 0 '①ae（R5，LS-228 R2，F4）白名單路徑候選在 mutation 語境（同一行）→ 不驗存在性' '' \
'## 已驗證
- 條件 1：mutation 樣本 `supabase/tests/99_nonexistent_mutant.sql` → 紅
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

expect 1 '②f（R3，m1）mutation 語境縮小到候選所在那一行——同一列項內、不同行的假名仍須通過存在性驗證' '`BogusUnrelatedTests`' \
'## 已驗證
1. 條件 1：拿掉某條檢查 → mutation 樣本 `BogusMutationOnlyTests` 改判過，斷言原文：`✓ mutant → 紅`
   另外這裡也核對過 `BogusUnrelatedTests` 全綠（這個假名不該被連坐放行）。
'

expect 1 '②g（R3，i1）候選是既有檔名的後綴而非整字相等 → 不算存在（PadTests 不是 SettingsViewIPadTests.swift 的 basename）' '`PadTests`' \
'## 已驗證
- 條件 1：`PadTests` 全綠（實際檔名是 SettingsViewIPadTests.swift，PadTests 只是後綴、不是整字檔名）
'

expect 1 '②h（R3，i2）只出現在 .test.sh fixture heredoc 裡的假型別不算存在（排除自測 fixture 檔）' '`ExcludedFixtureOnlyTests`' \
'## 已驗證
- 條件 1：`ExcludedFixtureOnlyTests` 全綠
'

expect 1 '②i（R4，LS-228）supabase/migrations/*.sql 引用不存在的檔案 → 紅，訊息點名哪個路徑' '`supabase/migrations/20260101000000_does_not_exist.sql`' \
'## 已驗證
- 條件 1：`supabase/migrations/20260101000000_does_not_exist.sql:1` 核對通過
'

expect 1 '②j（R5，LS-228 R2，F1／F2 邊界示範改版：docs/ 目錄內指名一個不存在的檔案）(b2) 存在性檢查仍紅，即使 (b) 的 .md 無條件子字串已放行整列' '`docs/legal/does-not-exist-fixture.md`' \
'## 已驗證
- 條件 1：核對過 `docs/legal/does-not-exist-fixture.md` 的內容
'

expect 1 '②k（R5，LS-228 R2，F5）候選用 `..` 逃出 --repo——即使該路徑在 repo 外真的存在也判「找不到」' '`scripts/../../outside-escape.sh`' \
'## 已驗證
- 條件 1：核對過 `scripts/../../outside-escape.sh` 的內容
'

expect 1 '②l（R5，LS-228 R2，F1 新增類別）supabase/**/*.sh 白名單路徑引用不存在的檔案 → 紅，訊息點名哪個路徑' '`supabase/tests/does-not-exist.sh`' \
'## 已驗證
- 條件 1：核對過 `supabase/tests/does-not-exist.sh` 的內容
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
# R2（merge-review R1 N7）：對上面的 $R 合成 fixture 跑，不對真 LittleSprout repo 跑——真原始碼的
# 8 個生產符號（LegalDocumentSheetUITests／SettingsViewIPadTests 等）任何一個未來被改名，都會讓
# rules job 在無關 PR 上轉紅、訊息難定位回這支檔案；fixture 內已建好這兩份 comment 原文引用到的
# 全部測試名稱／檔案的最小 stub（見上方 RealSampleFixture），行為與真實情況一致，只是不耦合真檔名。
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
- **Pencil MCP 逐板像素比對未執行**：`bash scripts/ops/pen-read.sh` 對 qa-test worktree 回 **exit 1（fail-closed）**——主 checkout `/Users/clyeh/little-sprout` 與另一 worktree `LS-192` 目前開著的 `.pen` 與磁碟版本有結構性差異（48 節點刪除／8 新增／上百筆 y／descendants 變更），方向不明，安全判定拒絕清場；QA 白名單不含清場權限，未強行 `--kill` 或 `pen-land`。以此判定不得對可能陳舊的文件做 Pencil MCP 視覺驗收，改以（a）4 輪 merge-review 已對 Notes 數字（520/87.5/345/24/272/無 grabber）逐一核對、與（b）本輪我自己在這個確切 test-tip build 上的獨立像素量測（見第 5 條，數字精確吻合）作為設計符合度證據。此為工具可用性缺口，非程式碼缺陷，建議 orchestrator 之後視需要另行安排 Pencil MCP 對板複驗。

**風險**：無。無 migration、無執行期並發變更、無 breaking API 變更。

**已關模擬器**：`5F59FF04-D2C6-413D-B31A-AFD39B257FB3`（qa-test-iPhone17Pro）、`F72DBCD1-9CBE-4903-AE6E-241064C391E1`（qa-test-iPadAir11M3，本輪新建）——皆已 `simctl shutdown`；`LS-192-iPhone17Pro` 為其他 agent 所有，未動。iPhone 專屬機 `content_size`/`appearance` 已於收工前復原為 `large`/`light`（本輪唯一手動變更過的機台）；iPad 專屬機全程未變更（`unknown`/`unknown`＝新機預設）。

**runtime 註記**：兩台專屬機皆 iOS 26.0（`.ios-runtime` 釘 26.2，本機無該 runtime 可用；`detect-simulator.sh` fail-open 印警告）——量測皆為 view frame 幾何與像素邊界偵測，餘裕遠高於門檻（footer ≥48pt 門檻 vs 實測 53–80pt），不受此差異影響。

證據：`/private/tmp/claude-501/-Users-clyeh-little-sprout/e6972486-fec6-43c0-b8f4-28b43b01a5a0/scratchpad/LS-191-qa-*.{log,png}`（iphone-tests.log／ipad-tests.log／ipad-settingstests.log／settingsviewtests.log／tap-target-check.log／iphone-light.png／iphone-dark.png／ax3-*.png／ipad-full.png／ipad-check.png）。
REALSAMPLE1

out_real1="$(bash "$check" "$work/ls191-c541cd06.md" --repo "$R" 2>&1)"; rc_real1=$?
# R2（merge-review R1 F2）：不只斷 rc==1——斷「哪一行、什麼原因」的具體 finding 訊息原文，且斷言
# 「只有這一條」（不再誤判第 15 行「沒有獨立 `*IPadTests` 類別」這句正確的否定陳述，R1 F1(b)）。
if [ "$rc_real1" -eq 1 ] \
   && printf '%s' "$out_real1" | grep -qF '✗ handoff-evidence-check：第 11 行起的列項缺『怎麼驗』證據' \
   && ! printf '%s' "$out_real1" | grep -qF 'IPadTests'; then
  echo "✓ ④a 真實樣本 LS-191 QA comment c541cd06 → exit 1，斷言訊息原文確實是「第 11 行起的列項缺『怎麼驗』證據」（項 3「iPhone 標準字級」），且不再誤判第 15 行 IPadTests 否定句（R1 F1(b) 已修）"
else
  echo "✗ ④a 真實樣本 c541cd06 應紅在第 11 行、且不含 IPadTests 誤判（期望 exit 1，實得 ${rc_real1}）" >&2
  printf '%s\n' "$out_real1" | sed 's/^/    /' >&2
  fail=1
fi

# ==== ④a-mut（R2，merge-review R1 F2）：反向 mutation——has_evidence() 恆真 → 上面 ④a 的判斷依據必須
#        真的翻轉（原本紅在「缺證據」，恆真後那條红必須消失），證明④a 斷的是真的規則，不是巧合撐出來
#        （F2 原話：拿掉 has_evidence 整條規則，舊版④a 只斷 rc==1，仍然「通過」，因為另一條誤判撐住了
#        exit 1；R1 F1 修好誤判後，這裡必須驗證新版④a 真的會因為規則被拿掉而發現不對）====
mut_he="$work/handoff_evidence_check.has-evidence-true.py"
awk '
  index($0, "# HANDOFF-MISSING-EVIDENCE-CHECK") > 0 { print "        missing_evidence = False  # HANDOFF-MISSING-EVIDENCE-CHECK"; next }
  { print }
' "$py" > "$mut_he"
if grep -qF 'missing_evidence = False  # HANDOFF-MISSING-EVIDENCE-CHECK' "$mut_he"; then
  echo "✓ ④a-mut：確認已把 has_evidence() 的判斷結果恆改為 False（等同恆真通過）"
  out_he="$(python3 "$mut_he" "$work/ls191-c541cd06.md" --repo "$R" 2>&1)"; rc_he=$?
  if [ "$rc_he" -eq 0 ]; then
    echo "✓ ④a-mut（拿掉 has_evidence 規則）：c541cd06 樣本改判 exit 0（原第 11 行的紅消失）——證明④a 斷的『第 11 行缺證據』訊息確實是 has_evidence() 這條規則造成的，不是巧合"
  else
    echo "✗ ④a-mut 未如預期翻轉為 exit 0（實得 exit ${rc_he}，代表還有其他規則在撐住紅、④a 仍可能零鑑別力）" >&2
    printf '%s\n' "$out_he" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ④a-mut：找不到 HANDOFF-MISSING-EVIDENCE-CHECK 標記，負控本身無效" >&2
  fail=1
fi

# R2（merge-review R1 N7）：改用完整逐字原文（58 行），不再是節錄版（原 R1 只內嵌 44 行）——
# 「直接在本檔內嵌真實 comment 原文」這句話現在名符其實；reviewer 已用完整原文重跑過驗證行為一致
# （exit 0，行號 12/16/20/24/28/34/40 與 handoff 引用相符，此處因改回完整原文行號會不同，故下面
# 只斷言 exit code，不斷特定行號）。
cat > "$work/ls192-88fb24bc.md" <<'REALSAMPLE2'
**QA（09-06 08:51）**：**PASS**。test tip `b5f87b9`（＝origin/test，checkout 於 `.claude/worktrees/qa-test`）。逐條獨立重驗（未照抄 merge-review 結論，兩帳號／多家庭真後端 E2E＋backend 查表核對），證據存 `/private/tmp/claude-501/-Users-clyeh-little-sprout/e6972486-fec6-43c0-b8f4-28b43b01a5a0/scratchpad/LS-192-qa-*.png`。

## 自動測試

- `xcodebuild test -only-testing:LittleSproutTests`（`qa-test-iPhone17Pro` 5F59FF04，iOS 26.0）→ **723 tests, 0 failures**，`** TEST SUCCEEDED **`。
- `xcodebuild test -only-testing:LittleSproutUITests/TapTargetGateTests -only-testing:LittleSproutUITests/FamilyMembersLeaveFlowUITests` → **19 tests, 0 failures**（含 `testFamilyMembersView`／`testProfileEditView`／兩支新 `FamilyMembersLeaveFlowUITests` 全綠）。log：`LS-192-qa-uitests-iphone.log`。
- `xcodebuild test -only-testing:LittleSproutUITests/SettingsViewIPadTests`（`qa-test-iPadAir11M3` F72DBCD1，iOS 26.0）→ **6 tests, 0 failures**。log：`LS-192-qa-uitests-ipad.log`。
- `git diff 6a5db27..b5f87b9 --stat`：34 檔，**無 migration、無 `design/*.pen` 變更**。

## 逐條驗收

**1. 02 編輯顯示名稱與頭像 —— ✓**
怎麼驗：登入 `ls192-owner2` → 設定 →「個人資料」。對稿：標題「個人資料」、副標「編輯你的顯示名稱與頭像，家人都會看到。」、88×88 圓形頭像＋28×28 相機 badge＋「換張照片」、help 文案「家人在時間軸與相簿裡會看到這個名字。」——與 `design/littlesprout.pen` `MohS1` 節點文字逐字核對相符。改名「陳二號」→「陳二號改名」儲存後：設定頁「個人」列即時顯示新名（`LS-192-qa-02-namechange-settings.png`）、家庭成員列同步更新（`LS-192-qa-03-*` 系列）；backend `profiles.display_name` 查表核對一致。頭像：`simctl addmedia` 餵圖 → PhotosPicker 選圖 → 儲存後 Storage 路徑 `{family_id}/avatars/{user_id}.jpg` 正確落地（backend 查表核對），ProfileEditView 與家庭成員列即時顯示新圖。AX3（長名字「李王美麗美惠子」）不破版（`LS-192-qa-02-ax3.png`）。深色一張（`LS-192-qa-02-dark.png`）版面正常。
证据：`LS-192-qa-02-profile-light.png`／`-02-dark.png`／`-02-ax3.png`／`-02-namechange-settings.png`。

**2. 03 家庭成員管理 —— ✓**
怎麼驗：owner（`ls192-owner`/`owner2`/`owner3`）與 member（`ls192-member2`）分別登入查看列表。Owner 視角：全部成員＋Role Pill（`crown`＝「家庭管理者」、`person`＝「一般成員」）皆正確渲染（非純文字，有 capsule 容器＋icon）、自己列無 chevron／動作按鈕、他人列有 44×44 動作按鈕（`陳一成員的動作`）觸發 Menu（「轉移家庭管理者」「移出成員」，紅字危險動作）。Member 視角（`LS-192-qa-03-member-view.png`）：兩列皆無 chevron／動作入口，僅「退出家庭」可用——差異符合預期。AX3 長名字壓測（`李王美麗美惠子`）：名字與 Role Pill 正確換行、無截斷無溢出、列高隨字級增高（`LS-192-qa-03-ax3-longname.png`）。iPad：`SettingsViewIPadTests` 6 支自動測試綠（含 `testProfileSectionEntryPushesAndBackReturns`／`testSidebarSelectionIsAccessibleAndDistinguishable`），互動式截圖因 mobile-mcp WDA 對這台 iPad 模擬器連線逾時（`timed out waiting for WebDriverAgent to be ready`，非本票程式問題）未能取得，僅有靜態 launch 截圖（`LS-192-qa-ipad-launch2.png`，welcome 頁面版式正常）；**已知未解 iPad split 版式（`yJvj7`）維持 LS-188 既有殼、記 LS-96 `5956c39c`**——依 orchestrator 09-06 06:37 裁決與 R3 查實，QA 確認現況可用、非本輪 FAIL 項，供使用者知悉。
证据：`LS-192-qa-03-owner-view.png`／`-03-member-view.png`／`-03-dark.png`／`-03-ax3-longname.png`／`-ipad-launch2.png`。

**3. 03b 移除成員確認 —— ✓**
怎麼驗：owner1 對 member1 執行移出。確認 sheet 文案逐字對稿：「要把「陳一成員」移出「陳家A」嗎？」／「移出後，他將無法再看到這個家庭的相片、影片與日記。他自己上傳的內容會保留在家庭裡，除非你另外刪除。」（含關鍵句「內容會保留」，M6 修正項）。確認後：列表即時少一列（1 位家人）、backend `family_members` 查表核對確實少一列（`{"user_id":"...","role":"owner"}` 僅剩 owner）。
证据：`LS-192-qa-03b-remove-confirm.png`／`-03-after-remove.png`。

**4. 03c 轉移家庭管理者 —— ✓**
怎麼驗：owner3 對 member3 執行轉移。確認 sheet 文案逐字對稿：「要把家庭管理者身分交給「陳三成員」嗎？」／「轉移後，陳三成員可以管理家庭成員與內容、處理檢舉；你會變成一般成員，仍能繼續使用這個家庭、看到所有照片與日記。」。確認後：列表**即時**對調兩人 Role Pill 並重排（新 owner 排到最前），原 owner 出現「退出家庭」可用（無 chevron，非管理者視角）；backend `family_members` 查表核對角色互換（`d76ecf0a`→owner、`f151ee44`→member）。
证据：`LS-192-qa-03c-transfer-confirm.png`／`-03-after-transfer.png`。

**5. 退出家庭三態（真後端、雙帳號＋多帳號）—— ✓（三態全驗）**
- (a) 一般成員退出：member2（從未當過 owner）與轉移後的 owner3（現為 member）分別執行 03d → 文案逐字對稿「要退出「陳家X」嗎？」／「退出後，你將無法再看到這個家庭的相片、影片與日記，除非有人重新邀請你。你自己上傳的內容會保留在家庭裡。」→ 確認後成功回三岔路頁（LS-18，`LS-192-qa-post-leave-threefork.png`）；backend 查表核對 `family_members` 少一列。
- (b) 管理者且有其他成員：owner3（家庭 C，member3 仍在）點「退出家庭」→ 03e mustTransferFirst 變體，文案逐字對稿「需要先轉移家庭管理者身分」／「你是「陳家C」唯一的家庭管理者，家裡還有 1 位家人。退出之前，請先把家庭管理者身分交給其中一位。」＋「前往轉移」導回家庭成員列表（可從那裡的動作選單完成轉移，已於 4. 實測完成整個轉移動作）。
- (c) 管理者獨自一人：owner1（family A，先移除 member1 後只剩自己）點「退出家庭」→ **03e 單人變體**，文案**逐字一致**（含全形箭頭與兩組直角引號）：「目前家庭只有你一位成員，無法退出家庭。若要離開，請至「帳號」→「刪除帳號」。」；無 Families Card／無「前往轉移」，只有「返回設定」；**無網路請求**——`docker logs supabase_kong_little-sprout --since 2m` 核對，點擊「退出家庭」前後**無任何** `DELETE /rest/v1/family_members` 或其他請求打進來（前一次 DELETE 是 03b 移除成員的請求，時間戳早於本次點擊）。**已知未解**：「返回設定」只 pop 一層回「家庭成員」（非 Settings 根），記 LS-96 `ee768c94`——已實測確認行為與描述一致，不算 FAIL。
证据：`LS-192-qa-03d-leave-confirm.png`／`-03e-musttransfer.png`／`-03e-solemember.png`／`-post-leave-threefork.png`。

**6. 錯誤路徑 —— ✓（部分經真後端觸發，部分經 code review 確認映射）**
- LS057（owner 有其他成員時嘗試退出）：獨立以 HTTP DELETE 重現（`{"code":"LS057",...}`），並在 UI 上實際點擊觸發同一路徑，確認文案分流正確（見 5-b）。
- LS001（唯一 owner 唯一成員直接 DELETE）：獨立建一次性帳號用 HTTP 重現仍回 LS001（`家庭 ... 必須至少保留一位 owner`），但**已確認 UI 層 `.soleMember` 分支根本不會送出這個請求**（見 5-c 的 kong log 核對）——LS001 對這條路徑而言已是防禦性、不可觸發的分支，與 R3 handoff 一致。
- LS058／LS059／LS060（非 owner 轉移／目標非成員／轉給自己）：`FamilyMemberActionVisibility.swift:89-100` code review 確認 `familyMemberActionMessage` 對五碼皆有專屬文案（非 R1 的泛用句「無法完成這個操作」），與 API.md §4 契約碼一致；未逐一用真併發觸發（需要精準時序賽跑），採程式碼審查＋既有 mutation testing（R2/R3 已用 mutation 證明分流邏輯真的被測試覆蓋）作為驗證依據。
- 斷網情境（"不卡 spinner"）：**⊘ 未實機驗證**——本機環境無法乾淨模擬網路中斷（會影響共用 Supabase 容器其他使用者）。改以 code review 確認：`FamilyStore+Members.swift` 四個動作（`removeMember`／`transferOwnership`／`updateDisplayName`／`updateAvatar`）皆 `guard !isSubmitting` → `.submitting` → `try/catch` → 失敗必落 `.failure(AppError.map(error))`，沒有任何路徑會停在 `.submitting` 不轉換；此為靜態程式碼保證，非動態網路中斷實測，如實記錄不算 PASS 的完整證據。

**7. 回歸 —— ✓**
- `git diff 6a5db27..b5f87b9 --stat`：34 檔皆屬 LS-192 範圍（`Features/Settings/*`／`Services/Family/*`／測試／pbxproj／`tap-target-exemptions.txt`），無 migration、無 `.pen`。
- LS-188 設定頁其他區（封鎖名單／檢舉紀錄／儲存空間／使用條款／隱私權政策／登出／刪除帳號）於多次導覽中維持正常渲染，無破版；`SettingsView.swift` 的 diff 只碰 `profileSection`／`familySection`（新增 `.task(id:)` 補查與傳參數），法律區塊程式碼未變動。
- `TapTargetGateTests` 全量 17 支（含既有 `testSettingsView`／`testTimelineViewDefaultState`／`testUploadQueueSheetView` 等既有畫面）0 failures，證明本票沒有波及既有畫面的 tap-target。

## 未驗與原因

- iPad 互動式截圖（`FamilyMembersView`／03b-e）：mobile-mcp 對 `qa-test-iPadAir11M3` WDA 連線逾時，改採自動測試（6/6 綠）＋靜態 launch 截圖佐證版式無破版。
- LS058／LS059／LS060 真併發觸發：需要精準時序賽跑（兩個 client 同時操作），本輪以 code review＋既有 mutation coverage 替代。
- 斷網 spinner：本機共用環境無法安全模擬，以 code review（`isSubmitting`／`catch` 狀態機）替代，記為 ⊘。

以上兩項⊘不影響 PASS 裁決——皆非本票新增風險，且已有等效證據（自動測試／程式碼審查）佐證正確性；已知未解的 03e 返回層級與 iPad split 版式兩項也已在 merge-review R3／orchestrator 裁決中記入 LS-96，QA 重驗結果與申報一致。

## 環境

- 模擬器已關：`5F59FF04-D2C6-413D-B31A-AFD39B257FB3`（qa-test-iPhone17Pro）、`F72DBCD1-9CBE-4903-AE6E-241064C391E1`（qa-test-iPadAir11M3）。
- lock 已釋放：「LS-192 QA 冒煙」（持有 37 分 57 秒）。
- 測試資料已清乾淨（6 帳號＋1 一次性帳號、4 個測試家庭，`delete from families where name like '陳家%'` + `delete from auth.users where email like 'ls192-%@ls.test'`，皆在 `supabase-lock.sh --` 內執行）。
- Pen 路徑：本票無 `.pen` 變更，僅離線讀 `design/littlesprout.pen`（明文 JSON）核對節點 `MohS1`／`hVAq3`／`gjCoe`／`yJvj7`／`yMNOt`／`p8GUvZ`／`ANIpL`／`sF5oA` 文字內容，未使用 Pencil MCP。
REALSAMPLE2

out_real2="$(bash "$check" "$work/ls192-88fb24bc.md" --repo "$R" 2>&1)"; rc_real2=$?
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
if awk '
  index($0, "# HANDOFF-BADNAMES-CHECK") > 0 { print "        bad_names = []  # HANDOFF-BADNAMES-CHECK"; next }
  { print }
' "$py" > "$mutant" && grep -q 'bad_names = \[\]  # HANDOFF-BADNAMES-CHECK' "$mutant"; then
  bogus_body='## 已驗證
- 條件 1：`BogusTests` 全綠
'
  printf '%s' "$bogus_body" > "$work/bogus.md"
  out_mut="$(python3 "$mutant" "$work/bogus.md" --repo "$R" 2>&1)"; rc_mut=$?
  if [ "$rc_mut" -eq 0 ]; then
    echo "✓ ⑤ mutant（拿掉『測試名存在』檢查）：假測試名樣本改判綠——證明②b 的紅是這條檢查造成的"
  else
    echo "✗ ⑤ mutant 未如預期翻轉（實得 exit ${rc_mut}）" >&2
    printf '%s\n' "$out_mut" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ⑤ mutate：找不到 HANDOFF-BADNAMES-CHECK 標記，負控本身無效" >&2
  fail=1
fi

# ==== ⑥（R2，F1）mutation 負控：拿掉 glob／否定詞／mutation 語境的跳過判準（skip 恆 False）→
#        ①k／①l／①m 的正樣本必須改判紅，證明「跳過驗存在性」是這幾個判準造成的 ====
mut_skip="$work/handoff_evidence_check.no-skip.py"
awk '
  index($0, "# HANDOFF-SKIP-CHECK") > 0 { print "        skip = False  # HANDOFF-SKIP-CHECK"; next }
  { print }
' "$py" > "$mut_skip"
if grep -qF 'skip = False  # HANDOFF-SKIP-CHECK' "$mut_skip"; then
  echo "✓ ⑥ mutate：確認已把 glob／否定詞／mutation 語境判準恆改為 False（等於一律不跳過驗存在性）"
  glob_body='## 已驗證
- 條件 1：本 feature 沒有獨立 `*NoSuchIPadTests` 類別，`FooTests` 已涵蓋
'
  printf '%s' "$glob_body" > "$work/glob.md"
  out_glob="$(python3 "$mut_skip" "$work/glob.md" --repo "$R" 2>&1)"; rc_glob=$?
  if [ "$rc_glob" -eq 1 ] && printf '%s' "$out_glob" | grep -qF 'NoSuchIPadTests'; then
    echo "✓ ⑥ mutant（拿掉 glob 跳過）：①k 的正樣本改判紅（NoSuchIPadTests 被當成引用驗存在）——證明 glob 判準是原因"
  else
    echo "✗ ⑥ mutant（glob）未如預期翻轉（實得 exit ${rc_glob}）" >&2
    printf '%s\n' "$out_glob" | sed 's/^/    /' >&2
    fail=1
  fi

  neg_body='## 已驗證
- 條件 1：這裡沒有 NoSuchWeirdTests 這個類別，改用 `FooTests` 驗證
'
  printf '%s' "$neg_body" > "$work/neg.md"
  out_neg="$(python3 "$mut_skip" "$work/neg.md" --repo "$R" 2>&1)"; rc_neg=$?
  if [ "$rc_neg" -eq 1 ] && printf '%s' "$out_neg" | grep -qF 'NoSuchWeirdTests'; then
    echo "✓ ⑥ mutant（拿掉否定詞跳過）：①l 的正樣本改判紅——證明否定詞判準是原因"
  else
    echo "✗ ⑥ mutant（否定詞）未如預期翻轉（實得 exit ${rc_neg}）" >&2
    printf '%s\n' "$out_neg" | sed 's/^/    /' >&2
    fail=1
  fi

  mut_ctx_body='## 已驗證
- 條件 1：拿掉某條檢查 → mutation 樣本 `BogusMutationOnlyTests` 改判過，斷言原文：`✓ mutant → 紅`
'
  printf '%s' "$mut_ctx_body" > "$work/mutctx.md"
  out_mutctx="$(python3 "$mut_skip" "$work/mutctx.md" --repo "$R" 2>&1)"; rc_mutctx=$?
  if [ "$rc_mutctx" -eq 1 ] && printf '%s' "$out_mutctx" | grep -qF 'BogusMutationOnlyTests'; then
    echo "✓ ⑥ mutant（拿掉 mutation 語境跳過）：①m 的正樣本改判紅——證明 mutation 語境判準是原因"
  else
    echo "✗ ⑥ mutant（mutation 語境）未如預期翻轉（實得 exit ${rc_mutctx}）" >&2
    printf '%s\n' "$out_mutctx" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ⑥ mutate：找不到 HANDOFF-SKIP-CHECK 標記，負控本身無效" >&2
  fail=1
fi

# ==== ⑦（R3，m4）mutation：NUMBERED_ITEM_RE 退回只認 ASCII 數字＋句點 → ①o（圈號）與 ①p（全形數字）
#        的正樣本必須改判 exit 2（找不到列項），證明是這行放寬的規則造成的 ====
mut_num="$work/handoff_evidence_check.ascii-only-numbered.py"
awk '
  index($0, "# HANDOFF-NUMBERED-ITEM") > 0 { print "NUMBERED_ITEM_RE = re.compile(r\"^\\*{0,2}[0-9]+\\.\\s+\")  # HANDOFF-NUMBERED-ITEM"; next }
  { print }
' "$py" > "$mut_num"
if grep -qF 'NUMBERED_ITEM_RE = re.compile(r"^\*{0,2}[0-9]+\.\s+")  # HANDOFF-NUMBERED-ITEM' "$mut_num"; then
  echo "✓ ⑦ mutate：確認已把 NUMBERED_ITEM_RE 退回只認 ASCII 數字＋句點"
  printf '%s' '## 逐條查實

**① 範圍 1**：`FooTests` 全綠。
' > "$work/circled.md"
  out_circled="$(python3 "$mut_num" "$work/circled.md" --repo "$R" 2>&1)"; rc_circled=$?
  if [ "$rc_circled" -eq 2 ]; then
    echo "✓ ⑦ mutant（退回 ASCII-only）：①o 的圈號樣本改判 exit 2（找不到列項）——證明圈號規則是原因"
  else
    echo "✗ ⑦ mutant 未如預期翻轉為 exit 2（實得 exit ${rc_circled}）" >&2
    printf '%s\n' "$out_circled" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ⑦ mutate：找不到 HANDOFF-NUMBERED-ITEM 標記，負控本身無效" >&2
  fail=1
fi

# ==== ⑧（R3，m3；R4／LS-228 縮小為 .py/.json）mutation：PATH_RE 拿掉 .py/.json → ①n 的正樣本必須改判紅
#        （.sh/.md/.yml 已在 R4 移出 PATH_RE，改由 ⑬ 驗證 PATH_ANCHOR_RE 那條路） ====
mut_path="$work/handoff_evidence_check.no-new-path-ext.py"
awk '
  index($0, "# HANDOFF-EVIDENCE-PATH") > 0 { print "PATH_RE = re.compile(r\"\\.png|\\.log|\\.test\\.sh|scratchpad/|evidence/|\\.swift\\b\")  # HANDOFF-EVIDENCE-PATH"; next }
  { print }
' "$py" > "$mut_path"
if grep -qF 'PATH_RE = re.compile(r"\.png|\.log|\.test\.sh|scratchpad/|evidence/|\.swift\b")  # HANDOFF-EVIDENCE-PATH' "$mut_path"; then
  echo "✓ ⑧ mutate：確認已把 PATH_RE 拿掉 .py/.json"
  printf '%s' '## 已驗證
- 條件 1：核對過 `some/config.json` 的內容
' > "$work/pathext.md"
  out_pathext="$(python3 "$mut_path" "$work/pathext.md" --repo "$R" 2>&1)"; rc_pathext=$?
  if [ "$rc_pathext" -eq 1 ] && printf '%s' "$out_pathext" | grep -qF '缺『怎麼驗』證據'; then
    echo "✓ ⑧ mutant（拿掉新路徑副檔名）：①n 型樣本改判紅——證明是這幾個副檔名在放行"
  else
    echo "✗ ⑧ mutant 未如預期翻轉（實得 exit ${rc_pathext}）" >&2
    printf '%s\n' "$out_pathext" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ⑧ mutate：找不到 HANDOFF-EVIDENCE-PATH 標記，負控本身無效" >&2
  fail=1
fi

# ==== ⑨（R3，i1）mutation：basename 整字相等退回「後綴即算」→ ②g 的負樣本（PadTests）必須改判過 ====
mut_suffix="$work/handoff_evidence_check.suffix-match.py"
awk '
  index($0, "# HANDOFF-BASENAME-EQ") > 0 { print "        if relpath.split(\"/\")[-1].endswith(target):  # HANDOFF-BASENAME-EQ"; next }
  { print }
' "$py" > "$mut_suffix"
if grep -qF 'if relpath.split("/")[-1].endswith(target):  # HANDOFF-BASENAME-EQ' "$mut_suffix"; then
  echo "✓ ⑨ mutate：確認已把 basename 整字相等退回「後綴即算」"
  printf '%s' '## 已驗證
- 條件 1：`PadTests` 全綠
' > "$work/padtests.md"
  out_padtests="$(python3 "$mut_suffix" "$work/padtests.md" --repo "$R" 2>&1)"; rc_padtests=$?
  if [ "$rc_padtests" -eq 0 ]; then
    echo "✓ ⑨ mutant（basename 退回後綴比對）：②g 的負樣本（PadTests）改判過——證明整字相等判準是原因"
  else
    echo "✗ ⑨ mutant 未如預期翻轉（實得 exit ${rc_padtests}）" >&2
    printf '%s\n' "$out_padtests" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ⑨ mutate：找不到 HANDOFF-BASENAME-EQ 標記，負控本身無效" >&2
  fail=1
fi

# ==== ⑩（R3，i2）mutation：拿掉 .test.sh／.test.js 排除 → ②h 的負樣本（ExcludedFixtureOnlyTests）必須改判過 ====
mut_noexclude="$work/handoff_evidence_check.no-grep-exclude.py"
awk '
  index($0, "# HANDOFF-GREP-EXCLUDE") > 0 { print "        proc = subprocess.run([\"git\", \"-C\", repo, \"grep\", \"-q\", \"-P\", pattern], capture_output=True)  # HANDOFF-GREP-EXCLUDE"; next }
  { print }
' "$py" > "$mut_noexclude"
if grep -qF 'proc = subprocess.run(["git", "-C", repo, "grep", "-q", "-P", pattern], capture_output=True)  # HANDOFF-GREP-EXCLUDE' "$mut_noexclude"; then
  echo "✓ ⑩ mutate：確認已拿掉 .test.sh／.test.js 排除"
  printf '%s' '## 已驗證
- 條件 1：`ExcludedFixtureOnlyTests` 全綠
' > "$work/excluded.md"
  out_excluded="$(python3 "$mut_noexclude" "$work/excluded.md" --repo "$R" 2>&1)"; rc_excluded=$?
  if [ "$rc_excluded" -eq 0 ]; then
    echo "✓ ⑩ mutant（拿掉 .test.sh 排除）：②h 的負樣本（ExcludedFixtureOnlyTests）改判過——證明排除規則是原因"
  else
    echo "✗ ⑩ mutant 未如預期翻轉（實得 exit ${rc_excluded}）" >&2
    printf '%s\n' "$out_excluded" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ⑩ mutate：找不到 HANDOFF-GREP-EXCLUDE 標記，負控本身無效" >&2
  fail=1
fi

# ==== ⑪（R3，i3）mutation：否定詞子句退回只看候選之前 → ①q 的正樣本（否定詞在候選之後）必須改判紅 ====
mut_negafter="$work/handoff_evidence_check.negation-before-only.py"
awk '
  index($0, "# HANDOFF-NEGATION-AFTER") > 0 { print "    clause_end = start  # HANDOFF-NEGATION-AFTER"; next }
  { print }
' "$py" > "$mut_negafter"
if grep -qF 'clause_end = start  # HANDOFF-NEGATION-AFTER' "$mut_negafter"; then
  echo "✓ ⑪ mutate：確認已把否定詞子句退回只看候選之前"
  printf '%s' '## 已驗證
- 條件 1：`FooBarTests` 這個類別不存在，改用 `FooTests` 驗證
' > "$work/negafter.md"
  out_negafter="$(python3 "$mut_negafter" "$work/negafter.md" --repo "$R" 2>&1)"; rc_negafter=$?
  if [ "$rc_negafter" -eq 1 ] && printf '%s' "$out_negafter" | grep -qF 'FooBarTests'; then
    echo "✓ ⑪ mutant（否定詞只看之前）：①q 的正樣本改判紅（FooBarTests 被當成引用）——證明「候選之後」判準是原因"
  else
    echo "✗ ⑪ mutant 未如預期翻轉（實得 exit ${rc_negafter}）" >&2
    printf '%s\n' "$out_negafter" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ⑪ mutate：找不到 HANDOFF-NEGATION-AFTER 標記，負控本身無效" >&2
  fail=1
fi

# ==== ⑫（R4，LS-228）mutation 負控：拿掉白名單路徑存在性驗證 → ②i 的負樣本（不存在的 .sql 路徑）
#        必須改判過，證明②i 的紅是 HANDOFF-PATH-EXISTS 這條檢查造成的 ====
mut_pathexists="$work/handoff_evidence_check.no-path-exists.py"
awk '
  index($0, "# HANDOFF-PATH-EXISTS") > 0 { print "        bad_paths = []  # HANDOFF-PATH-EXISTS"; next }
  { print }
' "$py" > "$mut_pathexists"
if grep -qF 'bad_paths = []  # HANDOFF-PATH-EXISTS' "$mut_pathexists"; then
  echo "✓ ⑫ mutate：確認已把白名單路徑存在性驗證恆改為空（等同一律判定存在）"
  missing_sql_body='## 已驗證
- 條件 1：`supabase/migrations/20260101000000_does_not_exist.sql:1` 核對通過
'
  printf '%s' "$missing_sql_body" > "$work/missingsql.md"
  out_missingsql="$(python3 "$mut_pathexists" "$work/missingsql.md" --repo "$R" 2>&1)"; rc_missingsql=$?
  if [ "$rc_missingsql" -eq 0 ]; then
    echo "✓ ⑫ mutant（拿掉白名單路徑存在性驗證）：②i 的負樣本（不存在的 .sql 路徑）改判過——證明 HANDOFF-PATH-EXISTS 是原因"
  else
    echo "✗ ⑫ mutant 未如預期翻轉（實得 exit ${rc_missingsql}）" >&2
    printf '%s\n' "$out_missingsql" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ⑫ mutate：找不到 HANDOFF-PATH-EXISTS 標記，負控本身無效" >&2
  fail=1
fi

# ==== ⑬（R4，LS-228）mutation 負控：has_evidence() 拿掉 PATH_ANCHOR_RE 判斷 → 只靠白名單路徑舉證的
#        正樣本（①r）必須改判紅，證明白名單路徑舉證確實是這條規則造成的 ====
mut_noanchor="$work/handoff_evidence_check.no-anchor-evidence.py"
awk '
  index($0, "# HANDOFF-HAS-EVIDENCE-PATH-ANCHOR") > 0 { print "    return bool(TEST_NAME_RE.search(text) or PATH_RE.search(text) or COMMAND_RE.search(text))  # HANDOFF-HAS-EVIDENCE-PATH-ANCHOR"; next }
  { print }
' "$py" > "$mut_noanchor"
if grep -qF 'return bool(TEST_NAME_RE.search(text) or PATH_RE.search(text) or COMMAND_RE.search(text))  # HANDOFF-HAS-EVIDENCE-PATH-ANCHOR' "$mut_noanchor"; then
  echo "✓ ⑬ mutate：確認已把 has_evidence() 的 PATH_ANCHOR_RE 判斷拿掉"
  ts_only_body='## 已驗證
- 條件 1：`supabase/functions/fixture/example.ts:1` 核對通過
'
  printf '%s' "$ts_only_body" > "$work/tsonly.md"
  out_tsonly="$(python3 "$mut_noanchor" "$work/tsonly.md" --repo "$R" 2>&1)"; rc_tsonly=$?
  if [ "$rc_tsonly" -eq 1 ] && printf '%s' "$out_tsonly" | grep -qF '缺『怎麼驗』證據'; then
    echo "✓ ⑬ mutant（拿掉 PATH_ANCHOR_RE 舉證）：①r 型樣本改判紅——證明白名單路徑舉證確實是 PATH_ANCHOR_RE 這條規則造成的"
  else
    echo "✗ ⑬ mutant 未如預期翻轉（實得 exit ${rc_tsonly}）" >&2
    printf '%s\n' "$out_tsonly" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ⑬ mutate：找不到 HANDOFF-HAS-EVIDENCE-PATH-ANCHOR 標記，負控本身無效" >&2
  fail=1
fi

# ==== ⑭（R5，LS-228 R2，F5）mutation 負控：拿掉 repo 邊界檢查（path_within_repo 恆回 True）→ ②k 的
#        逃逸樣本必須改判過（存在），證明②k 的紅是 HANDOFF-PATH-BOUNDARY-CHECK 這條檢查造成的 ====
mut_noboundary="$work/handoff_evidence_check.no-boundary.py"
awk '
  index($0, "# HANDOFF-PATH-BOUNDARY-CHECK") > 0 { print "    return True  # HANDOFF-PATH-BOUNDARY-CHECK"; next }
  { print }
' "$py" > "$mut_noboundary"
if grep -qF 'return True  # HANDOFF-PATH-BOUNDARY-CHECK' "$mut_noboundary"; then
  echo "✓ ⑭ mutate：確認已把 repo 邊界檢查恆改為 True（等同不檢查是否逃出 --repo）"
  escape_body='## 已驗證
- 條件 1：核對過 `scripts/../../outside-escape.sh` 的內容
'
  printf '%s' "$escape_body" > "$work/escape.md"
  out_escape="$(python3 "$mut_noboundary" "$work/escape.md" --repo "$R" 2>&1)"; rc_escape=$?
  if [ "$rc_escape" -eq 0 ]; then
    echo "✓ ⑭ mutant（拿掉 repo 邊界檢查）：②k 的逃逸樣本改判過（因為 \$work/outside-escape.sh 確實存在）——證明 HANDOFF-PATH-BOUNDARY-CHECK 是原因"
  else
    echo "✗ ⑭ mutant 未如預期翻轉（實得 exit ${rc_escape}）" >&2
    printf '%s\n' "$out_escape" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ⑭ mutate：找不到 HANDOFF-PATH-BOUNDARY-CHECK 標記，負控本身無效" >&2
  fail=1
fi

# ==== ⑮（R5，LS-228 R2，F4）mutation 負控：path_anchor_candidates() 的 skip 判準退回只有
#        is_command_invocation_candidate 一種 → ①ad／①ae 的正樣本必須改判紅，證明 is_negated／
#        is_mutation_context 這兩個新判準是原因 ====
mut_nopathskip="$work/handoff_evidence_check.no-path-skip.py"
awk '
  index($0, "# HANDOFF-PATH-SKIP-CHECK") > 0 { print "        skip = is_command_invocation_candidate(block, m.start())  # HANDOFF-PATH-SKIP-CHECK"; next }
  { print }
' "$py" > "$mut_nopathskip"
if grep -qF 'skip = is_command_invocation_candidate(block, m.start())  # HANDOFF-PATH-SKIP-CHECK' "$mut_nopathskip"; then
  echo "✓ ⑮ mutate：確認已把 path_anchor_candidates() 的 skip 判準退回只有 is_command_invocation_candidate 一種"
  neg_path_body='## 已驗證
- 條件 1：`supabase/migrations/20990101000000_x.sql` 這個檔不存在，gate 正確判紅
'
  printf '%s' "$neg_path_body" > "$work/negpath.md"
  out_negpath="$(python3 "$mut_nopathskip" "$work/negpath.md" --repo "$R" 2>&1)"; rc_negpath=$?
  if [ "$rc_negpath" -eq 1 ] && printf '%s' "$out_negpath" | grep -qF '20990101000000_x.sql'; then
    echo "✓ ⑮ mutant（否定詞）：①ad 的正樣本改判紅（20990101000000_x.sql 被當成引用驗存在）——證明否定詞判準是原因"
  else
    echo "✗ ⑮ mutant（否定詞）未如預期翻轉（實得 exit ${rc_negpath}）" >&2
    printf '%s\n' "$out_negpath" | sed 's/^/    /' >&2
    fail=1
  fi

  mut_path_body='## 已驗證
- 條件 1：mutation 樣本 `supabase/tests/99_nonexistent_mutant.sql` → 紅
'
  printf '%s' "$mut_path_body" > "$work/mutpath.md"
  out_mutpath="$(python3 "$mut_nopathskip" "$work/mutpath.md" --repo "$R" 2>&1)"; rc_mutpath=$?
  if [ "$rc_mutpath" -eq 1 ] && printf '%s' "$out_mutpath" | grep -qF '99_nonexistent_mutant.sql'; then
    echo "✓ ⑮ mutant（mutation 語境）：①ae 的正樣本改判紅——證明 mutation 語境判準是原因"
  else
    echo "✗ ⑮ mutant（mutation 語境）未如預期翻轉（實得 exit ${rc_mutpath}）" >&2
    printf '%s\n' "$out_mutpath" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ⑮ mutate：找不到 HANDOFF-PATH-SKIP-CHECK 標記，負控本身無效" >&2
  fail=1
fi

# ==== ⑯（R5，LS-228 R2，F1）mutation 負控：PATH_RE 退回 LS-228 首版（拿掉 .sh/.md/.yml）→ ①y（根
#        目錄 project.yml）／①z（裸檔名 db-reset-retry.sh）兩個正樣本必須改判紅，證明修復 merge-review
#        R1 F1 的正是把這三個副檔名還原回 PATH_RE ====
mut_r4regress="$work/handoff_evidence_check.r4-regression.py"
awk '
  index($0, "# HANDOFF-EVIDENCE-PATH") > 0 { print "PATH_RE = re.compile(r\"\\.png|\\.log|\\.test\\.sh|scratchpad/|evidence/|\\.swift\\b|\\.py\\b|\\.json\\b\")  # HANDOFF-EVIDENCE-PATH"; next }
  { print }
' "$py" > "$mut_r4regress"
if grep -qF 'PATH_RE = re.compile(r"\.png|\.log|\.test\.sh|scratchpad/|evidence/|\.swift\b|\.py\b|\.json\b")  # HANDOFF-EVIDENCE-PATH' "$mut_r4regress"; then
  echo "✓ ⑯ mutate：確認已把 PATH_RE 退回 LS-228 首版（拿掉 .sh/.md/.yml）"
  printf '%s' '## 已驗證
- 條件 1：核對過 `project.yml` 的內容
' > "$work/rootyml.md"
  out_rootyml="$(python3 "$mut_r4regress" "$work/rootyml.md" --repo "$R" 2>&1)"; rc_rootyml=$?
  printf '%s' '## 已驗證
- 條件 1：跑了 `db-reset-retry.sh` 全綠
' > "$work/barename.md"
  out_barename="$(python3 "$mut_r4regress" "$work/barename.md" --repo "$R" 2>&1)"; rc_barename=$?
  if [ "$rc_rootyml" -eq 1 ] && [ "$rc_barename" -eq 1 ]; then
    echo "✓ ⑯ mutant（PATH_RE 退回 LS-228 首版）：①y（project.yml）與①z（db-reset-retry.sh）雙雙改判紅——證明是這三個副檔名的還原修好了 merge-review R1 F1 的迴歸"
  else
    echo "✗ ⑯ mutant 未如預期翻轉（project.yml exit ${rc_rootyml}、db-reset-retry.sh exit ${rc_barename}，期望皆為 1）" >&2
    printf '%s\n' "$out_rootyml" | sed 's/^/    /' >&2
    printf '%s\n' "$out_barename" | sed 's/^/    /' >&2
    fail=1
  fi
else
  echo "✗ ⑯ mutate：找不到 HANDOFF-EVIDENCE-PATH 標記，負控本身無效" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  n=$(grep -c '^✓' "$count_log")
  echo "✓ handoff-evidence-check 自測通過（${n} 組樣本）"
fi
exit "$fail"
