#!/bin/bash
# patrol-filter.sh 的自測（LS-267 R2 M1）。CI `rules` job 跑。
# 守兩件事：(1) 過濾本身的行為（留什麼、丟什麼、空輸出 fail loud、參數 fail closed）；
# (2) **配套前提**——patrol 三支腳本的「異常／略過／讀不到」結論行都帶得動標記，不會被這道過濾靜默吞掉
#     （merge-review R1 M1：R1 版的過濾式把 Linear 半段「略過（無 LINEAR_API_KEY）」等整類行吃掉，
#      orchestrator 只看到 git 半段、Linear 半段停擺沒有任何訊號）。
# 逐分支夾具另見 `patrol-linear.test.sh` ⑪(e)-(g)（Linear 半段全稱＋無 key 略過）、⑬（LS-287 已落地排除）與
# `patrol.test.sh` ㉛（git 半段旗標／停滯行）；本檔補 patrol.sh 的退化分支與文件引用對帳。
# ⑨（LS-287）：harness 開票行的「已落地：」附註裁定「進 context」（隨同一條 → 行通過），理由見該區塊註解。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pf="${root}/scripts/ops/patrol-filter.sh"
patrol="${root}/scripts/ops/patrol.sh"
doc="${root}/docs/COLLABORATION.md"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# R3 B1（merge-review R2 blocker）：**不要用 `printf … | grep -q`**。`set -o pipefail` 下，GNU grep `-q`
# 命中就立刻退出，寫入端的 printf 收到 SIGPIPE 回 141 → 整條管線 141 → 斷言假紅；內容越大、命中位置越
# 靠前就越容易觸發（reviewer 在 ubuntu:24.04 實測：同一份輸入 20 次有 14 次回 141，本檔在容器內 8/8 紅）。
# macOS 的 BSD grep 會把輸入讀完才退出，所以本機永遠看不到——這是最糟的形狀：本機綠、CI 紅、每次紅的格子還不同。
# 改用 here-string（無管線、無 SIGPIPE）；比對整個檔案時用下面的 `file_has()` 讓 grep 直接吃檔案。
has() { if grep -qF -- "$3" <<<"$2"; then echo "✓ $1"; else echo "✗ ${1}（輸出應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then echo "✗ ${1}（輸出不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else echo "✓ $1"; fi; }
# file_has <名稱> <檔案路徑> <字面>：grep 直接讀檔，不經 shell 變數、不經管線（⑧ 的四格原本把 100 KB 的
# patrol.sh／patrol_linear.py 讀進變數再灌管線，正是 B1 的觸發點）。
file_has() { if grep -qF -- "$3" "$2"; then echo "✓ $1"; else echo "✗ ${1}（${2} 應含「${3}」）" >&2; fail=1; fi; }
rc_is() { if [ "$3" -eq "$2" ]; then echo "✓ $1"; else echo "✗ ${1}（期望 exit ${2}，實得 ${3}）" >&2; printf '%s\n' "$4" | sed 's/^/    /' >&2; fail=1; fi; }

# ---- ① --pattern：印出樣式本身（文件與其他自測都引用它，不再各自抄字面）----
pat=$(bash "$pf" --pattern); rc=$?
rc_is '① --pattern exit 0' 0 "$rc" "$pat"
for tok in '⚠' '✗' '⏳' '→' 'lane:' 'current cycle' '無異常'; do
  has "① 樣式含 ${tok}" "$pat" "$tok"
done
# R3 i3：`--markers` 是「帶標記」的子集合（`patrol.test.sh` ㉛a 的輸入選擇器從這裡取），必須是 PATTERN 的前綴子集
mk=$(bash "$pf" --markers); rc=$?
rc_is '① --markers exit 0' 0 "$rc" "$mk"
has   '① --markers 是 --pattern 的子集合（同一份定義切出來）' "$pat" "$mk"
hasnt '① --markers 不含結構行選擇器（lane:）' "$mk" 'lane:'

# ---- ② 留什麼、丟什麼 ----
sample=$(printf '%s\n' \
  '== 近 7 日 CI 同類紅（同簽章 ≥2 個 run 即 ⚠ → §5-b）' \
  '  LS-9  feature/LS-9-x  local=a remote=a ahead=0  ok' \
  '  ⚠ runtime LS-9-iPhone17Pro iOS 26.5 ≠ 釘住版 iOS 26.2' \
  '  LS-2  feature/LS-2-y  ⏳ 1 個未提交變更、最後改動 45m 前' \
  '  → save_issue LS-3 cycle=5' \
  '    lane:harness    上限1 在飛1  候補：（無候補）' \
  '   current cycle：5（剩 3 天；票數 2/4 完成）' \
  '  巡檢：無異常（git／PR 面；Linear 對照仍需 list_issues）' \
  '  容器 12 個，rest／kong／db／auth 之間最大差 5 分')
kept=$(printf '%s\n' "$sample" | bash "$pf")
has   '② 留下 ⚠ 行' "$kept" '⚠ runtime LS-9-iPhone17Pro'
has   '② 留下 ⏳ 停滯行' "$kept" '⏳ 1 個未提交變更'
has   '② 留下 → 動作行' "$kept" '→ save_issue LS-3 cycle=5'
has   '② 留下 lane 表' "$kept" 'lane:harness'
has   '② 留下 cycle 一行' "$kept" 'current cycle：5'
has   '② 留下「巡檢：無異常」' "$kept" '巡檢：無異常'
hasnt '② 丟掉段落標題（標題自己含 ⚠ 字樣）' "$kept" '== 近 7 日 CI 同類紅'
hasnt '② 丟掉無標記的 ok 行' "$kept" 'ahead=0  ok'
hasnt '② 丟掉無標記的敘述行' "$kept" '容器 12 個'

# ---- ③ 過濾後一行都不剩 → fail loud（印 ⚠ 提醒到 stderr），exit 仍 0 不中斷 cron ----
out3=$(printf '%s\n' '  一切風平浪靜' '  沒有任何標記' | bash "$pf" 2>&1); rc=$?
rc_is '③ 空結果仍 exit 0（不讓 cron 整條紅）' 0 "$rc" "$out3"
has   '③ 空結果印 ⚠ 提醒（不靜默）' "$out3" 'patrol-filter：過濾後沒有任何行'

# ---- ④ 參數 fail closed ----
out4=$(bash "$pf" --wat </dev/null 2>&1); rc=$?
rc_is '④ 未知參數 → exit 2' 2 "$rc" "$out4"

# ---- ⑤ 文件引用對帳：§4-b 模板必須「呼叫這支腳本」，且不得再複製樣式字面（R1 m1 的抄寫漂移來源）----
tmpl=$(grep -n 'orchestrator 自己直接執行' "$doc" | head -1 | cut -d: -f1)
if [ -z "$tmpl" ]; then
  echo "✗ ⑤ 在 docs/COLLABORATION.md 找不到 §4-b cron 模板第 1 步（形狀變了？）" >&2; fail=1
else
  line=$(sed -n "${tmpl}p" "$doc")
  has   '⑤ §4-b 模板呼叫 patrol-filter.sh' "$line" 'bash scripts/ops/patrol-filter.sh'
  hasnt '⑤ §4-b 模板不再複製樣式字面（樣式唯一定義在腳本）' "$line" "grep -E '⚠"
  # R3 i2：過濾器是下游、看不到上游 exit code——模板必須自己帶 pipefail，patrol.sh 的 exit 2 才不會被吃掉
  has   '⑤ §4-b 模板帶 set -o pipefail（上游非零不被管線末端蓋掉）' "$line" 'set -o pipefail'
fi

# ---- ⑤b（R3 i2）pipefail 下上游非零真的傳得出來（模板那一行的行為，不是只有文字）----
out5b=$(set -o pipefail; bash "$patrol" --bogus-arg 2>&1 | bash "$pf" 2>&1); rc5b=$?
if [ "$rc5b" -ne 0 ]; then
  echo "✓ ⑤b pipefail 下 patrol.sh 參數錯 → 整條管線非零（exit ${rc5b}），不被過濾器的 0 蓋掉"
else
  echo "✗ ⑤b pipefail 下上游非零仍被蓋成 0（模板的 pipefail 失效？）" >&2; printf '%s\n' "$out5b" | sed 's/^/    /' >&2; fail=1
fi
out5c=$(set +o pipefail; bash "$patrol" --bogus-arg 2>&1 | bash "$pf" 2>&1); rc5c=$?   # 本檔自己開著 pipefail，對照組要在子 shell 關掉
if [ "$rc5c" -eq 0 ]; then
  echo "✓ ⑤b 對照：沒有 pipefail 時同一條管線回 0——證明 ⑤b 的非零來自 pipefail 本身"
else
  echo "✗ ⑤b 對照組不該非零（實得 ${rc5c}）" >&2; fail=1
fi

# ---- ⑥ patrol.sh 的退化分支（gh 不可用 → PR 半段整段沒巡）：結論行必須通過過濾 ----
repo="$work/repo"
git init -q -b main "$repo"
( cd "$repo" && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m 'chore: LS-0 seed' )
out6=$(PATROL_GH="$work/no-such-gh" bash "$patrol" --repo "$repo" --no-fetch 30 2>&1)
keep6=$(printf '%s\n' "$out6" | bash "$pf" 2>/dev/null)
has '⑥ gh 不可用 → 「⚠ PR：略過（gh …）」通過過濾' "$keep6" '⚠ PR：略過（gh '

# ---- ⑦ mutation：拿掉 ⑥ 那行的 ⚠ → 被過濾吞掉（證明 ⑥ 的綠來自標記）----
mut="$work/mut/scripts"
mkdir -p "$work/mut"
cp -R "${root}/scripts" "$work/mut/scripts"
sed 's|echo "  ⚠ PR：略過（${pr_skip}）——PR 半段這輪沒巡"|echo "  PR：略過（${pr_skip}）"|' "$patrol" > "${mut}/ops/patrol.sh"
if ! grep -q 'echo "  PR：略過（${pr_skip}）"' "${mut}/ops/patrol.sh"; then
  echo "✗ ⑦ mutant 沒被正確合成（PR 略過行形狀變了）" >&2; fail=1
else
  out7=$(PATROL_GH="$work/no-such-gh" bash "${mut}/ops/patrol.sh" --repo "$repo" --no-fetch 30 2>&1)
  keep7=$(printf '%s\n' "$out7" | bash "$pf" 2>/dev/null)
  if grep -qF 'PR：略過（gh ' <<<"$keep7"; then
    echo "✗ ⑦ mutant（拿掉 ⚠）仍通過過濾——⑥ 的綠不是來自標記" >&2; fail=1
  else
    echo "✓ ⑦ mutant（拿掉 PR 略過行的 ⚠）：該行被過濾吞掉——證明 ⑥ 釘的正是那個標記"
  fi
fi

# ---- ⑧ 其餘退化分支的標記（原始碼字面對帳；這些分支要在真機／真 Linear 才觸發得到）----
file_has '⑧ patrol.sh：df 讀不到可用空間的略過行帶 ⚠' "$patrol" '⚠ （df 讀不到可用空間，略過'
file_has '⑧ patrol.sh：Pen lane 查詢失敗分支帶 ⚠' "$patrol" 'PEN_WRONG_LINE="⚠ Pen：目前開在'
has '⑧ patrol-linear.sh：無 LINEAR_API_KEY 三種模式都帶 ⚠' \
  "$(grep -c '⚠ 巡檢（Linear 半段）' "${root}/scripts/ops/patrol-linear.sh")" '3'
# R3 m1：QA「讀不到」那格移除——`format_human()` 的渲染端已經對每條 state_crosscheck 行前置 ⚠，
# 產生端不該再加（R2 加了會變 `⚠ ⚠`）。該路徑改由 `patrol-linear.test.sh` ⑫ 驗「恰好一個 ⚠ 且通過過濾」。
file_has '⑧ patrol_linear.py：狀態對照行由渲染端統一前置 ⚠（產生端不重複加）' "${root}/scripts/ops/patrol_linear.py" '"  ⚠ %s" % line'
file_has '⑧ patrol_linear.py：cycle 對帳 (c)(d) 訊息帶 ⚠' "${root}/scripts/ops/patrol_linear.py" '"  (c) ⚠ %s"'

# ---- ⑨（LS-287）「已落地：」補位候選排除附註——裁定：進 context ----
# patrol_linear.py 的 format_landed_note() 把「已落地：<id8> → <檔:行>」附掛在同一條「→ 開票：…」動作行
# 的 ［…］notes 括號裡（重用既有 open_ticket notes 機制，不另開一條獨立行）。既然它跟 → 同一行，這道
# 過濾本來就會留下整行（判準①只看行內有沒有 → ／⚠ 等標記字元，不分段），所以裁定是「進 context」——
# 讓 orchestrator 在看到「lane:harness 空 n 輪」時，同時看到候選被排除了誰、不必另外反查 repo；比藏成
# 不帶標記的獨立行更直接。這裡釘住這個決定本身：若哪天改成獨立一行印出且沒帶標記，這裡要跟著紅。
sample9=$(printf '%s\n' \
  '  lane:harness    上限1 在飛0  候補：（無候補）' \
  '    → 開票：lane:harness 空 1 輪（無候補）——來源候選：LS-96#33334444「尚未落地的候選」（P2 池項尚未升票）［已落地：11112222 → scripts/ops/fake-landed-LS287.sh:2］')
kept9=$(printf '%s\n' "$sample9" | bash "$pf")
has '⑨ 「已落地：」附註隨同一條 → 開票行一起通過過濾（裁定：進 context）' "$kept9" '已落地：11112222 → scripts/ops/fake-landed-LS287.sh:2'

# ---- ⑩（LS-311）用量段「⚠ [用量]」行：97 級警示、99 級停工都要原樣通過（不靠這裡另開白名單——patrol.sh
#      自己已把 ⚠／→ 寫進訊息裡，符合判準①；這裡釘住「真的通過」這件事，回歸不會被日後改動悄悄濾掉）----
sample10=$(printf '%s\n' \
  '  ⚠ [用量] 週用量 97%（重置 09-20 19:00）→ 不派新任務；在飛 agent 跑完只記票（usage-budget-winddown 步驟 3）' \
  '  ⚠ [用量] 週用量 99%（重置 09-20 19:00）→ 停下所有工作：CronDelete 巡檢、不派任何 agent、在飛只等結果記票、寫交接 session-resume-<日期>.md（usage-budget-winddown 步驟 1–5）')
kept10=$(printf '%s\n' "$sample10" | bash "$pf")
has '⑩ 留下 97 級 [用量] 警示行' "$kept10" '⚠ [用量] 週用量 97%'
has '⑩ 留下 99 級 [用量] 停工行' "$kept10" '⚠ [用量] 週用量 99%'

if [ "$fail" -eq 0 ]; then
  echo "✓ patrol-filter 自測通過（11 組樣本）"
fi
exit "$fail"
