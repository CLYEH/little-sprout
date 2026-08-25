#!/bin/bash
# patrol.sh／session-start.sh 的自測（LS-71）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對巡檢本身也適用：若判定退化——拿 base commit 的時間當「最後 commit」把新 worktree 誤判成
# 停滯（scratchpad 原型的 bug）、領先 remote／從未 push／dirty 停滯／尚未開工／主 checkout 落後任一漏標、
# 三分支漂移漏標（test ⊄ development 立即、main ⊄ development 超過 stale）或剛併入的 hotfix 被誤標（LS-85）、
# 乾淨或剛建好的 worktree 被誤標、保護分支或 detached worktree 混進表、--json 不合法、gh 不可用整支炸掉、
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
hasnt '① LS-7 不得誤標尚未開工' "$l7" '尚未開工'
hasnt '① LS-5 沒動過 → 不是已併入' "$l5" '已併入'
l8=$(row "$out" 'feature/LS-8-gone')
has   '① LS-8 目錄不存在 → 標 prune' "$l8" '目錄不存在'
hasnt '① 保護分支 worktree 不進表' "$out" 'dev-wt'
has   '① detached worktree 只標略過、不炸' "$out" 'detached，略過'

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

if [ "$fail" -eq 0 ]; then
  echo "✓ patrol／session-start 自測通過"
fi
exit "$fail"
