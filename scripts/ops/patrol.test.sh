#!/bin/bash
# patrol.sh／session-start.sh 的自測（LS-71）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對巡檢本身也適用：若判定退化——拿 base commit 的時間當「最後 commit」把新 worktree 誤判成
# 停滯（scratchpad 原型的 bug）、領先 remote／從未 push／dirty 停滯／尚未開工／主 checkout 落後任一漏標、
# 三分支漂移漏標（test ⊄ development 立即、main ⊄ development 超過 stale）或剛併入的 hotfix 被誤標（LS-85）、
# 乾淨或剛建好的 worktree 被誤標、保護分支或 detached worktree 混進表、--json 不合法、gh 不可用整支炸掉、
# gate hooks 沒裝（core.hooksPath 不是 .githooks／hook 不可執行）不標或裝好了誤標（LS-87）、
# >1 台非 demo-* 模擬器同時 Booted 卻沒標、demo-* 沒被豁免、或只有一台就誤標（LS-100）、
# 或 SessionStart hook 輸出不合法 JSON／非 0 退出／settings.json 沒掛上——這裡會紅。
# 合成 repo：file:// 裸 repo 當 origin（main／development／test），clone 當主 checkout，八個 worktree 各一種形狀；最後把 origin 指向會掛住的 ext:: 位址驗 fetch 看門狗。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
patrol="${root}/scripts/ops/patrol.sh"
hook="${root}/scripts/ops/session-start.sh"
settings="${root}/.claude/settings.json"
fail=0

command -v jq >/dev/null 2>&1 || { echo "✗ patrol 自測需要 jq（驗 --json 與 hook 輸出）" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# LS-70：Supabase lock 段讀合成 lock 目錄，不碰真的 /tmp/supabase-lock-*（⑪ 之前一律 free）
export SUPABASE_LOCK_DIR="$work/lock"
# LS-100：預設把 Booted 模擬器段餵一份「沒有裝置」的合成 JSON，不碰本機真正的模擬器——本機在跑其他
# worktree／agent 時可能真的有機器 Booted，不隔離的話 ①～⑬ 這些不關心模擬器的既有斷言會被本機當下
# 狀態污染而偶發紅（環境相依、不可重現）。⑭（既有：PATH 換 xcrun stub 驗 stale 裝置判定）與
# ⑮～⑰（本票：驗 Booted 判定）各自在呼叫時明講 SIMCTL_LIST_JSON（⑭ 特意設成空字串讓它照舊落回
# PATH 裡的 xcrun stub——patrol.sh 用 `${SIMCTL_LIST_JSON:-…}`，空字串與未設值同樣觸發預設值）。
export SIMCTL_LIST_JSON='{"devices":{}}'

# 臨時 repo 與本機全域／系統 git 設定隔離：自測結果不能因人而異
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
OLD=2020-01-01T00:00:00Z   # 老到必超過 stale 的時間戳（commit 日期）
OLD_T=202001010000         # 同一天，給 touch -t（POSIX，macOS／GNU 皆可）
gold() { env GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD" git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
STALE=30

has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（輸出應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✗ ${1}（輸出不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else echo "✓ $1"; fi; }
row()   { printf '%s' "$1" | grep -F -- "$2"; }   # 取含某字串的行
jq_ok() { if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then echo "✓ $1"; else echo "✗ ${1}（jq -e '${3}' 不成立）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
rc_is() { if [ "$3" -eq "$2" ]; then echo "✓ $1"; else echo "✗ ${1}（期望 exit ${2}，實得 ${3}）" >&2; printf '%s\n' "$4" | sed 's/^/    /' >&2; fail=1; fi; }

# ---- 合成 repo ----
remote="$work/remote.git"; g init -q --bare -b main "$remote"   # 裸 origin 的 HEAD 要指到 main，clone 才有 checkout
seed="$work/seed"; g init -q -b main "$seed"
echo a > "$seed/file.txt"; g -C "$seed" add -A
gold -C "$seed" commit -qm 'chore: LS-0 seed'     # base commit 刻意很老：拿它的時間當「最後 commit」就會把新 worktree 誤判
g -C "$seed" branch development; g -C "$seed" branch test
g -C "$seed" remote add origin "$remote"; g -C "$seed" push -q origin main development test
repo="$work/repo"; g clone -q "$remote" "$repo"
# gate hooks 裝好（§2 首次 clone 後的 git config core.hooksPath .githooks；三支 hook 可執行）——⑬ 之前一律視為正常
mkdir -p "$repo/.githooks"
for h in commit-msg pre-commit pre-push; do printf '#!/bin/sh\nexit 0\n' > "$repo/.githooks/$h"; chmod +x "$repo/.githooks/$h"; done
g -C "$repo" config core.hooksPath .githooks
wts="$repo/.claude/worktrees"; mkdir -p "$wts"
wt() { g -C "$repo" worktree add "$@" >/dev/null 2>&1 || { echo "✗ 建 worktree 失敗：$*" >&2; exit 1; }; }

# ① LS-1 領先 remote：兩個老 commit，只 push 第一個（第二個在本機等 push gate）
wt -b feature/LS-1-ahead "$wts/LS-1" origin/development
echo 1 > "$wts/LS-1/one.txt"; g -C "$wts/LS-1" add -A; gold -C "$wts/LS-1" commit -qm 'feat: LS-1 one'
g -C "$wts/LS-1" push -q origin feature/LS-1-ahead
echo 2 > "$wts/LS-1/two.txt"; g -C "$wts/LS-1" add -A; gold -C "$wts/LS-1" commit -qm 'feat: LS-1 two'
# ② LS-2 dirty 停滯：0 commit（HEAD＝老的 base commit）、有一個老的未提交變更
wt -b feature/LS-2-dirty "$wts/LS-2" origin/development
echo x >> "$wts/LS-2/file.txt"; touch -t "$OLD_T" "$wts/LS-2/file.txt"
# ③ LS-3 乾淨：剛 commit、已 push、無變更（負向）
wt -b feature/LS-3-clean "$wts/LS-3" origin/development
echo 3 > "$wts/LS-3/three.txt"; g -C "$wts/LS-3" add -A; g -C "$wts/LS-3" commit -qm 'feat: LS-3 three'
g -C "$wts/LS-3" push -q origin feature/LS-3-clean
# ④ LS-4 從未 push：有 commit、remote 無此分支
wt -b feature/LS-4-unpushed "$wts/LS-4" origin/development
echo 4 > "$wts/LS-4/four.txt"; g -C "$wts/LS-4" add -A; g -C "$wts/LS-4" commit -qm 'feat: LS-4 four'
# ⑤ LS-5 尚未開工：建好很久、0 commit、無變更（worktree 的 .git 檔 mtime＝建立時間）
wt -b feature/LS-5-idle "$wts/LS-5" origin/development
touch -t "$OLD_T" "$wts/LS-5/.git"
# ⑥ LS-6 剛建好：0 commit、無變更（負向；base commit 很老也不得誤標）；路徑帶引號與空白，順便驗 --json 跳脫
wt -b feature/LS-6-fresh "$wts/LS-6 \"q\"" origin/development
# ⑧ LS-8 目錄被刪但沒 git worktree remove（prunable）：要標、--json 欄位要與正常 worktree 同一套
wt -b feature/LS-8-gone "$wts/LS-8" origin/development
rm -rf "$wts/LS-8"
# 保護分支 worktree 與 detached worktree：不得進 worktree 表、也不能讓腳本炸
wt "$work/dev-wt" development
wt --detach "$work/detached"
# ⑦ LS-7 已併入：有 commit、已 push，之後 origin/development fast-forward 到它（＝PR 併了）但 worktree 沒移除
wt -b feature/LS-7-merged "$wts/LS-7" origin/development
echo 7 > "$wts/LS-7/seven.txt"; g -C "$wts/LS-7" add -A; gold -C "$wts/LS-7" commit -qm 'feat: LS-7 seven'
g -C "$wts/LS-7" push -q origin feature/LS-7-merged
g -C "$wts/LS-7" push -q origin feature/LS-7-merged:development
# 主 checkout 落後：origin/main 再前進一個 commit（patrol 預設會 fetch，順便驗 fetch）
echo b >> "$seed/file.txt"; g -C "$seed" commit -qam 'chore: LS-0 main moves'; g -C "$seed" push -q origin main

# ---- ① 人類可讀模式（預設 fetch、略過 gh）：六個 worktree 各得其所、主 checkout 落後 ----
out="$(bash "$patrol" --repo "$repo" --no-pr "$STALE" 2>&1)"; rc=$?
rc_is '① 巡檢完成 exit 0（有異常也 0，異常在輸出）' 0 "$rc" "$out"
has   '① 主 checkout 落後 origin/main 1 → 標並指示 pull' "$out" '主 checkout 落後 origin/main 1 commit'
has   '① 指示含 git pull --ff-only origin main' "$out" 'git pull --ff-only origin main'
has   '① --no-pr → PR 段標示略過' "$out" 'PR：略過（--no-pr）'
has   '① 三分支：dev 落後 main 1' "$out" 'dev 落後 main: 1'
l1=$(row "$out" 'feature/LS-1-ahead')
has   '① LS-1 領先 remote 1 commit、最後 commit 老 → push gate 卡' "$l1" '領先 remote 1 commit'
has   '① LS-1 提示 push gate' "$l1" 'push gate'
l2=$(row "$out" 'feature/LS-2-dirty')
has   '① LS-2 老的未提交變更 → dirty 停滯' "$l2" '未提交變更'
has   '① LS-2 0 commit 顯示「尚無 commit」，不拿老 base commit 的時間當最後 commit（原型 bug）' "$l2" '尚無 commit'
hasnt '① LS-2 不得誤標尚未開工（有變更）' "$l2" '尚未開工'
hasnt '① LS-2 不得誤標領先 remote' "$l2" '領先'
l3=$(row "$out" 'feature/LS-3-clean')
has   '① LS-3 乾淨已 push → ok' "$l3" ' ok'
hasnt '① LS-3 無 ⚠' "$l3" '⚠'
hasnt '① LS-3 無 ⏳' "$l3" '⏳'
l4=$(row "$out" 'feature/LS-4-unpushed')
has   '① LS-4 有 commit 但從未 push' "$l4" '分支未 push'
l5=$(row "$out" 'feature/LS-5-idle')
has   '① LS-5 建好很久 0 commit 無變更 → 尚未開工' "$l5" '尚未開工'
l6=$(row "$out" 'feature/LS-6-fresh')
has   '① LS-6 剛建好 0 commit 無變更 → ok（base commit 很老也不誤標）' "$l6" ' ok'
has   '① LS-6 顯示「尚無 commit」' "$l6" '尚無 commit'
hasnt '① LS-6 無 ⏳' "$l6" '⏳'
l7=$(row "$out" 'feature/LS-7-merged')
has   '① LS-7 自 base 0 commit 但 reflog 有 commit → 已併入 base、worktree 未移除' "$l7" '已併入 base'
has   '① LS-7 提示可跑 cleanup-merged.sh（LS-86）並帶出票號 LS-7' "$l7" 'cleanup-merged.sh --dry-run LS-7'
hasnt '① LS-7 不得誤標尚未開工' "$l7" '尚未開工'
hasnt '① LS-5 沒動過 → 不是已併入' "$l5" '已併入'
l8=$(row "$out" 'feature/LS-8-gone')
has   '① LS-8 目錄不存在 → 標 prune' "$l8" '目錄不存在'
hasnt '① 保護分支 worktree 不進表' "$out" 'dev-wt'
has   '① detached worktree 只標略過、不炸' "$out" 'detached，略過'
has   '① hooks 裝好 → gate hooks 段 ok' "$(row "$out" 'hooksPath=')" ' ok'
hasnt '① hooks 裝好不標' "$out" '⚠ core.hooksPath'

# ---- ② --brief：只有表頭＋異常行 ----
brief="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"; rc=$?
rc_is '② --brief exit 0' 0 "$rc" "$brief"
case "$(printf '%s\n' "$brief" | head -1)" in
  巡檢\ *) echo "✓ ② 表頭以「巡檢 」開頭" ;;
  *) echo "✗ ② 表頭應以「巡檢 」開頭" >&2; printf '%s\n' "$brief" | sed 's/^/    /' >&2; fail=1 ;;
esac
has   '② 異常行含 LS-1' "$brief" 'feature/LS-1-ahead'
hasnt '② 乾淨的 LS-3 不出現' "$brief" 'feature/LS-3-clean'
has   '② 主 checkout 落後的固定句（session-start.sh 靠它 grep）' "$brief" '主 checkout 落後 origin/main'
hasnt '② 有異常時不印「無異常」' "$brief" '巡檢：無異常'

# ---- ③ --json：合法且欄位正確 ----
json="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"; rc=$?
rc_is '③ --json exit 0' 0 "$rc" "$json"
jq_ok '③ 合法 JSON' "$json" '.'
jq_ok '③ 八個 worktree（保護分支／detached 不算）' "$json" '.worktrees | length == 8'
jq_ok '③ development 分支不在 worktree 表' "$json" '[.worktrees[].branch] | index("development") == null'
jq_ok '③ LS-1：ahead 1、自 base 2 commit、flag 領先' "$json" '.worktrees[] | select(.branch=="feature/LS-1-ahead") | .ahead == 1 and .commits_since_base == 2 and (.flag | test("領先 remote"))'
jq_ok '③ LS-2：0 commit → last_commit_minutes null；dirty 1 且超過 stale' "$json" '.worktrees[] | select(.branch=="feature/LS-2-dirty") | .commits_since_base == 0 and .last_commit_minutes == null and .dirty == 1 and .dirty_minutes >= 30'
jq_ok '③ LS-3：無 flag、有 remote、ahead 0' "$json" '.worktrees[] | select(.branch=="feature/LS-3-clean") | .flag == "" and .remote != null and .ahead == 0'
jq_ok '③ LS-4：remote null、flag 未 push' "$json" '.worktrees[] | select(.branch=="feature/LS-4-unpushed") | .remote == null and (.flag | test("未 push"))'
jq_ok '③ LS-5：worktree_minutes 超過 stale、flag 尚未開工' "$json" '.worktrees[] | select(.branch=="feature/LS-5-idle") | .worktree_minutes >= 30 and (.flag | test("尚未開工"))'
jq_ok '③ LS-6：無 flag；路徑含引號被正確跳脫' "$json" '.worktrees[] | select(.branch=="feature/LS-6-fresh") | .flag == "" and (.path | test("\"q\""))'
jq_ok '③ LS-7：0 commit 自 base、merged_into_base true、flag 已併入' "$json" '.worktrees[] | select(.branch=="feature/LS-7-merged") | .commits_since_base == 0 and .merged_into_base == true and (.flag | test("已併入"))'
jq_ok '③ LS-5：merged_into_base false' "$json" '.worktrees[] | select(.branch=="feature/LS-5-idle") | .merged_into_base == false'
jq_ok '③ LS-8：missing true、flag 目錄不存在、數值欄 null' "$json" '.worktrees[] | select(.branch=="feature/LS-8-gone") | .missing == true and (.flag | test("目錄不存在")) and .local == null and .ahead == null'
jq_ok '③ LS-8：欄位集合與正常 worktree 完全相同' "$json" '([.worktrees[] | select(.branch=="feature/LS-8-gone") | keys] | first) == ([.worktrees[] | select(.branch=="feature/LS-3-clean") | keys] | first)'
jq_ok '③ 主 checkout：main、落後 1、flag 有句' "$json" '.main_checkout.branch == "main" and .main_checkout.behind_origin_main == 1 and (.main_checkout.flag | test("落後 origin/main"))'
jq_ok '③ 三分支數字' "$json" '.branches.development_behind_main == 1 and .branches.test_behind_main == 1 and .branches.test_behind_development == 1'
jq_ok '③ PR 略過原因與空陣列' "$json" '.prs_skipped == "--no-pr" and .prs == []'
jq_ok '③ flags 彙總七筆（LS-1／2／4／5／7／8＋主 checkout）' "$json" '.flags | length == 7'
jq_ok '③ hooks 欄位：path .githooks、flag 空' "$json" '.hooks.path == ".githooks" and .hooks.flag == ""'

# ---- ④ gh 不可用（未裝、或 origin 不是 GitHub）→ 略過並標示，不炸 ----
out4="$(bash "$patrol" --repo "$repo" --no-fetch "$STALE" 2>&1)"; rc=$?
rc_is '④ gh 失敗仍 exit 0' 0 "$rc" "$out4"
has   '④ PR 段標示略過原因' "$out4" 'PR：略過（'

# ---- ⑤ 參數錯誤 fail closed（exit 2）----
bad() { local name=$1; shift; local out5; out5="$(bash "$patrol" "$@" 2>&1)"; rc_is "$name" 2 "$?" "$out5"; }
bad '⑤ 未知參數 → exit 2' --repo "$repo" --bogus
bad '⑤ stale 非整數 → exit 2' --repo "$repo" abc
bad '⑤ --repo 缺值 → exit 2' --repo
bad '⑤ --repo 不存在 → exit 2' --repo "$work/nope"
bad '⑤ --repo 不是 git repo → exit 2' --repo "$work"

# ---- ⑥ SessionStart hook：合法 JSON、含兩條指示、fail-soft ----
hj="$(printf '{}' | CLAUDE_PROJECT_DIR="$repo" PATROL_STALE="$STALE" bash "$hook" 2>/dev/null)"; rc=$?
rc_is '⑥ hook exit 0' 0 "$rc" "$hj"
jq_ok '⑥ hookSpecificOutput.hookEventName = SessionStart' "$hj" '.hookSpecificOutput.hookEventName == "SessionStart"'
jq_ok '⑥ additionalContext 含巡檢摘要與 cron 指示（*/26、§4-b）' "$hj" '.hookSpecificOutput.additionalContext | test("巡檢") and test("CronCreate") and test("\\*/26 \\* \\* \\* \\*") and test("§4-b")'
jq_ok '⑥ 主 checkout 落後 → 含先 pull 的指示' "$hj" '.hookSpecificOutput.additionalContext | test("git pull --ff-only origin main")'
hj2="$(printf '{}' | CLAUDE_PROJECT_DIR="$work/nope" bash "$hook" 2>/dev/null)"; rc=$?
rc_is '⑥ repo 不存在：fail-soft 仍 exit 0' 0 "$rc" "$hj2"
jq_ok '⑥ repo 不存在：仍合法 JSON、context 說明失敗＋仍提醒建 cron' "$hj2" '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | test("失敗") and test("CronCreate"))'

# ---- ⑦ 主 checkout pull 之後：落後標記與 pull 指示消失（負向）----
g -C "$repo" pull -q --ff-only origin main
brief2="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
hasnt '⑦ pull 後不再標主 checkout 落後' "$brief2" '主 checkout 落後 origin/main'
json2="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '⑦ pull 後 behind 0、flag 空' "$json2" '.main_checkout.behind_origin_main == 0 and .main_checkout.flag == ""'
hj3="$(printf '{}' | CLAUDE_PROJECT_DIR="$repo" PATROL_STALE="$STALE" bash "$hook" 2>/dev/null)"
jq_ok '⑦ pull 後 hook 不再指示 pull' "$hj3" '.hookSpecificOutput.additionalContext | test("git pull --ff-only origin main") | not'

# ---- ⑧ 全部乾淨時 --brief 印「巡檢：無異常」——把有異常的 worktree 移掉 ----
for n in LS-1 LS-2 LS-4 LS-5 LS-7; do
  g -C "$repo" worktree remove --force "$wts/$n" >/dev/null 2>&1 || { echo "✗ ⑧ 移除 worktree ${n} 失敗" >&2; fail=1; }
done
g -C "$repo" worktree prune
brief3="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '⑧ 全正常 → 末行「巡檢：無異常」' "$brief3" '巡檢：無異常'
hasnt '⑧ 全正常 → 無 ⚠' "$brief3" '⚠'

# ---- ⑨ .claude/settings.json 有把 hook 掛上（update-config skill 的 jq -e 驗法）----
if jq -e '.hooks.SessionStart[].hooks[] | select(.type == "command") | .command' "$settings" 2>/dev/null | grep -q 'scripts/ops/session-start.sh'; then
  echo "✓ ⑨ .claude/settings.json 的 SessionStart hook 指向 scripts/ops/session-start.sh"
else
  echo "✗ ⑨ .claude/settings.json 沒有掛 SessionStart → scripts/ops/session-start.sh（或 JSON 壞了）" >&2; fail=1
fi

# ---- ⑬ gate hooks 安裝檢查（LS-87 G5）：hooksPath 未設／設錯／hook 不可執行都標，裝回去就消失；hook 注入指示 ----
g -C "$repo" config --unset core.hooksPath
out13="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑬ hooksPath 未設定 → gate hooks 段 ⚠' "$out13" 'hooksPath=（未設定）  ⚠ core.hooksPath 未設定'
has   '⑬ 指示含設定指令' "$out13" 'git config core.hooksPath .githooks'
brief13="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '⑬ --brief 也印 [hooks]' "$brief13" '[hooks] ⚠'
json13="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '⑬ --json：hooks.path 空、flag 有句、flags 含一筆' "$json13" '.hooks.path == "" and (.hooks.flag | test("未設定")) and ([.flags[] | select(startswith("[hooks]"))] | length == 1)'
hj13="$(printf '{}' | CLAUDE_PROJECT_DIR="$repo" PATROL_STALE="$STALE" PATROL_FETCH_TIMEOUT=2 bash "$hook" 2>/dev/null)"
jq_ok '⑬ SessionStart hook：context 含 gate hooks 未裝好的指示' "$hj13" '.hookSpecificOutput.additionalContext | test("gate hooks 未裝好") and test("git config core.hooksPath .githooks")'
g -C "$repo" config core.hooksPath hooks-elsewhere
out13="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑬ hooksPath 設錯 → ⚠ 印現值' "$out13" 'core.hooksPath 是「hooks-elsewhere」而非 .githooks'
g -C "$repo" config core.hooksPath "$repo/.githooks"
out13="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
hasnt '⑬ hooksPath 為 repo 內 .githooks 的絕對路徑 → 也算裝好' "$out13" '[hooks]'
g -C "$repo" config core.hooksPath .githooks
chmod -x "$repo/.githooks/pre-push"
out13="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑬ pre-push 不可執行 → ⚠ 點名並指示 chmod +x' "$out13" '.githooks/pre-push 缺或不可執行 → chmod +x .githooks/pre-push'
hasnt '⑬ 其他兩支可執行 → 不點名' "$out13" '.githooks/pre-commit 缺'
rm -f "$repo/.githooks/commit-msg"
out13="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑬ commit-msg 缺檔 → 也標' "$out13" '.githooks/commit-msg 缺或不可執行'
has   '⑬ 兩支都標（以；連接）' "$out13" '.githooks/commit-msg 缺或不可執行 → chmod +x .githooks/commit-msg；⚠ .githooks/pre-push 缺或不可執行'
printf '#!/bin/sh\nexit 0\n' > "$repo/.githooks/commit-msg"; chmod +x "$repo/.githooks/commit-msg" "$repo/.githooks/pre-push"
out13="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
hasnt '⑬ 裝回去 → 不再標' "$out13" '[hooks]'
hj13="$(printf '{}' | CLAUDE_PROJECT_DIR="$repo" PATROL_STALE="$STALE" PATROL_FETCH_TIMEOUT=2 bash "$hook" 2>/dev/null)"
jq_ok '⑬ 裝好後 hook 不再指示' "$hj13" '.hookSpecificOutput.additionalContext | test("gate hooks 未裝好") | not'

# ---- ⑫ 三分支祖先鏈漂移（LS-85 G5；放在 ⑩ 之前——⑩ 之後 origin 指向黑洞，這裡要真的 fetch）----
# 現況：main 領先 development 1 commit（① 的 'main moves'，剛 commit）→ 未達 stale：不標、只印待 back-merge；test ⊂ development 成立
out12="$(bash "$patrol" --repo "$repo" --no-pr "$STALE" 2>&1)"
has   '⑫ main 剛領先 development（<stale）→ 印待 back-merge、不標' "$out12" '待 back-merge'
hasnt '⑫ 未達 stale 不標分支漂移' "$out12" '分支漂移'
has   '⑫ 三分支行印 test 不在 dev: 0' "$out12" 'test 不在 dev: 0'
json12="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '⑫ --json：test_not_in_development 0、main_ahead_minutes 數字且 <stale、drift 空' "$json12" '.branches.test_not_in_development == 0 and (.branches.main_ahead_minutes | type == "number") and .branches.main_ahead_minutes < 30 and .branches.drift == ""'
# main 再併入一個很老的 hotfix（first-parent 最早那筆超過 stale）→ ⚠ 分支漂移 main、指示 back-merge PR
echo h >> "$seed/file.txt"; gold -C "$seed" commit -qam 'chore: LS-0 old hotfix on main'; g -C "$seed" push -q origin main
out12="$(bash "$patrol" --repo "$repo" --no-pr "$STALE" 2>&1)"
has   '⑫ main 有老 commit 不在 development ≥ stale → ⚠ 分支漂移 main' "$out12" '⚠ 分支漂移：main 有 2 commit 不在 development'
has   '⑫ 指示 back-merge PR main→development' "$out12" '--head main --base development'
brief12="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '⑫ --brief 印漂移' "$brief12" '分支漂移：main'
json12="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '⑫ --json：development_behind_main 2、main_ahead_minutes ≥ stale、drift 有句、flags 含一筆' "$json12" '.branches.development_behind_main == 2 and .branches.main_ahead_minutes >= 30 and (.branches.drift | test("main 有 2 commit")) and ([.flags[] | select(test("分支漂移"))] | length == 1)'
# back-merge main→development（seed 先對齊 origin/development 再 merge、push）→ 漂移消失
g -C "$seed" fetch -q origin; g -C "$seed" checkout -q development; g -C "$seed" reset -q --hard origin/development
g -C "$seed" merge -q --no-edit main; g -C "$seed" push -q origin development
out12="$(bash "$patrol" --repo "$repo" --no-pr "$STALE" 2>&1)"
hasnt '⑫ back-merge 後不再標 main 漂移' "$out12" '分支漂移'
has   '⑫ back-merge 後 dev 落後 main: 0、祖先鏈 ok' "$out12" '祖先鏈 ok'
# test 被直接 push 一個 commit（test ⊄ development：舊式 back-merge／手動 push 的形狀）→ 立即 ⚠，不看時間
g -C "$seed" checkout -q test; echo t > "$seed/t.txt"; g -C "$seed" add -A; g -C "$seed" commit -qm 'chore: LS-0 direct push to test'
g -C "$seed" push -q origin test
out12="$(bash "$patrol" --repo "$repo" --no-pr "$STALE" 2>&1)"
has   '⑫ test 有 commit 不在 development → 立即 ⚠ 分支漂移 test' "$out12" '⚠ 分支漂移：test 有 1 commit 不在 development'
has   '⑫ 指示把 origin/test 併回 development' "$out12" 'backmerge-development'
json12="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '⑫ --json：test_not_in_development 1、drift 有句' "$json12" '.branches.test_not_in_development == 1 and (.branches.drift | test("test 有 1 commit"))'
# 把 test 併回 development（hotfix/LS-<n>-backmerge-development 的效果）→ 消失
g -C "$seed" checkout -q development; g -C "$seed" merge -q --no-edit test; g -C "$seed" push -q origin development
out12="$(bash "$patrol" --repo "$repo" --no-pr --brief "$STALE" 2>&1)"
hasnt '⑫ test 併回 development 後不再標' "$out12" '分支漂移'

# ---- ⑩ fetch 看門狗：origin 指向會永遠掛住的位址（ext:: 遠端 helper＝sleep），預設 10s 看門狗要在 ≤15s 內放行、exit 0、
#        印「fetch 逾時，用本機 ref 繼續」並照常巡檢（PR #99 R1：黑洞位址實測 75s，會把 hook 的 timeout 30 撐爆）----
g -C "$repo" config protocol.ext.allow always
g -C "$repo" remote set-url origin 'ext::sleep 30'
t0=$(date +%s); out10="$(bash "$patrol" --repo "$repo" --no-pr --brief "$STALE" 2>&1)"; rc=$?; t1=$(date +%s)
rc_is '⑩ fetch 掛住：預設看門狗仍 exit 0' 0 "$rc" "$out10"
if [ $((t1 - t0)) -le 15 ]; then echo "✓ ⑩ fetch 掛住：$((t1 - t0))s 內完成（≤15s）"; else echo "✗ ⑩ fetch 掛住：花了 $((t1 - t0))s（應 ≤15s）" >&2; fail=1; fi
has   '⑩ 印 fetch 逾時' "$out10" 'fetch 逾時'
has   '⑩ 印用本機 ref 繼續' "$out10" '用本機 ref 繼續'
has   '⑩ 逾時後仍照常巡檢（有表頭）' "$out10" '巡檢 '
json10="$(PATROL_FETCH_TIMEOUT=2 bash "$patrol" --repo "$repo" --no-pr --json "$STALE" 2>/dev/null)"
jq_ok '⑩ --json：fetched false、fetch_warning 有逾時句（PATROL_FETCH_TIMEOUT=2）' "$json10" '.fetched == false and (.fetch_warning | test("fetch 逾時"))'
hj10="$(printf '{}' | CLAUDE_PROJECT_DIR="$repo" PATROL_FETCH_TIMEOUT=2 bash "$hook" 2>/dev/null)"
jq_ok '⑩ hook：逾時句進 context、仍合法 JSON' "$hj10" '.hookSpecificOutput.additionalContext | test("fetch 逾時") and test("CronCreate")'
out11="$(PATROL_FETCH_TIMEOUT=abc bash "$patrol" --repo "$repo" --no-pr "$STALE" 2>&1)"; rc_is '⑩ PATROL_FETCH_TIMEOUT 非整數 → exit 2' 2 "$?" "$out11"

# ---- ⑪ Supabase lock 持有者（LS-70）：free／held／stale 進 human 與 --json，--brief 只在持有中印 ----
out11="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑪ human 模式有 Supabase lock 段' "$out11" '== Supabase lock'
has   '⑪ 未持有 → free' "$(printf '%s\n' "$out11" | sed -n '/== Supabase lock/{n;p;}')" 'free'
hasnt '⑪ --brief 未持有不印 lock 行' "$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)" 'Supabase lock'
mkdir -p "$SUPABASE_LOCK_DIR"
printf 'pid=%s\nstarted=%s\nhost=%s\nworktree=%s\nbranch=feature/LS-9-holder\ncmd=supabase db reset\n' "$$" "$(date +%s)" "$(hostname)" "$wts/LS-9" > "$SUPABASE_LOCK_DIR/holder"
out11="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑪ 持有中 → held pid=' "$out11" "held pid=$$"
has   '⑪ 持有中 → 顯示 cmd' "$out11" 'cmd=supabase db reset'
hasnt '⑪ 持有者活著 → lock 行不標 stale（表頭的「stale ≥」不算）' "$(printf '%s\n' "$out11" | sed -n '/== Supabase lock/{n;p;}')" 'stale'
brief11="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '⑪ --brief 持有中印 lock 行' "$brief11" 'Supabase lock：held'
json11="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '⑪ --json 合法且 supabase_lock 欄位為 held' "$json11" '.supabase_lock | test("held pid=")'
dead=$(sh -c 'echo $$')
printf 'pid=%s\nstarted=%s\nhost=%s\nworktree=/x\nbranch=b\ncmd=c\n' "$dead" "$(date +%s)" "$(hostname)" > "$SUPABASE_LOCK_DIR/holder"
has   '⑪ 持有者 pid 不存在 → 標 stale' "$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)" 'stale'
# 殘留 tomb（搬回失敗留下的 <lock>.stale.*）要看得到——§7 lock 列 ⚠️ 的反饋靠這裡（PR #122 R2 F2）
mkdir -p "$SUPABASE_LOCK_DIR.stale.1.2"
out11="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑪ 殘留 tomb → human 段列出 ⚠ tomb' "$out11" '⚠ tomb'
has   '⑪ 殘留 tomb → 列出目錄名' "$out11" "$(basename "$SUPABASE_LOCK_DIR").stale.1.2"
has   '⑪ 殘留 tomb → --brief 也印' "$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)" '⚠ tomb'
jq_ok '⑪ --json supabase_lock 含 tomb 行' "$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)" '.supabase_lock | test("tomb")'
rm -rf "$SUPABASE_LOCK_DIR" "$SUPABASE_LOCK_DIR.stale.1.2"

# ---- ⑭ 專屬模擬器 >7 天未用（LS-83）：xcrun 假身回固定 JSON，驗 lastBootedAt／目錄 mtime 兩種判定、
#        名稱不符 <票號>-<機型> 樣式（非 detect-simulator.sh 所建）不管、只列不刪＋印 simctl delete 指令、
#        --brief／--json 都看得到；xcrun 本身失敗（非 macOS／查詢出錯）fail-soft 不當異常炸掉 ----
mkdir -p "$work/bin" "$work/simdevs/SIM-OLDDIR/data"
touch -t "$OLD_T" "$work/simdevs/SIM-OLDDIR"   # 無 lastBootedAt 的裝置：靠這個目錄的 mtime 判老
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# 門檻兩側各取一個樣本才能釘住「-gt 7」這個確切數字（LS-83 R2 m4）：SIM-OLD／OLDDIR／LASTOLD 都老到
# 2020 年，就算門檻被誤改成 -gt 30 一樣會被判老，測不出退化；10 天前落在 7～30 之間，只有門檻真的是
# 7 天才會被列——門檻被改鬆（如 -gt 30）這條斷言就必須紅。
ten_days_epoch=$(( $(date +%s) - 10 * 86400 ))
ten_days_iso=$(date -u -r "$ten_days_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@${ten_days_epoch}" +%Y-%m-%dT%H:%M:%SZ)
esc_dpath=$(printf '%s' "$work/simdevs/SIM-OLDDIR/data" | sed 's/\//\\\//g')
cat > "$work/simdevices.json" <<JSON
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
      {
        "lastBootedAt" : "${now_iso}",
        "dataPath" : "\/tmp\/unused-fresh\/data",
        "udid" : "SIM-FRESH",
        "state" : "Shutdown",
        "name" : "LS-83-iPhone17Pro"
      },
      {
        "lastBootedAt" : "${OLD}",
        "dataPath" : "\/tmp\/unused-old\/data",
        "udid" : "SIM-OLD",
        "state" : "Shutdown",
        "name" : "LS-90-iPhoneAir"
      },
      {
        "dataPath" : "${esc_dpath}",
        "udid" : "SIM-OLDDIR",
        "state" : "Shutdown",
        "name" : "main-iPhone17"
      },
      {
        "lastBootedAt" : "${OLD}",
        "dataPath" : "\/tmp\/unused-other\/data",
        "udid" : "SIM-OTHER",
        "state" : "Shutdown",
        "name" : "iPhone 17 Pro"
      },
      {
        "lastBootedAt" : "${OLD}",
        "dataPath" : "\/tmp\/unused-lastold\/data",
        "udid" : "SIM-LASTOLD",
        "state" : "Shutdown",
        "name" : "LS-95-iPhoneAir"
      },
      {
        "lastBootedAt" : "${ten_days_iso}",
        "dataPath" : "\/tmp\/unused-10d\/data",
        "udid" : "SIM-10D",
        "state" : "Shutdown",
        "name" : "LS-97-iPhoneAir"
      }
    ]
  }
}
JSON
cat > "$work/bin/xcrun" <<STUB
#!/bin/bash
if [ -n "\${STUB_XCRUN_FAIL:-}" ]; then exit 1; fi
if [ "\$1" = simctl ] && [ "\$2" = list ] && [ "\$3" = devices ] && [ "\$4" = -j ]; then
  cat "$work/simdevices.json"
  exit 0
fi
exit 1
STUB
chmod +x "$work/bin/xcrun"

out14="$(SIMCTL_LIST_JSON= PATH="$work/bin:$PATH" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑭ 老裝置（lastBootedAt 超過 7 天）→ 列出並印 simctl delete' "$out14" 'LS-90-iPhoneAir（SIM-OLD）'
has   '⑭ 指令含 xcrun simctl delete SIM-OLD' "$out14" 'xcrun simctl delete SIM-OLD'
hasnt '⑭ 剛用過的（lastBootedAt 近期）不列' "$out14" 'SIM-FRESH'
has   '⑭ 無 lastBootedAt 退回目錄 mtime 判定為老 → 列出' "$out14" 'main-iPhone17（SIM-OLDDIR）'
has   '⑭ 10 天前（釘住門檻是 -gt 7；LS-83 R2 m4）→ 列出' "$out14" 'LS-97-iPhoneAir（SIM-10D）'
hasnt '⑭ 名稱不符 <票號>-<機型> 樣式不管' "$out14" 'SIM-OTHER'
# 陣列／檔案最後一台裝置（SIM-LASTOLD）之後還有多個收尾大括號（"]"／物件 "}"／外層 "}"）——awk 狀態機
# 印過一筆要清空，不然檔尾這些收尾大括號會把最後一筆重複印出（曾經的迴歸：只在最後一台裝置身上發生）
lastold_count=$(printf '%s' "$out14" | grep -c 'LS-95-iPhoneAir（SIM-LASTOLD）' || true)
if [ "$lastold_count" -eq 1 ]; then echo "✓ ⑭ 檔尾裝置（最後一筆）只列一次，不被收尾大括號重複印出"; else echo "✗ ⑭ 檔尾裝置列了 ${lastold_count} 次（應為 1）" >&2; fail=1; fi
brief14="$(SIMCTL_LIST_JSON= PATH="$work/bin:$PATH" bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '⑭ --brief 也看得到（掛 add_flag）' "$brief14" '[專屬模擬器 LS-90-iPhoneAir]'
has   '⑭ --brief 表頭「專屬模擬器逾期」數＝4（sim_flagged 有被讀，LS-83 R2 m2）' "$brief14" '專屬模擬器逾期 4'
json14="$(SIMCTL_LIST_JSON= PATH="$work/bin:$PATH" bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '⑭ --json：stale_simulators 只含四筆老裝置（SIM-OLD／SIM-OLDDIR／SIM-LASTOLD／SIM-10D），不含 SIM-FRESH（未超過門檻不列入）' "$json14" \
  '([.stale_simulators[].udid] | sort) == (["SIM-10D","SIM-LASTOLD","SIM-OLD","SIM-OLDDIR"] | sort)'
out14b="$(SIMCTL_LIST_JSON= STUB_XCRUN_FAIL=1 PATH="$work/bin:$PATH" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"; rc=$?
rc_is '⑭ xcrun 本身失敗（非 macOS／查詢出錯）→ 仍 exit 0，不當異常炸掉' 0 "$rc" "$out14b"
hasnt '⑭ xcrun 失敗時不誤列任何裝置' "$out14b" 'xcrun simctl delete'

# ---- ⑮ Booted 模擬器（LS-100）：demo-* 豁免；>1 台非豁免同時 Booted → 逐台 ⚠ 並印 shutdown 指令；
#        --brief／--json 都看得到。直接用 SIMCTL_LIST_JSON 餵合成 JSON（不必偽裝整支 xcrun）——
#        patrol.sh 讀 sim_raw 時「SIMCTL_LIST_JSON 有設就用它，沒設才真的呼叫 xcrun」。----
booted_json='{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
      {
        "udid" : "BOOT-A",
        "name" : "LS-90-iPhoneAir",
        "state" : "Booted"
      },
      {
        "udid" : "BOOT-B",
        "name" : "LS-95-iPhoneAir",
        "state" : "Booted"
      },
      {
        "udid" : "BOOT-DEMO",
        "name" : "demo-iPhone17Pro",
        "state" : "Booted"
      },
      {
        "udid" : "SHUT-C",
        "name" : "LS-97-iPhoneAir",
        "state" : "Shutdown"
      }
    ]
  }
}'
out15="$(SIMCTL_LIST_JSON="$booted_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑮ 兩台非 demo-* Booted → 各自列出並印 shutdown 指令' "$out15" '⚠ LS-90-iPhoneAir（BOOT-A）→ xcrun simctl shutdown BOOT-A'
has   '⑮ 第二台也列出' "$out15" '⚠ LS-95-iPhoneAir（BOOT-B）→ xcrun simctl shutdown BOOT-B'
hasnt '⑮ demo-* 豁免不列入 shutdown 建議' "$out15" 'shutdown BOOT-DEMO'
hasnt '⑮ Shutdown 狀態的裝置不列入' "$out15" 'SHUT-C'
brief15="$(SIMCTL_LIST_JSON="$booted_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '⑮ --brief 也印 Booted 異常（掛 add_flag）' "$brief15" '[Booted 模擬器 LS-90-iPhoneAir]'
has   '⑮ --brief 表頭含 Booted 異常數＝2' "$brief15" 'Booted 異常 2'
json15="$(SIMCTL_LIST_JSON="$booted_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '⑮ --json：booted_simulators 含三台 Booted（含 demo，exempt 各自標記正確）、booted_flagged=2' "$json15" \
  '(.booted_simulators | length) == 3 and .booted_flagged == 2
   and ([.booted_simulators[] | select(.name=="demo-iPhone17Pro") | .exempt] | first) == true
   and ([.booted_simulators[] | select(.name=="LS-90-iPhoneAir") | .exempt] | first) == false'

# ---- ⑯ 只有一台非 demo-* Booted（混一台 demo）→ 單台屬正常使用中，不算異常 ----
one_json='{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
      {
        "udid" : "BOOT-ONLY",
        "name" : "LS-101-iPhone17Pro",
        "state" : "Booted"
      },
      {
        "udid" : "BOOT-DEMO2",
        "name" : "demo-iPhone17Pro",
        "state" : "Booted"
      }
    ]
  }
}'
out16="$(SIMCTL_LIST_JSON="$one_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
hasnt '⑯ 只有一台非 demo-* Booted → 不標異常' "$out16" '[Booted 模擬器'
has   '⑯ 仍列出無異常摘要（Booted 2 台、非 demo-* 1 台）' "$out16" '無異常；Booted 2 台，非 demo-* 1 台'

# ---- ⑰ 完全沒有 Booted 裝置 → 該段顯示無異常 ----
none_json='{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
  {
    "udid" : "SHUT-ONLY",
    "name" : "LS-1-iPhoneAir",
    "state" : "Shutdown"
  }
]}}'
out17="$(SIMCTL_LIST_JSON="$none_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑰ 無 Booted 裝置 → 無異常（Booted 0 台）' "$out17" '無異常；Booted 0 台，非 demo-* 0 台'
brief17="$(SIMCTL_LIST_JSON="$none_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '⑰ --brief 表頭 Booted 異常數＝0' "$brief17" 'Booted 異常 0'

# ---- ⑱ Booted 模擬器命中鎖目錄（PR #164 R1 I1）：兩台非 demo-* Booted，其中一台的
#        /tmp/simulator-lock-<udid>（scripts/ops/simulator-lock.sh 用的同一個目錄命名慣例）存在，
#        代表 push-gate 正在跑 xcodebuild test——這台該標「鎖中，勿關」，不印 shutdown 建議；另一台
#        沒鎖，照常建議 shutdown。暫存鎖目錄用 $$ 帶出唯一性，避免與其他併行跑的自測互相干擾 ----
lock_udid="LOCKED-UDID-$$"
lockdir="/tmp/simulator-lock-${lock_udid}"
rm -rf "$lockdir"; mkdir -p "$lockdir"
locked_json='{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
      {
        "udid" : "BOOT-A",
        "name" : "LS-90-iPhoneAir",
        "state" : "Booted"
      },
      {
        "udid" : "'"$lock_udid"'",
        "name" : "main-iPhone17",
        "state" : "Booted"
      }
    ]
  }
}'
out18="$(SIMCTL_LIST_JSON="$locked_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑱ 鎖中的那台標「鎖中，勿關」' "$out18" "main-iPhone17（${lock_udid}）鎖中（push gate 進行中），勿關"
hasnt '⑱ 鎖中的那台不印 shutdown 建議' "$out18" "shutdown ${lock_udid}"
has   '⑱ 沒鎖的那台仍建議 shutdown' "$out18" '⚠ LS-90-iPhoneAir（BOOT-A）→ xcrun simctl shutdown BOOT-A'
brief18="$(SIMCTL_LIST_JSON="$locked_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '⑱ --brief 也印「鎖中」異常' "$brief18" '鎖中（push gate 進行中）——勿關'
rm -rf "$lockdir"

# ---- ⑲ --linear（LS-103）：串接 patrol-linear.sh；合成 repo 沒有 .env，所以只驗「有串接、優雅略過」，
#        不驗 Linear 查詢邏輯本身（那是 patrol-linear.test.sh 的範圍）。--json 與 --linear 合併時只警告、
#        不破壞 --json 單一物件的契約（stdout 仍是合法 JSON，warning 走 stderr）----
out19="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --linear "$STALE" 2>&1)"
has '⑲ --linear human 模式串接 patrol-linear.sh（無 .env → 印略過）' "$out19" '略過（無 LINEAR_API_KEY）'
brief19="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief --linear "$STALE" 2>&1)"
has '⑲ --linear --brief 也串接（略過訊息仍在）' "$brief19" '略過（無 LINEAR_API_KEY）'
json19_err="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json --linear "$STALE" 2>&1 1>/dev/null)"
has '⑲ --linear 與 --json 合併只警告（不支援合併）' "$json19_err" '不支援合併'
json19_out="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json --linear "$STALE" 2>/dev/null)"
if printf '%s' "$json19_out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  echo "✓ ⑲ --linear --json 的 stdout 仍是合法單一 JSON 物件"
else
  echo "✗ ⑲ --linear --json 的 stdout 不是合法 JSON" >&2; printf '%s\n' "$json19_out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑳ R1 F6：patrol-linear.sh 非 0 exit 不可被吞——PATROL_LINEAR_SH 換一支假身模擬失敗，
#        brief 摘要行不得再宣稱「無異常」，且 stdout 要看得到「Linear 半段失敗」----
fake_plsh="$work/bin/fake-patrol-linear.sh"
mkdir -p "$work/bin"
cat > "$fake_plsh" <<'EOF'
#!/bin/bash
echo "模擬 Linear 段炸掉" >&2
exit 7
EOF
chmod +x "$fake_plsh"
out20="$(PATROL_LINEAR_SH="$fake_plsh" bash "$patrol" --repo "$repo" --no-pr --no-fetch --linear "$STALE" 2>&1)"
has   '⑳ human 模式印出 Linear 半段失敗（exit 7）' "$out20" 'Linear 半段失敗（exit 7）'
brief20="$(PATROL_LINEAR_SH="$fake_plsh" bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief --linear "$STALE" 2>&1)"
hasnt '⑳ --brief 不得再宣稱「巡檢：無異常」（Linear 段已失敗）' "$brief20" '巡檢：無異常'
has   '⑳ --brief 摘要行含 [Linear] 段失敗 flag' "$brief20" '[Linear] 段失敗（exit 7）'
json20_out="$(PATROL_LINEAR_SH="$fake_plsh" bash "$patrol" --repo "$repo" --no-pr --no-fetch --json --linear "$STALE" 2>/dev/null)"
if printf '%s' "$json20_out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  echo "✓ ⑳ --json（與 --linear 合併時）仍是合法 JSON——json 模式本就不跑 Linear 段，不受影響"
else
  echo "✗ ⑳ --json 不是合法 JSON" >&2; printf '%s\n' "$json20_out" | sed 's/^/    /' >&2; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ patrol／session-start 自測通過"
fi
exit "$fail"
