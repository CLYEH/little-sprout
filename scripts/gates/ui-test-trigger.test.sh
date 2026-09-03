#!/bin/bash
# ui-test-trigger.sh 的自測（LS-137）。CI rules job 每個 PR 都跑。
#
# 票文三樣本（①只動 LittleSprout/Navigation/ → 跑；②只動 LittleSproutUITests/ → 跑；③只動 supabase/ → 略過）
# ＋規則邊界（前綴不可誤配 LittleSproutTests/、非 Swift 檔不算、混合清單、空清單、參數錯誤）＋ `--base` 模式
# 用合成 repo 驗 git diff 接線與三點語意（base 側自己的變更不算）。
#
# 「前饋必有反饋」對這支腳本也適用：mutation 負控用 UI-TEST-TRIGGER-RULE 標記把判定退回 LS-95 舊規則
# （只認 Features/／DesignSystem/），樣本 ①／② 必須改判略過——證明 ①／② 確實釘住「LittleSprout/**/*.swift」與
# 「LittleSproutUITests/**」這兩條判定，不是湊巧綠（同 linear-issue-check.test.sh 的 build_mutant 慣例）。
# merge-review R1（R2 補）：㉑ rename 搬出 app target／㉒ 非 ASCII 檔名／㉓ --files 給目錄，＋ diff 行三支 mutant
# （三點→兩點／拿掉 --no-renames／拿掉 quotePath=false）各自必須翻掉 ⑱／㉑／㉒；fixture 內容改互異（F1 根因）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/ui-test-trigger.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

rule_set='LittleSprout/**/*.swift、LittleSproutUITests/**'

expect() {   # expect <期望 exit code> <名稱> <實得 exit code> <輸出> [輸出必含字串…]
  local want=$1 name=$2 got=$3 out=$4
  shift 4
  local ok=1
  [ "$got" -eq "$want" ] || ok=0
  local must
  for must in "$@"; do
    printf '%s' "$out" | grep -qF -- "$must" || ok=0
  done
  if [ "$ok" -eq 1 ]; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

files_run() {   # files_run <腳本> <路徑…>：以 --files - 從 stdin 餵變更清單
  local script=$1; shift
  printf '%s\n' "$@" | bash "$script" --files - 2>&1
}

# ---- 票文三樣本 ----
# ① 只動 LittleSprout/Navigation/ → 跑（LS-136 PR #235 的實際形狀：舊規則印「略過」）
out=$(files_run "$checker" LittleSprout/Navigation/MainTabView.swift); got=$?
expect 0 '① 只動 LittleSprout/Navigation/ → 跑' "$got" "$out" '要跑' 'LittleSprout/Navigation/MainTabView.swift'

# ② 只動 LittleSproutUITests/ → 跑（改 UI 測試本身也要跑）
out=$(files_run "$checker" LittleSproutUITests/TapTargetGateTests.swift); got=$?
expect 0 '② 只動 LittleSproutUITests/ → 跑' "$got" "$out" '要跑' 'LittleSproutUITests/TapTargetGateTests.swift'

# ③ 只動 supabase/ → 略過（exit 3），且印出實際判定用的路徑集合
out=$(files_run "$checker" supabase/migrations/20260903000000_foo.sql supabase/config.toml); got=$?
expect 3 '③ 只動 supabase/ → 略過（exit 3）並印判定路徑集合' "$got" "$out" '略過' "$rule_set" 'supabase/migrations/20260903000000_foo.sql'

# ---- 規則邊界 ----
# ④ 純 docs/＋scripts/ → 略過（保留 LS-95 R1 m3 省時語意）
out=$(files_run "$checker" docs/COLLABORATION.md scripts/gates/foo.sh .github/workflows/ci.yml); got=$?
expect 3 '④ 純 docs/／scripts/／.github/ → 略過' "$got" "$out" '略過'

# ⑤ 根層 LittleSprout/*.swift（LS-136 的 TapTargetGateHarness.swift）→ 跑
out=$(files_run "$checker" LittleSprout/TapTargetGateHarness.swift); got=$?
expect 0 '⑤ 根層 LittleSprout/TapTargetGateHarness.swift → 跑' "$got" "$out" '要跑'

# ⑥ 只動 LittleSprout/ 下非 Swift 檔 → 略過（規則是 *.swift，不是「LittleSprout/ 下任何檔」）
out=$(files_run "$checker" LittleSprout/Assets.xcassets/AppIcon.appiconset/Contents.json LittleSprout/Info.plist); got=$?
expect 3 '⑥ 只動 LittleSprout/ 下非 Swift 檔 → 略過' "$got" "$out" '略過'

# ⑦ 只動 LittleSproutTests/（unit tests）→ 略過：`LittleSprout/` 前綴含斜線，不可誤配同名前綴目錄
out=$(files_run "$checker" LittleSproutTests/TimelineStoreTests.swift); got=$?
expect 3 '⑦ 只動 LittleSproutTests/ → 略過（前綴不可誤配）' "$got" "$out" '略過'

# ⑧ 混合清單：supabase/ 在前、LittleSprout/Services/ 的 Swift 在後 → 跑（不能只看第一個檔）
out=$(files_run "$checker" supabase/config.toml LittleSprout/Services/Timeline/TimelineStore.swift); got=$?
expect 0 '⑧ 混合清單（supabase/＋LittleSprout/Services/*.swift）→ 跑' "$got" "$out" '要跑' 'TimelineStore.swift'

# ⑨ 路徑不在根層（docs/LittleSprout/Foo.swift）→ 略過：判定是錨定 repo 根的前綴，不是子字串
out=$(files_run "$checker" docs/LittleSprout/Foo.swift design/LittleSproutUITests/x); got=$?
expect 3 '⑨ 非根層的 LittleSprout/… 子字串 → 略過（錨定前綴）' "$got" "$out" '略過'

# ⑩ 空清單 → 略過
out=$(printf '' | bash "$checker" --files - 2>&1); got=$?
expect 3 '⑩ 空清單 → 略過' "$got" "$out" '略過'

# ⑪ --files 讀檔（非 stdin）
printf 'LittleSprout/Navigation/MainTabView.swift\n' > "$work/list.txt"
out=$(bash "$checker" --files "$work/list.txt" 2>&1); got=$?
expect 0 '⑪ --files <file> 讀檔 → 跑' "$got" "$out" '要跑'

# ---- 參數錯誤 → exit 2（呼叫端視為「無法證明可略過」照跑） ----
out=$(bash "$checker" 2>&1); got=$?
expect 2 '⑫ 無參數 → exit 2、印用法' "$got" "$out" '用法：ui-test-trigger.sh'
out=$(bash "$checker" --base x --files y 2>&1); got=$?
expect 2 '⑬ --base 與 --files 同給 → exit 2' "$got" "$out" '只能擇一'
out=$(bash "$checker" --files "$work/missing.txt" 2>&1); got=$?
expect 2 '⑭ --files 讀不到檔 → exit 2' "$got" "$out" '讀不到'
out=$(bash "$checker" --bogus 2>&1); got=$?
expect 2 '⑮ 未知參數 → exit 2' "$got" "$out" '未知參數'

# ---- --base 模式：合成 repo ----
R="$work/repo"
mkdir -p "$R"
git -C "$R" init -q -b base
git -C "$R" -c user.name=t -c user.email=t@t config commit.gpgsign false
commit() {   # commit <repo> <訊息> <檔案…>：建檔＋commit
  local repo=$1 msg=$2; shift 2
  local f
  # merge-review R1 F1：內容必須互異（寫入路徑名本身）——原本每檔固定 x，⑱ 的 base 側 Swift 與 feature 側 .sql
  # 內容相同被 git 配成 R100 rename、--name-only 只印目的路徑，三點→兩點的 mutation 因此逃脫。
  for f in "$@"; do mkdir -p "$repo/$(dirname "$f")"; echo "$f" >> "$repo/$f"; done
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "$msg"
}
commit "$R" init README.md supabase/config.toml

# ⑯ feature 分支只動 LittleSprout/Navigation/ → 跑
git -C "$R" checkout -q -b feat-nav
commit "$R" nav LittleSprout/Navigation/MainTabView.swift
out=$(cd "$R" && bash "$checker" --base base 2>&1); got=$?
expect 0 '⑯ --base：feature 只動 LittleSprout/Navigation/ → 跑' "$got" "$out" '要跑' 'MainTabView.swift'

# ⑰ feature 分支只動 supabase/ → 略過
git -C "$R" checkout -q base
git -C "$R" checkout -q -b feat-db
commit "$R" db supabase/migrations/20260903000000_foo.sql
out=$(cd "$R" && bash "$checker" --base base 2>&1); got=$?
expect 3 '⑰ --base：feature 只動 supabase/ → 略過' "$got" "$out" '略過' "$rule_set"

# ⑱ 三點語意：base 側後來自己加了 Swift 檔、feature（只動 supabase/）未合入 → 仍略過
#    （兩點 `base..HEAD` 會把 base 側的 Swift 檔當成 HEAD「刪除」列進清單而誤觸發；mutation 負控）
git -C "$R" checkout -q base
commit "$R" base-swift LittleSprout/Features/Foo.swift
git -C "$R" checkout -q feat-db
out=$(cd "$R" && bash "$checker" --base base 2>&1); got=$?
expect 3 '⑱ --base 三點語意：base 側自己的 Swift 變更不算 → 仍略過' "$got" "$out" '略過'

# ⑲ base ref 不存在 → exit 2
out=$(cd "$R" && bash "$checker" --base nope 2>&1); got=$?
expect 2 '⑲ --base 找不到 ref → exit 2' "$got" "$out" '找不到 base ref'

# ⑳ 不在 git repo 內 → exit 2
out=$(cd "$work" && bash "$checker" --base base 2>&1); got=$?
expect 2 '⑳ --base 不在 git repo 內 → exit 2' "$got" "$out" '不在 git repo 內'

# ㉑ merge-review R1 F2：Swift 檔搬出 app target（git mv LittleSprout/Features/Foo.swift → docs/）→ 要跑。
#    不帶 --no-renames 時 git 配成 R100、--name-only 只印目的路徑 docs/Foo.swift → 誤判略過（漏跑方向）。
git -C "$R" checkout -q base
git -C "$R" checkout -q -b feat-mv
mkdir -p "$R/docs"
git -C "$R" mv LittleSprout/Features/Foo.swift docs/Foo.swift
git -C "$R" -c user.name=t -c user.email=t@t commit -q -m mv
out=$(cd "$R" && bash "$checker" --base base 2>&1); got=$?
expect 0 '㉑ --base：Swift 檔 git mv 搬出 LittleSprout/ → 要跑（舊路徑要進清單）' "$got" "$out" '要跑' 'LittleSprout/Features/Foo.swift'

# ㉒ merge-review R1 F3：非 ASCII 檔名的 Swift 新增（LittleSprout/Features/測試View.swift）→ 要跑。
#    core.quotePath 預設會把路徑印成 "LittleSprout/Features/\346\270\254…"（含引號）→ ^LittleSprout/ 不匹配。
git -C "$R" checkout -q base
git -C "$R" checkout -q -b feat-zh
commit "$R" zh 'LittleSprout/Features/測試View.swift'
out=$(cd "$R" && bash "$checker" --base base 2>&1); got=$?
expect 0 '㉒ --base：非 ASCII 檔名 Swift 新增 → 要跑（路徑不被 quotePath 跳脫）' "$got" "$out" '要跑' 'LittleSprout/Features/測試View.swift'

# ㉓ merge-review R1 F4：--files 給目錄（[ -r ] 為真但 cat 失敗）→ exit 2，不得落成「空清單→略過」的 fail-open
out=$(bash "$checker" --files "$work" 2>&1); got=$?
expect 2 '㉓ --files 給目錄 → exit 2（不 fail-open 成略過）' "$got" "$out" '讀不到'

# ---- mutation 負控：把判定退回 LS-95 舊規則（只認 Features/／DesignSystem/），①／② 必須改判略過 ----
# 證明 ①／② 釘住的是「LittleSprout/**/*.swift」「LittleSproutUITests/**」兩條判定本身：若腳本退化回舊規則，
# 本檔的 ①／② 會紅（這裡對 mutant 直接驗「改判略過」，並先驗 mutant 真的被改到，負控本身才有效）。
mutant="$work/mutant.sh"
awk -v repl="pattern='(^|/)(Features|DesignSystem)/'" \
  '$0 ~ /^pattern=/ && index($0, "UI-TEST-TRIGGER-RULE") > 0 { print repl; next } { print }' "$checker" > "$mutant"
if ! grep -qF "(Features|DesignSystem)/" "$mutant" || grep -qF 'LittleSprout/.*\.swift' "$mutant"; then
  echo "✗ mutant：判定行沒有被替換（UI-TEST-TRIGGER-RULE 標記遺失？），負控本身無效" >&2
  fail=1
else
  out=$(files_run "$mutant" LittleSprout/Navigation/MainTabView.swift); got=$?
  expect 3 'mutant（退回 Features|DesignSystem 舊規則）：樣本 ① 改判略過——證明 ① 釘住 LittleSprout/**/*.swift' "$got" "$out" '略過'
  out=$(files_run "$mutant" LittleSproutUITests/TapTargetGateTests.swift); got=$?
  expect 3 'mutant（退回 Features|DesignSystem 舊規則）：樣本 ② 改判略過——證明 ② 釘住 LittleSproutUITests/**' "$got" "$out" '略過'
  # 對照：舊規則仍認得 Features/——mutant 不是「什麼都略過」的壞 mutant
  out=$(files_run "$mutant" LittleSprout/Features/Auth/SignInView.swift); got=$?
  expect 0 'mutant 對照：Features/ 在舊規則下仍要跑（mutant 不是全略過）' "$got" "$out" '要跑'
fi

# ---- merge-review R1 F1：diff 行的 mutation 負控（UI-TEST-TRIGGER-DIFF 標記）----
# 三點→兩點／拿掉 --no-renames／拿掉 core.quotePath=false 三支 mutant 必須分別把 ⑱／㉑／㉒ 翻掉——原 fixture
# 每檔內容固定 x 時，⑱ 抓不到三點→兩點（R100 rename 吞掉 Swift 路徑）；這裡直接驗 mutant 的翻轉，若有人把
# commit() 改回固定內容、或案例失去鑑別力，這裡會紅。
diff_mutant() {   # diff_mutant <輸出路徑> <替換整行>
  awk -v repl="$2" '$0 ~ /^ *changed=\$\(git / && index($0, "UI-TEST-TRIGGER-DIFF") > 0 { print repl; next } { print }' "$checker" > "$1"
  if cmp -s "$checker" "$1"; then
    echo "✗ diff mutant：替換沒生效（UI-TEST-TRIGGER-DIFF 標記遺失？），負控本身無效" >&2
    fail=1; return 1
  fi
}
m="$work/mutant-twodot.sh"
if diff_mutant "$m" '    changed=$(git -c core.quotePath=false diff --name-only --no-renames "${arg}..HEAD") || exit 2'; then
  out=$(cd "$R" && git checkout -q feat-db && bash "$m" --base base 2>&1); got=$?
  expect 0 'mutant（三點→兩點）：⑱ 情境改判要跑（base 側 Swift 被當成刪除列進清單）——證明 ⑱ 釘住三點語意' "$got" "$out" 'LittleSprout/Features/Foo.swift'
fi
m="$work/mutant-renames.sh"
if diff_mutant "$m" '    changed=$(git -c core.quotePath=false diff --name-only "${arg}...HEAD") || exit 2'; then
  out=$(cd "$R" && git checkout -q feat-mv && bash "$m" --base base 2>&1); got=$?
  expect 3 'mutant（拿掉 --no-renames）：㉑ 改判略過（R100 只印目的路徑）——證明 ㉑ 釘住 --no-renames' "$got" "$out" '略過'
fi
m="$work/mutant-quotepath.sh"
if diff_mutant "$m" '    changed=$(git diff --name-only --no-renames "${arg}...HEAD") || exit 2'; then
  out=$(cd "$R" && git checkout -q feat-zh && bash "$m" --base base 2>&1); got=$?
  expect 3 'mutant（拿掉 core.quotePath=false）：㉒ 改判略過（路徑被引號跳脫）——證明 ㉒ 釘住 quotePath' "$got" "$out" '略過'
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ ui-test-trigger.test.sh 全部通過"
else
  echo "✗ ui-test-trigger.test.sh 有案例失敗" >&2
fi
exit "$fail"
