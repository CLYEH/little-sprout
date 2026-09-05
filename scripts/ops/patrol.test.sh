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
# LS-176：磁碟水位段預設門檻 20 GB——CI runner／開發機當下可用空間可能真的低於 20 GB，不隔離的話 ⑧「全正常無 ⚠」
# 這類既有斷言會隨機器狀態偶發紅。統一設成 0（永不觸發），㉑ 自己在呼叫時覆寫門檻與兩個目錄。
export PATROL_DISK_MIN_GB=0
# LS-180：Pencil 連線探針段只在有 design 分支 worktree 時跑 pen-status.sh——它會 pgrep／lsof／pen CLI 探真的 Pen；自測
# 一律指到假身（㉒ 自己再換成受控的假身），不碰本機真正的 Pen。
export PATROL_PEN_STATUS_SH="$work/fake-pen-status.sh"
printf '#!/bin/bash\necho "Pencil：（自測假身）"\nexit 0\n' > "$PATROL_PEN_STATUS_SH"
# LS-187：專屬模擬器段每輪都量 CoreSimulator/Devices 體積（du 快取）——自測一律指到小假目錄與自己的快取檔，不對真的
# ~/Library 跑 du（本機實測 18 秒）、不碰 /tmp 的真快取；LINEAR_API_KEY 一開始 unset（㉓ 的 --linear 案例用假身，不打真 API）。
mkdir -p "$work/fake-devices-default"
export PATROL_SIM_DEVICES_DIR="$work/fake-devices-default" PATROL_DU_CACHE="$work/du-cache"
unset LINEAR_API_KEY

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

# ---- ⑪-b QA 持有 hold（LS-159）：holder `cmd=hold:<label>` → human／--brief 印「持有中（label，剩餘 n 分）」、
#        --json 多 hold_label／hold_expires_at；命令型持有（上面 ⑪ 的 json11）兩欄為 null ----
jq_ok '⑪-b 命令型持有 → --json hold_label／hold_expires_at 為 null' "$json11" '.hold_label == null and .hold_expires_at == null'
mkdir -p "$SUPABASE_LOCK_DIR"
exp11=$(( $(date +%s) + 600 ))
printf 'pid=%s\nstarted=%s\nhost=%s\nworktree=%s\nbranch=test\ncmd=hold:LS-9 QA 冒煙\nowner=%s\nexpires_at=%s\nheartbeat=%s\n' "$$" "$(date +%s)" "$(hostname)" "$wts/LS-9" "$$" "$exp11" "$(date +%s)" > "$SUPABASE_LOCK_DIR/holder"
out11="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑪-b hold → human 段印 持有中（label，剩餘 n 分）' "$out11" '持有中（LS-9 QA 冒煙，剩餘 10 分）'
has   '⑪-b hold → --brief 也印 label' "$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)" 'Supabase lock：held pid='
has   '⑪-b hold → --brief 含 持有中' "$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)" '持有中（LS-9 QA 冒煙'
jq_ok '⑪-b --json hold_label／hold_expires_at 來自 holder 檔' "$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)" ".hold_label == \"LS-9 QA 冒煙\" and .hold_expires_at == ${exp11}"
rm -rf "$SUPABASE_LOCK_DIR"

# ---- ⑪-c LS-207（ca35c579）：排隊可見化——<lock 路徑>.waiters/ 有檔且持有者剩餘 >10 分才印 ⚠ 排隊 ----
mkdir -p "$SUPABASE_LOCK_DIR"
exp11c=$(( $(date +%s) + 900 ))   # 剩餘 15 分（>10 門檻）
printf 'pid=%s\nstarted=%s\nhost=%s\nworktree=%s\nbranch=test\ncmd=hold:LS-9 排隊測試\nowner=%s\nexpires_at=%s\nheartbeat=%s\n' "$$" "$(date +%s)" "$(hostname)" "$wts/LS-9" "$$" "$exp11c" "$(date +%s)" > "$SUPABASE_LOCK_DIR/holder"
out11c="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
hasnt '⑪-c 無等待者 → 不印 ⚠ 排隊' "$out11c" '⚠ 排隊'
jq_ok '⑪-c 無等待者 → --json lock_waiters=0' "$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)" '.lock_waiters == 0 and .lock_waiters_max_minutes == 0'
mkdir -p "${SUPABASE_LOCK_DIR}.waiters"
now_e=$(date +%s)
# 起始秒數故意避開整分邊界（ceil((now-started)/60) 在邊界上差 1 秒就跳一分鐘，710／170 各留 10s 緩衝）
: > "${SUPABASE_LOCK_DIR}.waiters/LS-20-11111-$(( now_e - 710 ))"   # 等了 12 分（660< 710 ≤720）
: > "${SUPABASE_LOCK_DIR}.waiters/LS-21-22222-$(( now_e - 170 ))"   # 等了 3 分（120< 170 ≤180）
out11c="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑪-c 有 2 個等待者、持有者剩餘 >10 分 → 印 ⚠ 排隊 2（最久 12 分）' "$out11c" '⚠ 排隊 2（最久 12 分）'
has   '⑪-c ⚠ 排隊行含持有者 label 與剩餘分鐘' "$out11c" '持有者「LS-9 排隊測試」剩餘'
has   '⑪-c --brief 也印 ⚠ 排隊' "$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)" '⚠ 排隊 2（最久 12 分）'
json11c="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '⑪-c --json lock_waiters／lock_waiters_max_minutes 正確' "$json11c" '.lock_waiters == 2 and .lock_waiters_max_minutes == 12'
jq_ok '⑪-c --json flags 含 ⚠ 排隊' "$json11c" '.flags | any(test("⚠ 排隊"))'
# 持有者剩餘 ≤10 分（門檻不含等於）→ 即使有等待者也不印，避免快到期時洗版
exp11c2=$(( $(date +%s) + 600 ))
printf 'pid=%s\nstarted=%s\nhost=%s\nworktree=%s\nbranch=test\ncmd=hold:LS-9 排隊測試\nowner=%s\nexpires_at=%s\nheartbeat=%s\n' "$$" "$(date +%s)" "$(hostname)" "$wts/LS-9" "$$" "$exp11c2" "$(date +%s)" > "$SUPABASE_LOCK_DIR/holder"
hasnt '⑪-c 持有者剩餘 10 分（未超過門檻）→ 不印 ⚠ 排隊' "$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)" '⚠ 排隊'
rm -rf "${SUPABASE_LOCK_DIR}.waiters"
# 命令型持有（無 expires_at）即使殘留 waiters/ 也不印——沒有「剩餘分鐘」可比
mkdir -p "${SUPABASE_LOCK_DIR}.waiters"
: > "${SUPABASE_LOCK_DIR}.waiters/LS-22-33333-$(( $(date +%s) - 60 ))"
printf 'pid=%s\nstarted=%s\nhost=%s\nworktree=%s\nbranch=feature/LS-9-holder\ncmd=supabase db reset\n' "$$" "$(date +%s)" "$(hostname)" "$wts/LS-9" > "$SUPABASE_LOCK_DIR/holder"
hasnt '⑪-c 命令型持有（無到期時間）→ 不印 ⚠ 排隊' "$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)" '⚠ 排隊'
rm -rf "$SUPABASE_LOCK_DIR" "${SUPABASE_LOCK_DIR}.waiters"

# ---- ⑭ 專屬模擬器 >7 天未用（LS-83；LS-187 起為第二層）：xcrun 假身回固定 JSON，驗 lastBootedAt／目錄 mtime 兩種判定、
#        名稱不符 <票號>-<機型> 樣式（非 detect-simulator.sh 所建）不管、只列不刪＋印 simctl delete 指令、
#        --brief／--json 都看得到；xcrun 本身失敗（非 macOS／查詢出錯）fail-soft 不當異常炸掉 ----
# LS-187：第一層先看「票 worktree 還在不在」——這裡的 LS-83／90／95／97 都要有 worktree，才輪得到第二層的 >7 天判定
# （否則全被判成殘機、動作行變 cleanup-merged，⑭ 就測不到 -gt 7 門檻）；殘機案例在 ㉓。
for n in 83 90 95 97; do wt -b "feature/LS-${n}-sim" "$wts/LS-${n}" origin/development; done
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
has   '⑭ --brief 表頭「專屬模擬器待清」數＝4、殘機 0（sim_flagged 有被讀，LS-83 R2 m2；LS-187 改名）' "$brief14" '專屬模擬器待清 4（殘機 0）'
json14="$(SIMCTL_LIST_JSON= PATH="$work/bin:$PATH" bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '⑭ --json：stale_simulators 只含四筆老裝置（SIM-OLD／SIM-OLDDIR／SIM-LASTOLD／SIM-10D），不含 SIM-FRESH（未超過門檻不列入）' "$json14" \
  '([.stale_simulators[].udid] | sort) == (["SIM-10D","SIM-LASTOLD","SIM-OLD","SIM-OLDDIR"] | sort)'
out14b="$(SIMCTL_LIST_JSON= STUB_XCRUN_FAIL=1 PATH="$work/bin:$PATH" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"; rc=$?
rc_is '⑭ xcrun 本身失敗（非 macOS／查詢出錯）→ 仍 exit 0，不當異常炸掉' 0 "$rc" "$out14b"
hasnt '⑭ xcrun 失敗時不誤列任何裝置' "$out14b" 'xcrun simctl delete'

# ---- ⑭b（LS-205；merge-review R1 M1 訂正）：`.ios-runtime` 釘住版與裝置實際 runtime 不一致 →
#        獨立標「⚠ runtime」細項＋獨立計數 `sim_rt_mismatch`，跟第一層／第二層清理判斷互不影響（票
#        worktree 還在、剛用過，兩層都不會標，只有這裡的新訊號會標）——**不進 `sim_flagged`（「待清」
#        語意）、不叫 `add_flag`（`--brief`「巡檢：無異常」與 flag 清單都靠它，併入後本機幾乎必然
#        runtime ≠ 釘住版，若算進去「無異常」會永久消失、且無法行動：本機沒有那個 runtime 就是沒有）。
#        相符的那台不印任何東西（迴歸防呆）。另建一張票（LS-201）的 worktree，避免動到 ⑭ 對 LS-83／90／95／97
#        既有斷言依賴的裝置清單；`rm -f` 還原，讓後面案例維持「無 .ios-runtime」的既有假設（pinned_os 為空、
#        本檢查整段跳過）。
for n in 201; do wt -b "feature/LS-${n}-runtime" "$wts/LS-${n}" origin/development; done
printf '26.5\n' > "$repo/.ios-runtime"
rt_json=$(cat <<JSON
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
      {
        "lastBootedAt" : "${now_iso}",
        "dataPath" : "\/tmp\/unused-rtmismatch\/data",
        "udid" : "SIM-RT-MISMATCH",
        "state" : "Shutdown",
        "name" : "LS-201-iPhone17Pro"
      }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
      {
        "lastBootedAt" : "${now_iso}",
        "dataPath" : "\/tmp\/unused-rtmatch\/data",
        "udid" : "SIM-RT-MATCH",
        "state" : "Shutdown",
        "name" : "LS-201-iPhoneAir"
      }
    ]
  }
}
JSON
)
outRT="$(SIMCTL_LIST_JSON="$rt_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑭b runtime 不符釘住版標「⚠ runtime」細項（提示不擋，不計入待清）' "$outRT" '⚠ runtime LS-201-iPhone17Pro（SIM-RT-MISMATCH）iOS 26.0 ≠ 釘住版 iOS 26.5（提示不擋，不計入待清）'
hasnt '⑭b runtime 相符的那台不標' "$outRT" 'LS-201-iPhoneAir（SIM-RT-MATCH）iOS'
briefRT="$(SIMCTL_LIST_JSON="$rt_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '⑭b（M1 訂正）--brief 表頭獨立顯示「runtime 不一致 1」（釘住版字樣）' "$briefRT" '· runtime 不一致 1（釘住 iOS 26.5，提示不擋） ·'
hasnt '⑭b（M1 訂正）runtime 不一致不進 add_flag／flag 清單（不是「[專屬模擬器 …] runtime …」這種 flag 行）' "$briefRT" '[專屬模擬器 LS-201-iPhone17Pro] runtime'
has   '⑭b（M1 訂正）--brief 表頭「專屬模擬器待清」不受 runtime 不一致影響，仍是 0' "$briefRT" '專屬模擬器待清 0（殘機 0）'

# ---- ⑭c（merge-review R1 M1 具體重現案例）：同一台機器**同時**是「殘機」（無 worktree）又「runtime
#        不一致」——修法之前這台會被算兩次（`sim_flagged` 待清數 2）；修法之後只有「殘機」那個真正
#        可行動的原因算進待清，runtime 不一致獨立計數，兩者互不重複疊加。
db14c='{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
      {
        "lastBootedAt" : "'"${OLD}"'",
        "dataPath" : "\/tmp\/unused-ls9999\/data",
        "udid" : "SIM-LS9999",
        "state" : "Shutdown",
        "name" : "LS-9999-iPhone17Pro"
      }
    ]
  }
}'
printf '26.2\n' > "$repo/.ios-runtime"
out14c="$(SIMCTL_LIST_JSON="$db14c" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑭c 殘機那條原因照常列（可行動，計入待清）' "$out14c" 'LS-9999-iPhone17Pro（SIM-LS9999）票 LS-9999 的 worktree 已不在（殘機） → bash scripts/ops/cleanup-merged.sh --apply LS-9999'
has   '⑭c runtime 不一致細項也照常列（不可行動，獨立於待清）' "$out14c" '⚠ runtime LS-9999-iPhone17Pro（SIM-LS9999）iOS 26.0 ≠ 釘住版 iOS 26.2（提示不擋，不計入待清）'
brief14c="$(SIMCTL_LIST_JSON="$db14c" bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '⑭c（M1 具體重現）同一台機器不被算成 2——待清仍是 1（不是 2），runtime 不一致獨立顯示 1' "$brief14c" '專屬模擬器待清 1（殘機 1） · runtime 不一致 1（釘住 iOS 26.2，提示不擋）'
has   '⑭c 殘機仍照常掛 add_flag（真正可行動的原因不受影響）' "$brief14c" '[專屬模擬器 LS-9999-iPhone17Pro] 票 LS-9999 的 worktree 已不在（殘機） → bash scripts/ops/cleanup-merged.sh --apply LS-9999'
hasnt '⑭c runtime 不一致本身仍不進 flag 清單' "$brief14c" '[專屬模擬器 LS-9999-iPhone17Pro] runtime'
rm -f "$repo/.ios-runtime"

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

# ---- ㉑ 磁碟水位（LS-176）：門檻設成必觸發（999999 GB）→ human／--brief／--json 都標 ⚠、列 Devices／DerivedData 體積
#        （PATROL_SIM_DEVICES_DIR／PATROL_DERIVED_DATA_DIR 指到小假目錄，不對真的 ~/Library 跑 du）與 LS-* 專屬模擬器
#        台數（從 SIMCTL_LIST_JSON 算；main-*／原廠機不算）；門檻 0（永不觸發）→ 不標、不 du（json devices_gb null）、
#        但仍印一行可用量＋台數；門檻非整數 → exit 2。mutation：閾值比較方向反了、台數把 main-* 算進去、
#        ⚠ 沒掛 add_flag（brief／json 看不到）→ 這裡紅 ----
mkdir -p "$work/fake-devices/A" "$work/fake-dd/LittleSprout-x"
echo data > "$work/fake-devices/A/f"; echo data > "$work/fake-dd/LittleSprout-x/f"
disk_json='{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
      {
        "udid" : "D1",
        "name" : "LS-90-iPhoneAir",
        "state" : "Shutdown"
      },
      {
        "udid" : "D2",
        "name" : "LS-176-iPhone17Pro",
        "state" : "Shutdown"
      },
      {
        "udid" : "D3",
        "name" : "main-iPhone17Pro",
        "state" : "Shutdown"
      },
      {
        "udid" : "D4",
        "name" : "iPhone 17 Pro",
        "state" : "Shutdown"
      }
    ]
  }
}'
out21="$(SIMCTL_LIST_JSON="$disk_json" PATROL_DISK_MIN_GB=999999 PATROL_SIM_DEVICES_DIR="$work/fake-devices" PATROL_DERIVED_DATA_DIR="$work/fake-dd" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"; rc=$?
rc_is '㉑ 低於門檻仍 exit 0' 0 "$rc" "$out21"
has   '㉑ human 模式有磁碟水位段' "$out21" '== 磁碟水位'
has   '㉑ 低於門檻 → ⚠ 磁碟可用 … < 999999 GB' "$out21" 'GB < 999999 GB'
has   '㉑ 列 CoreSimulator/Devices 體積（假目錄 0 GB）' "$out21" 'CoreSimulator/Devices 0 GB'
has   '㉑ 列 DerivedData 體積' "$out21" 'DerivedData 0 GB'
has   '㉑ 列 LS-* 專屬模擬器台數＝2（main-*／原廠機不算）' "$out21" 'LS-* 專屬模擬器 2 台'
has   '㉑ 處置指到 cleanup-merged.sh --apply' "$out21" 'cleanup-merged.sh --apply LS-<n>'
brief21="$(SIMCTL_LIST_JSON="$disk_json" PATROL_DISK_MIN_GB=999999 PATROL_SIM_DEVICES_DIR="$work/fake-devices" PATROL_DERIVED_DATA_DIR="$work/fake-dd" bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '㉑ --brief 也印 [磁碟]（掛 add_flag）' "$brief21" '[磁碟] ⚠ 磁碟可用'
has   '㉑ --brief 表頭含磁碟可用' "$brief21" '· 磁碟可用 '
json21="$(SIMCTL_LIST_JSON="$disk_json" PATROL_DISK_MIN_GB=999999 PATROL_SIM_DEVICES_DIR="$work/fake-devices" PATROL_DERIVED_DATA_DIR="$work/fake-dd" bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '㉑ --json：disk 欄位（avail_gb 數字、min_gb 999999、devices_gb／derived_data_gb 數字、dedicated_simulators 2、flag 有句、flags 含一筆 [磁碟]）' "$json21" \
  '(.disk.avail_gb | type == "number") and .disk.min_gb == 999999 and (.disk.devices_gb | type == "number") and (.disk.derived_data_gb | type == "number") and .disk.dedicated_simulators == 2 and (.disk.flag | test("磁碟可用")) and ([.flags[] | select(startswith("[磁碟]"))] | length == 1)'
out21b="$(SIMCTL_LIST_JSON="$disk_json" PATROL_DISK_MIN_GB=0 PATROL_SIM_DEVICES_DIR="$work/fake-devices" PATROL_DERIVED_DATA_DIR="$work/fake-dd" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
hasnt '㉑ 高於門檻（門檻 0）→ 不標 ⚠ 磁碟' "$out21b" '⚠ 磁碟可用'
has   '㉑ 高於門檻仍印一行可用量與台數  ok' "$out21b" 'LS-* 專屬模擬器 2 台  ok'
brief21b="$(SIMCTL_LIST_JSON="$disk_json" PATROL_DISK_MIN_GB=0 bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
hasnt '㉑ 高於門檻 --brief 無 [磁碟]' "$brief21b" '[磁碟]'
json21b="$(SIMCTL_LIST_JSON="$disk_json" PATROL_DISK_MIN_GB=0 bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
# LS-187：devices_gb 改為每輪都有（專屬模擬器段末尾要印，走 du 快取）；「沒跑水位段 du」改看 derived_data_gb 仍 null
jq_ok '㉑ 高於門檻 --json：disk.flag 空、derived_data_gb null（沒跑水位段 du）、devices_gb 數字（LS-187 每輪都有）、flags 無 [磁碟]' "$json21b" '.disk.flag == "" and .disk.derived_data_gb == null and (.disk.devices_gb | type == "number") and ([.flags[] | select(startswith("[磁碟]"))] | length == 0)'
out21c="$(PATROL_DISK_MIN_GB=abc bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"; rc_is '㉑ PATROL_DISK_MIN_GB 非整數 → exit 2' 2 "$?" "$out21c"

# ---- ㉒ Pencil 連線探針（LS-180）：只在有 design 分支 worktree 時跑 pen-status.sh；探針非 0 → [Pencil] flag（human／
#        brief／json 都帶、指示 /mcp 重連）；0 → 只印一行不標；沒有 design worktree → 略過、不呼叫探針；探針腳本不存在
#        → 標 [Pencil] 說明 ----
out22a="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '㉒ 無 design 分支 worktree → Pencil 段印略過' "$out22a" '無 design 分支 worktree，略過探針'
hasnt '㉒ 無 design worktree 不呼叫探針（假身輸出不出現）' "$out22a" '（自測假身）'
json22a="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '㉒ --json 無 design worktree：pencil.ran false、line null' "$json22a" '.pencil.ran == false and .pencil.line == null'
wt -b feature/LS-9-flow-design "$wts/LS-9" origin/development
fake_ps_bad="$work/fake-pen-status-bad.sh"
printf '#!/bin/bash\necho "Pencil：行程 ✓（pid 1） · 路徑 /x/design/littlesprout.pen · MCP 探針 ✗（mcp-server 1 支皆無 Pen socket 連線——在 Claude Code 執行 /mcp 重連 pencil）"\nexit 1\n' > "$fake_ps_bad"
out22="$(PATROL_PEN_STATUS_SH="$fake_ps_bad" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"; rc=$?
rc_is '㉒ 探針 ✗ 仍 exit 0（異常在輸出）' 0 "$rc" "$out22"
has   '㉒ human 有 Pencil 段' "$out22" '== Pencil 連線'
has   '㉒ human 印探針行' "$out22" 'MCP 探針 ✗'
has   '㉒ human 探針非 0 → 段內指示派工前 /mcp 重連' "$out22" '→ 設計票派工前先請使用者在 Claude Code 執行 /mcp 重連 pencil'
brief22="$(PATROL_PEN_STATUS_SH="$fake_ps_bad" bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '㉒ --brief 印探針行' "$brief22" 'Pencil：行程 ✓（pid 1）'
has   '㉒ --brief 探針非 0 → [Pencil] flag 帶探針行' "$brief22" '[Pencil] Pencil：行程 ✓（pid 1）'
has   '㉒ --brief flag 指示派工前 /mcp 重連' "$brief22" '設計票派工前先請使用者在 Claude Code 執行 /mcp 重連 pencil'
json22="$(PATROL_PEN_STATUS_SH="$fake_ps_bad" bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '㉒ --json：pencil.ran true、rc 1、line 含探針、flags 恰一筆 [Pencil]' "$json22" \
  '.pencil.ran == true and .pencil.rc == 1 and (.pencil.line | test("MCP 探針")) and ([.flags[] | select(startswith("[Pencil]"))] | length == 1)'
out22b="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '㉒ 探針 0 → 印一行（預設假身）' "$out22b" '（自測假身）'
hasnt '㉒ 探針 0 → 不標 [Pencil]' "$out22b" '[Pencil]'
json22b="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '㉒ --json 探針 0：pencil.ran true、rc 0、無 [Pencil] flag' "$json22b" '.pencil.ran == true and .pencil.rc == 0 and ([.flags[] | select(startswith("[Pencil]"))] | length == 0)'
out22c="$(PATROL_PEN_STATUS_SH="$work/does-not-exist.sh" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '㉒ 探針腳本不存在 → 段內說明並指示重連' "$out22c" 'Pencil：探針腳本不存在'
brief22c="$(PATROL_PEN_STATUS_SH="$work/does-not-exist.sh" bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '㉒ 探針腳本不存在 → --brief 標 [Pencil]' "$brief22c" '[Pencil] Pencil：探針腳本不存在'

# ---- ㉓ 專屬模擬器第一層（LS-187；使用者 2026-09-05 指出 4 台 Done 票殘機——Done 後 7 天內、皆 Shutdown——巡檢 20+ 輪沒抓）：
#        (a) LS-999 Shutdown、剛用過、票 worktree 不在 → ⚠＋動作行 `→ bash scripts/ops/cleanup-merged.sh --apply LS-999`
#        （human／--brief flag／--json orphan_simulators）；(b) LS-3 同樣剛用過但 worktree 在（In Progress）→ 不 ⚠；
#        (c) LS-998 Booted、worktree 不在 → 不列刪、不進 flag（LS-100 規則），只印 ⓘ；main-*／demo-*／qa-* 不進第一層；
#        段末印「Xcode 預設模擬器 m 台」（名稱非 LS-/main-/demo-/qa- 開頭）＋ Devices 體積；--linear 時 worktree 仍在的票
#        走 patrol-linear.sh --closed 查狀態（假身）：回 Done → ⚠（worktree 仍在）；假身 exit 3（無 key）→ 只用 worktree 判定
#        並在段末註明；不帶 --linear → 註明「未查」。du 快取：human 量一次寫快取、下一輪沿用；--brief 不量。
#        mutation：第一層拿掉（回到只看 >7 天）→ (a) 紅；Booted 也列刪 → (c) 紅；worktree 判定退化成子字串 → 「裝置 LS-4、
#        worktree 只有 LS-40」這案紅（子字串會把 LS-40 當成 LS-4 的 worktree 而不 ⚠；R1 minor-1：LS-3 對 LS-30 那個方向
#        子字串也對不上、沒鑑別力，故補這個短票號對長 worktree 的方向）----
# 裝置 LS-4-* 的票 LS-4 沒有 worktree（⑧ 已移除），但 LS-40 有——整字比對必須判 LS-4「不在」；反向 LS-40-* 有 LS-40 → 「在」
wt -b feature/LS-40-sim "$wts/LS-40" origin/development
# patrol.sh 的 awk 解析器認 simctl 的 pretty-print（一行一個 key）——fixture 必須同形，不能把一台寫成一行
sim_dev() {  # $1=udid $2=state $3=name [$4=lastBootedAt，省略＝無此欄]
  printf '      {\n'
  [ -n "${4:-}" ] && printf '        "lastBootedAt" : "%s",\n' "$4"
  printf '        "udid" : "%s",\n        "state" : "%s",\n        "name" : "%s"\n      }' "$1" "$2" "$3"
}
orphan_json="{
  \"devices\" : {
    \"com.apple.CoreSimulator.SimRuntime.iOS-26-0\" : [
$(sim_dev ORPH-999 Shutdown LS-999-iPhone17Pro "$now_iso"),
$(sim_dev ORPH-30 Shutdown LS-30-iPhone17Pro "$now_iso"),
$(sim_dev ORPH-4 Shutdown LS-4-iPhone17Pro "$now_iso"),
$(sim_dev LIVE-40 Shutdown LS-40-iPhone17Pro "$now_iso"),
$(sim_dev LIVE-3 Shutdown LS-3-iPhone17Pro "$now_iso"),
$(sim_dev BOOT-998 Booted LS-998-iPhone17Pro "$now_iso"),
$(sim_dev MAIN-1 Shutdown main-iPhone17Pro "$now_iso"),
$(sim_dev DEMO-1 Shutdown demo-iPhone17Pro "$now_iso"),
$(sim_dev QA-1 Shutdown qa-LS98-iPhone17ProMax "$now_iso"),
$(sim_dev DEF-1 Shutdown 'iPhone 17 Pro' "$now_iso"),
$(sim_dev DEF-2 Shutdown 'iPad Pro 13-inch (M4)')
    ]
  }
}"
rm -f "$PATROL_DU_CACHE"
out23="$(SIMCTL_LIST_JSON="$orphan_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"; rc=$?
rc_is '㉓ 有殘機仍 exit 0（異常在輸出）' 0 "$rc" "$out23"
has   '㉓ (a) Done 票殘機 LS-999（worktree 不在）→ ⚠' "$out23" '⚠ LS-999-iPhone17Pro（ORPH-999）票 LS-999 的 worktree 已不在（殘機）'
has   '㉓ (a) 動作行指到 cleanup-merged.sh --apply LS-999' "$out23" '→ bash scripts/ops/cleanup-merged.sh --apply LS-999'
has   '㉓ LS-30 殘機（LS-3 的 worktree 不能整字命中 LS-30）→ ⚠' "$out23" 'cleanup-merged.sh --apply LS-30'
# R1 minor-1：有鑑別力的方向——裝置 LS-4、worktree 只有 LS-40：整字比對 → LS-4 無 worktree → ⚠；子字串會把 LS-40 當成 LS-4 的 → 不 ⚠ → 這裡紅
if printf '%s\n' "$out23" | grep -qE -- '⚠ LS-4-iPhone17Pro（ORPH-4）票 LS-4 的 worktree 已不在（殘機） → bash scripts/ops/cleanup-merged.sh --apply LS-4$'; then echo "✓ ㉓ 裝置 LS-4 對 worktree LS-40：整字比對不把 LS-40 當成 LS-4 的 worktree → ⚠＋動作行 --apply LS-4"; else echo "✗ ㉓ 裝置 LS-4 應被判殘機（worktree 只有 LS-40）——整字比對退化成子字串？" >&2; printf '%s\n' "$out23" | sed 's/^/    /' >&2; fail=1; fi
if printf '%s\n' "$out23" | grep -qE -- '--apply LS-40$'; then echo "✗ ㉓ 反向：LS-40-* 有 LS-40 worktree，不該有動作行" >&2; printf '%s\n' "$out23" | sed 's/^/    /' >&2; fail=1; else echo "✓ ㉓ 反向：LS-40-* 有 LS-40 worktree → 無動作行"; fi
hasnt '㉓ 反向：LS-40-* 不進任何 ⚠ 行' "$out23" '⚠ LS-40-iPhone17Pro'
if printf '%s\n' "$out23" | grep -qE -- '--apply LS-3$'; then echo "✗ ㉓ (b) LS-3 worktree 在（In Progress）不該有動作行" >&2; printf '%s\n' "$out23" | sed 's/^/    /' >&2; fail=1; else echo "✓ ㉓ (b) LS-3 worktree 在 → 無動作行"; fi
hasnt '㉓ (b) LS-3 不進任何 ⚠ 行' "$out23" '⚠ LS-3-iPhone17Pro'
hasnt '㉓ (c) Booted 殘機 LS-998 不列刪（LS-100）' "$out23" 'cleanup-merged.sh --apply LS-998'
hasnt '㉓ (c) Booted 殘機不印 simctl delete' "$out23" 'simctl delete BOOT-998'
has   '㉓ (c) Booted 殘機印 ⓘ 說明' "$out23" 'ⓘ LS-998-iPhone17Pro（BOOT-998）票 LS-998 的 worktree 已不在（殘機），但 Booted 不列刪'
hasnt '㉓ main-* 不進第一層（沒有票）' "$out23" '--apply main'
hasnt '㉓ demo-*／qa-* 不進第一層' "$out23" 'DEMO-1'
hasnt '㉓ qa-* 不進第一層' "$out23" 'QA-1'
has   '㉓ 段末印 Xcode 預設模擬器 2 台（iPhone 17 Pro／iPad Pro；LS-/main-/demo-/qa- 不算）' "$out23" 'Xcode 預設模擬器 2 台（未列入清理；修剪需使用者裁定）'
has   '㉓ 段末印 CoreSimulator/Devices 體積（假目錄 0 GB，剛量）' "$out23" 'CoreSimulator/Devices 0 GB（du 剛量）'
has   '㉓ 不帶 --linear → 段末註明票狀態未查' "$out23" '票狀態未查（未帶 --linear），只用 worktree 判定'
[ -f "$PATROL_DU_CACHE" ] && grep -qF "$PATROL_SIM_DEVICES_DIR" "$PATROL_DU_CACHE" && echo "✓ ㉓ human 量完寫入 du 快取（含路徑）" || { echo "✗ ㉓ du 快取未寫入或缺路徑" >&2; fail=1; }
out23b="$(SIMCTL_LIST_JSON="$orphan_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '㉓ 下一輪沿用 du 快取（不重量）' "$out23b" 'CoreSimulator/Devices 0 GB（du 快取 '
# LS-198（LS-187 R1 info-3）：快取回寫走同目錄暫存檔＋mv——過期重量後檔案是「換掉」的（inode 變），不是原檔就地改寫（併發讀者可能讀到半行），
#   且不留 .tmp 殘檔、內容仍是一行。mutation：改回 `> "$du_cache"` 直接寫 → inode 不變 → 紅
ino_before=$(ls -i "$PATROL_DU_CACHE" | awk '{print $1}')
out23c="$(SIMCTL_LIST_JSON="$orphan_json" PATROL_DU_CACHE_MIN=0 bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '㉓ 快取過期（PATROL_DU_CACHE_MIN=0）→ 重量並回寫' "$out23c" 'CoreSimulator/Devices 0 GB（du 剛量）'
ino_after=$(ls -i "$PATROL_DU_CACHE" | awk '{print $1}')
if [ -n "$ino_before" ] && [ -n "$ino_after" ] && [ "$ino_before" != "$ino_after" ]; then echo "✓ ㉓ 快取回寫是換檔（暫存檔＋mv，inode ${ino_before}→${ino_after}），不是就地改寫"; else echo "✗ ㉓ 快取回寫應走暫存檔＋mv（inode ${ino_before}→${ino_after} 未變＝就地改寫，併發讀者可能讀到半行）" >&2; fail=1; fi
if ls "$PATROL_DU_CACHE".tmp.* >/dev/null 2>&1; then echo "✗ ㉓ 快取暫存檔殘留：$(ls "$PATROL_DU_CACHE".tmp.*)" >&2; fail=1; else echo "✓ ㉓ 快取回寫不留 .tmp 殘檔"; fi
[ "$(wc -l < "$PATROL_DU_CACHE" | tr -d ' ')" -eq 1 ] && grep -qF "$PATROL_SIM_DEVICES_DIR" "$PATROL_DU_CACHE" && echo "✓ ㉓ 回寫後快取仍是一行、含路徑" || { echo "✗ ㉓ 回寫後快取內容不對：$(cat "$PATROL_DU_CACHE")" >&2; fail=1; }
brief23="$(SIMCTL_LIST_JSON="$orphan_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '㉓ --brief 帶殘機 flag（掛 add_flag）' "$brief23" '[專屬模擬器 LS-999-iPhone17Pro] 票 LS-999 的 worktree 已不在（殘機） → bash scripts/ops/cleanup-merged.sh --apply LS-999'
has   '㉓ --brief 表頭台數：待清 3（殘機 3：LS-999／LS-30／LS-4）' "$brief23" '專屬模擬器待清 3（殘機 3）'
has   '㉓ --brief 帶 LS-4 殘機 flag' "$brief23" '[專屬模擬器 LS-4-iPhone17Pro] 票 LS-4 的 worktree 已不在（殘機）'
hasnt '㉓ --brief 不標 LS-40' "$brief23" '[專屬模擬器 LS-40-'
hasnt '㉓ --brief 不標 LS-3' "$brief23" '[專屬模擬器 LS-3-'
hasnt '㉓ --brief 不標 Booted 殘機 LS-998' "$brief23" '[專屬模擬器 LS-998'
hasnt '㉓ --brief 不印段末台數／體積行（只帶旗標行）' "$brief23" 'Xcode 預設模擬器'
rm -f "$PATROL_DU_CACHE"
brief23b="$(SIMCTL_LIST_JSON="$orphan_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
[ -f "$PATROL_DU_CACHE" ] && { echo "✗ ㉓ --brief 無快取時不該去量 Devices（hook 30s 預算）" >&2; fail=1; } || echo "✓ ㉓ --brief 無快取不量 Devices、不寫快取"
json23="$(SIMCTL_LIST_JSON="$orphan_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '㉓ --json：orphan_simulators 恰三筆（LS-999／LS-30／LS-4，reason no_worktree、state Shutdown）、default_simulators 2、stale_simulators 空、flags 三筆 [專屬模擬器' "$json23" \
  '([.orphan_simulators[] | .ticket] | sort) == ["LS-30", "LS-4", "LS-999"] and (.orphan_simulators | all(.reason == "no_worktree" and .state == "Shutdown")) and .default_simulators == 2 and (.stale_simulators | length == 0) and ([.flags[] | select(startswith("[專屬模擬器"))] | length == 3)'
# LS-198（LS-187 R1 info-4）：--json 帶 sim_linear_note，程式讀 JSON 分得出這輪有沒有問 Linear
jq_ok '㉓ --json：sim_linear_note＝「票狀態未查（未帶 --linear）…」（LS-198）' "$json23" '.sim_linear_note | test("票狀態未查（未帶 --linear）")'
# --linear：worktree 仍在的票（LS-3）走 patrol-linear.sh --closed；假身依 CLOSED_STUB 回「LS-3<TAB>Done」／exit 3／exit 1
fake_closed="$work/bin/fake-patrol-linear-closed.sh"
cat > "$fake_closed" <<'EOF'
#!/bin/bash
# 假身：--closed <nums> 記 argv 到 CLOSED_STUB_LOG、依 CLOSED_STUB 回應；其他模式（human／brief 段）印一行、exit 0
printf '%s\n' "$*" >> "${CLOSED_STUB_LOG:-/dev/null}"
case " $* " in
  *" --closed "*)
    case "${CLOSED_STUB:-}" in
      done) printf 'LS-3\tDone\n'; exit 0 ;;
      nokey) echo "略過（無 LINEAR_API_KEY）" >&2; exit 3 ;;
      fail) echo "炸" >&2; exit 1 ;;
      *) exit 0 ;;
    esac ;;
  *) echo "巡檢（Linear 半段）：（假身）"; exit 0 ;;
esac
EOF
chmod +x "$fake_closed"
: > "$work/closed.log"
out23l="$(SIMCTL_LIST_JSON="$orphan_json" PATROL_LINEAR_SH="$fake_closed" CLOSED_STUB=done CLOSED_STUB_LOG="$work/closed.log" bash "$patrol" --repo "$repo" --no-pr --no-fetch --linear "$STALE" 2>&1)"
has   '㉓ --linear：LS-3 worktree 在但 Linear 回 Done → ⚠（worktree 仍在）＋動作行' "$out23l" '⚠ LS-3-iPhone17Pro（LIVE-3）票 LS-3 已 Done（worktree 仍在） → bash scripts/ops/cleanup-merged.sh --apply LS-3'
has   '㉓ --linear：段末註明已查 Linear（只列 worktree 仍在的 LS-40／LS-3）' "$out23l" '票狀態已查 Linear（LS-40、LS-3）'
grep -qE -- '--closed 40,3( |$)' "$work/closed.log" && echo "✓ ㉓ --linear 只問 worktree 仍在的票（--closed 40,3；999／30／4／998 不問）" || { echo "✗ ㉓ --closed 應只帶 40,3（實得：$(cat "$work/closed.log"))" >&2; fail=1; }
n_closed=$(grep -c -- '--closed' "$work/closed.log" 2>/dev/null || true); [ "${n_closed:-0}" -eq 1 ] && echo "✓ ㉓ --closed 只呼叫一次（批次）" || { echo "✗ ㉓ --closed 應只呼叫一次（實得 ${n_closed:-0}）" >&2; fail=1; }
brief23l="$(SIMCTL_LIST_JSON="$orphan_json" PATROL_LINEAR_SH="$fake_closed" CLOSED_STUB=done bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief --linear "$STALE" 2>&1)"
has   '㉓ --linear --brief 也帶 Done 票 flag' "$brief23l" '[專屬模擬器 LS-3-iPhone17Pro] 票 LS-3 已 Done（worktree 仍在）'
json23l="$(SIMCTL_LIST_JSON="$orphan_json" PATROL_LINEAR_SH="$fake_closed" CLOSED_STUB=done bash "$patrol" --repo "$repo" --no-pr --no-fetch --json --linear "$STALE" 2>/dev/null)"
jq_ok '㉓ --json --linear：sim_linear_note＝「票狀態已查 Linear（LS-40、LS-3）」、orphan_simulators 含 LS-3 reason ticket_closed（LS-198）' "$json23l" \
  '(.sim_linear_note | test("票狀態已查 Linear（LS-40、LS-3）")) and ([.orphan_simulators[] | select(.ticket == "LS-3" and .reason == "ticket_closed")] | length == 1)'
out23n="$(SIMCTL_LIST_JSON="$orphan_json" PATROL_LINEAR_SH="$fake_closed" CLOSED_STUB=nokey bash "$patrol" --repo "$repo" --no-pr --no-fetch --linear "$STALE" 2>&1)"
hasnt '㉓ --linear 無 key（假身 exit 3）→ LS-3 不 ⚠' "$out23n" '⚠ LS-3-iPhone17Pro'
has   '㉓ --linear 無 key → 段末註明只用 worktree 判定' "$out23n" '無 LINEAR_API_KEY，票狀態未查、只用 worktree 判定'
has   '㉓ --linear 無 key → 殘機 LS-999 照樣 ⚠' "$out23n" 'cleanup-merged.sh --apply LS-999'
out23f="$(SIMCTL_LIST_JSON="$orphan_json" PATROL_LINEAR_SH="$fake_closed" CLOSED_STUB=fail bash "$patrol" --repo "$repo" --no-pr --no-fetch --linear "$STALE" 2>&1)"; rc=$?
rc_is '㉓ --linear 查詢失敗（假身 exit 1）仍 exit 0' 0 "$rc" "$out23f"
has   '㉓ --linear 查詢失敗 → 段末註明失敗、只用 worktree 判定' "$out23f" 'Linear 票狀態查詢失敗（patrol-linear.sh --closed exit 1），只用 worktree 判定'
hasnt '㉓ --linear 查詢失敗 → LS-3 不 ⚠' "$out23f" '⚠ LS-3-iPhone17Pro'

# ---- ㉓-b ticket_has_worktree 的 `[ -d ]` 分支（LS-198；LS-187 R1 info-1 指出無樣本）：worktree 記錄仍在 git worktree list（prunable、
#        未 prune）、目錄已被 rm → 視同「不在」→ 該票專屬機是殘機 ⚠。⑧ 的 LS-8 已被 worktree prune 掉，這裡另建 LS-77 並只刪目錄。
#        mutation：拿掉 `[ -d "$p" ]`（記錄在就算「在」）→ 紅 ----
wt -b feature/LS-77-gone "$wts/LS-77" origin/development
rm -rf "$wts/LS-77"
# porcelain 印 realpath（/private/var…），不能拿 $wts 字面比
if g -C "$repo" worktree list --porcelain | grep -qE "^worktree .*/LS-77$"; then echo "✓ ㉓-b 前提：LS-77 的 worktree 記錄仍在、目錄已刪"; else echo "✗ ㉓-b 前提不成立：LS-77 記錄不在 git worktree list" >&2; fail=1; fi
gone_json="{
  \"devices\" : {
    \"com.apple.CoreSimulator.SimRuntime.iOS-26-0\" : [
$(sim_dev GONE-77 Shutdown LS-77-iPhone17Pro "$now_iso"),
$(sim_dev LIVE-3b Shutdown LS-3-iPhone17Pro "$now_iso")
    ]
  }
}"
out23g="$(SIMCTL_LIST_JSON="$gone_json" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"; rc=$?
rc_is '㉓-b exit 0' 0 "$rc" "$out23g"
has   '㉓-b 記錄在、目錄已刪 → LS-77 判殘機 ⚠＋動作行' "$out23g" '⚠ LS-77-iPhone17Pro（GONE-77）票 LS-77 的 worktree 已不在（殘機） → bash scripts/ops/cleanup-merged.sh --apply LS-77'
hasnt '㉓-b 對照：LS-3（目錄在）不 ⚠' "$out23g" '⚠ LS-3-iPhone17Pro'

if [ "$fail" -eq 0 ]; then
  echo "✓ patrol／session-start 自測通過"
fi
exit "$fail"
