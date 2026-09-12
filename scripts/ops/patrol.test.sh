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
# LS-207：「本地有 commit、無 remote 分支」旗標的 20 分鐘寬限——既有 fixture 的 commit 都是「剛剛」建立
# （lm=0），不隔離的話會被寬限期擋住、既有斷言（① LS-4 未 push 即刻標 ⚠）偶發紅。統一設成 0（永不寬限，
# 沿用改動前的即刻標記行為）；㉔ 自己在呼叫時覆寫門檻驗證寬限期本身。
export PATROL_PUSH_GRACE_MIN=0
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

# ---- ⑥b LS-209（push 韌性）：SessionStart hook 冪等設定 core.sshCommand（SSH keepalive），不改使用者全域
#        ~/.gitconfig；已是目標值就不重複寫、context 不重複提醒；設定寫進的是 $repo 自己的（合成）git config，
#        不碰真的 ~/.gitconfig ----
g -C "$repo" config --unset core.sshCommand 2>/dev/null || true
hjssh1="$(printf '{}' | CLAUDE_PROJECT_DIR="$repo" PATROL_STALE="$STALE" bash "$hook" 2>/dev/null)"
jq_ok '⑥b 首次跑：context 印已設定 core.sshCommand（keepalive）' "$hjssh1" '.hookSpecificOutput.additionalContext | test("已設定 git core.sshCommand") and test("ServerAliveInterval=30") and test("ServerAliveCountMax=20")'
cur_ssh=$(g -C "$repo" config --get core.sshCommand)
if [ "$cur_ssh" = "ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=20" ]; then echo "✓ ⑥b repo 層 core.sshCommand 確實被設定成目標值"; else echo "✗ ⑥b core.sshCommand 值不符（實得「${cur_ssh}」）" >&2; fail=1; fi
if git config --global --get core.sshCommand >/dev/null 2>&1 && [ "$(git config --global --get core.sshCommand 2>/dev/null)" = "ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=20" ]; then echo "✗ ⑥b 不該動到使用者全域 ~/.gitconfig" >&2; fail=1; else echo "✓ ⑥b 未動到使用者全域 ~/.gitconfig"; fi
hjssh2="$(printf '{}' | CLAUDE_PROJECT_DIR="$repo" PATROL_STALE="$STALE" bash "$hook" 2>/dev/null)"
jq_ok '⑥b 已是目標值時第二次跑不再重複提醒（冪等）' "$hjssh2" '.hookSpecificOutput.additionalContext | test("已設定 git core.sshCommand") | not'
cur_ssh2=$(g -C "$repo" config --get core.sshCommand)
[ "$cur_ssh2" = "$cur_ssh" ] && echo "✓ ⑥b 冪等：第二次跑後值不變" || { echo "✗ ⑥b 冪等後值變了（實得「${cur_ssh2}」）" >&2; fail=1; }
g -C "$repo" config core.sshCommand 'old-custom-value'
hjssh3="$(printf '{}' | CLAUDE_PROJECT_DIR="$repo" PATROL_STALE="$STALE" bash "$hook" 2>/dev/null)"
jq_ok '⑥b 既有非目標值（如舊自訂值）→ 仍會被覆寫成目標值並提醒' "$hjssh3" '.hookSpecificOutput.additionalContext | test("已設定 git core.sshCommand")'
cur_ssh3=$(g -C "$repo" config --get core.sshCommand)
[ "$cur_ssh3" = "ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=20" ] && echo "✓ ⑥b 舊自訂值被覆寫成目標值" || { echo "✗ ⑥b 舊自訂值未被覆寫（實得「${cur_ssh3}」）" >&2; fail=1; }
hjssh_norepo="$(printf '{}' | CLAUDE_PROJECT_DIR="$work/nope" bash "$hook" 2>/dev/null)"
jq_ok '⑥b repo 不存在時不因 core.sshCommand 這段而炸——仍合法 JSON、fail-soft' "$hjssh_norepo" '.hookSpecificOutput.hookEventName == "SessionStart"'
# mutation：拿掉 LS209-SSH-KEEPALIVE 整段（標記區塊，同 patrol.sh 的 LS209-PEN-WRONG 慣例）→ 上面「首次跑印已設定」
# 的負樣本必須不再出現該訊息。ssh_note= 宣告刻意放在區塊外（同 PEN_WRONG_LINE 的教訓），拿掉整段不會讓 `set -u`
# 下游讀取 $ssh_note 炸「unbound variable」。
mut_hook="$work/session-start.no-ssh-keepalive.sh"
awk 'index($0, "LS209-SSH-KEEPALIVE-START") > 0 { skip = 1 } skip != 1 { print } index($0, "LS209-SSH-KEEPALIVE-END") > 0 { skip = 0 }' "$hook" > "$mut_hook"
if grep -q 'LS209-SSH-KEEPALIVE-START' "$mut_hook" || grep -q 'SSH_KEEPALIVE_CMD=' "$mut_hook"; then echo "✗ ⑥b mutant 仍含 core.sshCommand 設定段（awk 拿掉失敗，負控本身無效）" >&2; fail=1; else echo "✓ ⑥b mutant 確實已拿掉 core.sshCommand 設定段"; fi
g -C "$repo" config --unset core.sshCommand 2>/dev/null || true
hjssh_mut="$(printf '{}' | CLAUDE_PROJECT_DIR="$repo" PATROL_STALE="$STALE" bash "$mut_hook" 2>/dev/null)"
jq_ok '⑥b mutant：拿掉設定段後不再印已設定訊息（證明這段確實是原因）' "$hjssh_mut" '.hookSpecificOutput.additionalContext | test("已設定 git core.sshCommand") | not'
if [ -z "$(g -C "$repo" config --get core.sshCommand 2>/dev/null)" ]; then echo "✓ ⑥b mutant：拿掉設定段後 core.sshCommand 確實未被設定"; else echo "✗ ⑥b mutant 應該沒有設定 core.sshCommand" >&2; fail=1; fi
# 還原：讓後續 ⑦ 之後的測試不受本段影響（本來就不該有值，但保險起見還原成本段前的狀態）
g -C "$repo" config --unset core.sshCommand 2>/dev/null || true

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
: > "${SUPABASE_LOCK_DIR}.waiters/LS-20-$$-$(( now_e - 710 ))"   # 等了 12 分（660< 710 ≤720）；pid 用本測試程序自己的（LS-207 R2：kill -0 要驗得到活）
: > "${SUPABASE_LOCK_DIR}.waiters/LS-21-$$-$(( now_e - 170 ))"   # 等了 3 分（120< 170 ≤180）
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
: > "${SUPABASE_LOCK_DIR}.waiters/LS-22-$$-$(( $(date +%s) - 60 ))"
printf 'pid=%s\nstarted=%s\nhost=%s\nworktree=%s\nbranch=feature/LS-9-holder\ncmd=supabase db reset\n' "$$" "$(date +%s)" "$(hostname)" "$wts/LS-9" > "$SUPABASE_LOCK_DIR/holder"
hasnt '⑪-c 命令型持有（無到期時間）→ 不印 ⚠ 排隊' "$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)" '⚠ 排隊'
rm -rf "$SUPABASE_LOCK_DIR" "${SUPABASE_LOCK_DIR}.waiters"

# ---- ⑪-d LS-207 R2（merge-review R1 fd783f6c F3）：waiter 檔的 pid 已死（SIGKILL／crash 殘留，INT/TERM/HUP
#        才有 trap 清）→ 讀取時用 kill -0 驗活、不活就回收（不計入排隊數、檔案真的被刪掉，不是常駐假警報）；
#        pid 還活著的 waiter 不受影響、照常計入 ----
mkdir -p "$SUPABASE_LOCK_DIR"
exp11d=$(( $(date +%s) + 900 ))
printf 'pid=%s\nstarted=%s\nhost=%s\nworktree=%s\nbranch=test\ncmd=hold:LS-9 F3 測試\nowner=%s\nexpires_at=%s\nheartbeat=%s\n' "$$" "$(date +%s)" "$(hostname)" "$wts/LS-9" "$$" "$exp11d" "$(date +%s)" > "$SUPABASE_LOCK_DIR/holder"
mkdir -p "${SUPABASE_LOCK_DIR}.waiters"
sh -c 'exit 0' & dead_pid=$!; wait "$dead_pid" 2>/dev/null   # 讓出一個保證已死的 pid（不靠猜測 999999，避免 pid 重用巧合）
dead_wf="${SUPABASE_LOCK_DIR}.waiters/LS-30-${dead_pid}-$(( $(date +%s) - 300 ))"
: > "$dead_wf"
sleep 30 & live_pid=$!
live_wf="${SUPABASE_LOCK_DIR}.waiters/LS-31-${live_pid}-$(( $(date +%s) - 710 ))"
: > "$live_wf"
out11d="$(bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
has   '⑪-d 活 pid 的 waiter 仍計入（⚠ 排隊 1，不是 2）' "$out11d" '⚠ 排隊 1（最久 12 分）'
if [ -e "$dead_wf" ]; then echo "✗ ⑪-d 死 pid 的 waiter 檔應被回收、卻還在" >&2; fail=1; else echo "✓ ⑪-d 死 pid 的 waiter 檔已被回收（kill -0 驗活後刪除）"; fi
if [ -e "$live_wf" ]; then echo "✓ ⑪-d 活 pid 的 waiter 檔沒被誤刪"; else echo "✗ ⑪-d 活 pid 的 waiter 檔被誤刪" >&2; fail=1; fi
kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
rm -rf "$SUPABASE_LOCK_DIR" "${SUPABASE_LOCK_DIR}.waiters"
# mutation：拿掉 kill -0 回收判定 → 死 pid 的 waiter 檔應該不再被刪、⚠ 排隊 應該變成 2（兩個都被算進去）
# patrol.sh 用 $(dirname "${BASH_SOURCE[0]}") 找同目錄的 supabase-lock.sh（--status 讀 lock）——mutant 檔案
# 若獨自放在 $work 下、旁邊沒有 supabase-lock.sh，會印「（無 …/supabase-lock.sh）」整段查無此鎖，蓋掉真正要
# 驗的排隊行為。放進專屬子目錄並複製一份真正的 supabase-lock.sh 進去。
mut_dir="$work/patrol-mutant-f3"; mkdir -p "$mut_dir"
cp "${root}/scripts/ops/supabase-lock.sh" "$mut_dir/supabase-lock.sh"
mut_f3="$mut_dir/patrol.sh"
python3 - "$patrol" "$mut_f3" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '''    wpid=$(basename "$wf" | sed -E 's/^(.*)-([0-9]+)-([0-9]+)$/\\2/')
    case "$wpid" in
      ''|*[!0-9]*) ;;
      *) if ! kill -0 "$wpid" 2>/dev/null; then rm -f "$wf" 2>/dev/null; continue; fi ;;
    esac
'''
assert old in src, "找不到 F3 回收判定區塊，mutation 樣板需同步"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, ""))
PY
mkdir -p "$SUPABASE_LOCK_DIR"
printf 'pid=%s\nstarted=%s\nhost=%s\nworktree=%s\nbranch=test\ncmd=hold:LS-9 F3 mutant\nowner=%s\nexpires_at=%s\nheartbeat=%s\n' "$$" "$(date +%s)" "$(hostname)" "$wts/LS-9" "$$" "$(( $(date +%s) + 900 ))" "$(date +%s)" > "$SUPABASE_LOCK_DIR/holder"
mkdir -p "${SUPABASE_LOCK_DIR}.waiters"
sh -c 'exit 0' & dead_pid2=$!; wait "$dead_pid2" 2>/dev/null
dead_wf2="${SUPABASE_LOCK_DIR}.waiters/LS-32-${dead_pid2}-$(( $(date +%s) - 290 ))"   # 290s（非整分邊界，留 10s 緩衝，同 ⑪-c 的手法）
: > "$dead_wf2"
out_mut="$(bash "$mut_f3" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
if printf '%s' "$out_mut" | grep -qF '⚠ 排隊 1（最久 5 分）' && [ -e "$dead_wf2" ]; then
  echo "✓ ⑪-d mutant：拿掉回收判定後死 pid 的 waiter 檔不再被清、照常計入排隊數（證明 F3 修法確實是原因）"
else
  echo "✗ ⑪-d mutant 應仍計入死 pid waiter 且檔案還在（負控本身可能無效）" >&2; printf '%s\n' "$out_mut" | sed 's/^/    /' >&2; fail=1
fi
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

# ---- ㉖ LS-209（自 LS-211 I-c 起改讀 `pen-status.sh --path` 的機器可讀輸出，不再自己 sed 解析
#        PENCIL_LINE 的中文組合字串——見 patrol.sh LS209-PEN-WRONG 區塊註解）：Pen 開錯檔偵測（實作票）。
#        用 PATROL_PEN_STATUS_SH 假身模擬 `pen-status.sh --path`（回一個固定路徑，或空輸出＋exit 1）；
#        lane 查詢用 PATROL_LINEAR_SH 假身回應 `--lane <n>`。(a) 路徑落在非 design 票 worktree → ⚠＋flag；
#        (b) 路徑落在 lane:design 票 worktree → 完全靜默（不印、不 flag，這是正常設計票工作流）；(c) lane
#        查詢失敗（exit 非 0，模擬無 LINEAR_API_KEY）→ 印「lane ?」、不 flag（fail-open）；(d) 路徑不在任何票
#        worktree（如主 checkout）→ 完全靜默；(e) --path 空輸出＋exit 1（Pen 沒開／讀不到）→ 完全靜默；
#        (f) 用本檔頭的預設假身（session-wide，不特別覆寫）→ 完全靜默、不呼叫 lane 查詢（省成本）----
# mk_fake_pen_status <輸出檔路徑> <要印的路徑（空字串＝讀不到）>：路徑值寫進 <輸出檔路徑>.path 側檔，
# 假身腳本讀側檔內容——避開路徑字串（含空白／特殊字元）直接內嵌進腳本原始碼的跳脫問題。
mk_fake_pen_status() {
  printf '%s' "$2" > "$1.path"
  cat > "$1" <<EOF
#!/bin/bash
p="\$(cat '$1.path')"
if [ -z "\$p" ]; then
  if [ "\${1:-}" = --path ]; then exit 1; fi
  echo "Pencil：行程 ✗（Pen 沒開）"
  exit 1
fi
if [ "\${1:-}" = --path ]; then printf '%s\n' "\$p"; exit 0; fi
echo "Pencil：行程 ✓（pid 1） · 路徑 \$p · MCP 探針 ✓（mcp-server 1 支皆有 unix socket 連到 Pen pid 1）"
exit 0
EOF
  chmod +x "$1"
}
fake_ps_wrong="$work/fake-pen-status-wrong.sh"
mk_fake_pen_status "$fake_ps_wrong" "${repo}/.claude/worktrees/LS-777/design/littlesprout.pen"
fake_ps_design="$work/fake-pen-status-design.sh"
mk_fake_pen_status "$fake_ps_design" "${repo}/.claude/worktrees/LS-778/design/littlesprout.pen"
fake_ps_outside="$work/fake-pen-status-outside.sh"
mk_fake_pen_status "$fake_ps_outside" "${repo}/design/littlesprout.pen"
fake_ps_unreadable="$work/fake-pen-status-unreadable.sh"
mk_fake_pen_status "$fake_ps_unreadable" ""

# 假 patrol-linear.sh：--lane <n> 依 LANE_STUB／LANE_STUB_RC 回應，其他呼叫（既有測試沿用 PATROL_LINEAR_SH 時）一律 exit 0 印一行
fake_plsh_lane="$work/fake-patrol-linear-lane.sh"
cat > "$fake_plsh_lane" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${LANE_STUB_LOG:-/dev/null}"
case " $* " in
  *" --lane "*)
    rc=${LANE_STUB_RC:-0}
    if [ "$rc" != 0 ]; then echo "略過（自測假身）" >&2; exit "$rc"; fi
    printf '%s\n' "${LANE_STUB:-}"
    exit 0 ;;
  *) echo "巡檢（Linear 半段）：（假身）"; exit 0 ;;
esac
EOF
chmod +x "$fake_plsh_lane"

out26a="$(PATROL_PEN_STATUS_SH="$fake_ps_wrong" PATROL_LINEAR_SH="$fake_plsh_lane" LANE_STUB='lane:backend' bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"; rc=$?
rc_is '㉖(a) 非 design 票 worktree 仍 exit 0（異常在輸出）' 0 "$rc" "$out26a"
has   '㉖(a) human 有「Pen 開錯檔偵測」段並印 ⚠' "$out26a" '⚠ Pen 開錯檔（實作票 LS-777）'
brief26a="$(PATROL_PEN_STATUS_SH="$fake_ps_wrong" PATROL_LINEAR_SH="$fake_plsh_lane" LANE_STUB='lane:backend' bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '㉖(a) --brief 印 ⚠ 行' "$brief26a" '⚠ Pen 開錯檔（實作票 LS-777）'
has   '㉖(a) --brief 掛 [Pen] flag（lane 帶進訊息）' "$brief26a" '[Pen] 開錯檔（實作票 LS-777；lane=lane:backend，非 lane:design'

out26b="$(PATROL_PEN_STATUS_SH="$fake_ps_design" PATROL_LINEAR_SH="$fake_plsh_lane" LANE_STUB='lane:design' bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
hasnt '㉖(b) lane:design 票 worktree → 不印 ⚠（正常設計票工作流）' "$out26b" '⚠ Pen 開錯檔'
has   '㉖(b) 段落印「未開在任何票 worktree…」的靜默訊息' "$out26b" '（Pen 未開，或未開在任何票 worktree，或該票 lane 為 design）'
brief26b="$(PATROL_PEN_STATUS_SH="$fake_ps_design" PATROL_LINEAR_SH="$fake_plsh_lane" LANE_STUB='lane:design' bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
hasnt '㉖(b) --brief 不印任何 Pen 行、不掛 flag' "$brief26b" '[Pen]'

out26c="$(PATROL_PEN_STATUS_SH="$fake_ps_wrong" PATROL_LINEAR_SH="$fake_plsh_lane" LANE_STUB_RC=3 bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
hasnt '㉖(c) lane 查詢失敗（exit 3，模擬無 LINEAR_API_KEY）→ 不印 ⚠、不擋（fail-open）' "$out26c" '⚠ Pen 開錯檔'
has   '㉖(c) 印「lane ?（查詢失敗，不擋）」' "$out26c" 'Pen：目前開在 LS-777 worktree，lane ?（查詢失敗，不擋）'
brief26c="$(PATROL_PEN_STATUS_SH="$fake_ps_wrong" PATROL_LINEAR_SH="$fake_plsh_lane" LANE_STUB_RC=3 bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has   '㉖(c) --brief 印「lane ?」但不掛 [Pen] flag' "$brief26c" 'lane ?（查詢失敗，不擋）'
hasnt '㉖(c) --brief 不掛 flag' "$brief26c" '[Pen]'

out26d="$(PATROL_PEN_STATUS_SH="$fake_ps_outside" PATROL_LINEAR_SH="$fake_plsh_lane" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
hasnt '㉖(d) 路徑不在任何票 worktree（如主 checkout）→ 完全靜默' "$out26d" '⚠ Pen 開錯檔'
hasnt '㉖(d) 也不印「lane ?」（根本沒進入查詢）' "$out26d" 'lane ?'

out26e="$(PATROL_PEN_STATUS_SH="$fake_ps_unreadable" PATROL_LINEAR_SH="$fake_plsh_lane" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
hasnt '㉖(e) pen-status.sh --path 空輸出＋exit 1（Pen 沒開／讀不到）→ 完全靜默' "$out26e" '⚠ Pen 開錯檔'

: > "$work/lane-calls.log"
out26f="$(PATROL_LINEAR_SH="$fake_plsh_lane" LANE_STUB_LOG="$work/lane-calls.log" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
hasnt '㉖(default) 本檔頭預設假身（無可用路徑）→ 完全靜默' "$out26f" '⚠ Pen 開錯檔'
if [ -s "$work/lane-calls.log" ]; then echo "✗ ㉖(default) 無可用路徑時不該呼叫 patrol-linear.sh --lane（省成本）：$(cat "$work/lane-calls.log")" >&2; fail=1; else echo "✓ ㉖(default) 無可用路徑時完全不呼叫 lane 查詢（省 CLI／API 成本）"; fi

# mutation：拿掉 LS209-PEN-WRONG 整段 → 上面 ㉖(a) 的負樣本必須變綠（不印 ⚠、不掛 flag），證明紅是這段造成的
mut_penwrong="$work/patrol.no-pen-wrong.sh"
awk 'index($0, "LS209-PEN-WRONG-START") > 0 { skip = 1 } skip != 1 { print } index($0, "LS209-PEN-WRONG-END") > 0 { skip = 0 }' "$patrol" > "$mut_penwrong"
if grep -q 'LS209-PEN-WRONG-START' "$mut_penwrong" || grep -qF 'add_flag "[Pen] 開錯檔' "$mut_penwrong"; then
  echo "✗ ㉖ mutant 仍含 Pen 開錯檔偵測段（awk 拿掉失敗，負控本身無效）" >&2; fail=1
else
  echo '✓ ㉖ mutant 確實已拿掉 Pen 開錯檔偵測段'
fi
out26m="$(PATROL_PEN_STATUS_SH="$fake_ps_wrong" PATROL_LINEAR_SH="$fake_plsh_lane" LANE_STUB='lane:backend' bash "$mut_penwrong" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out26m" | grep -qF '⚠ Pen 開錯檔'; then
  echo '✓ ㉖ mutant：拿掉偵測段後，同一份「非 design 票」負樣本變綠（Pen 開錯檔偵測段確實是原因）'
else
  echo "✗ ㉖ mutant 應 exit 0 且不印「⚠ Pen 開錯檔」（實得 ${rc}）" >&2; printf '%s\n' "$out26m" | sed 's/^/    /' >&2; fail=1
fi

# 假 pgrep／lsof（LS-207 R2 F6）：不碰真的系統行程表。fake-pgrep 只回 $FAKE_PGREP_PIDS（空白分隔，忽略實際參數）；
# fake-lsof 只回 $FAKE_LSOF_CWD 當成查到的 pid 的 cwd（-Fn 格式：p<pid> 一行、n<路徑> 一行）。
cat > "$work/fake-pgrep" <<'EOS'
#!/bin/bash
for p in ${FAKE_PGREP_PIDS:-}; do echo "$p"; done
EOS
chmod +x "$work/fake-pgrep"
cat > "$work/fake-lsof" <<'EOS'
#!/bin/bash
echo "p$3"
echo "n${FAKE_LSOF_CWD:-/nonexistent}"
EOS
chmod +x "$work/fake-lsof"
export PATROL_PGREP="$work/fake-pgrep" PATROL_LSOF="$work/fake-lsof"

# ---- ㉔ LS-207 R2（merge-review R1 fd783f6c F6）：本地有 commit、無 remote 分支——30 分鐘寬限
#        （PATROL_PUSH_GRACE_MIN，> push-gate 看門狗 25 分）：超過寬限、pgrep 找不到該 worktree 的
#        push-gate.sh 行程 → 標 ⚠；「領先 remote」旗標（既有）不受影響 ----
wt -b feature/LS-901-nopush "$wts/LS-901" origin/development
echo x > "$wts/LS-901/x.txt"; g -C "$wts/LS-901" add -A
commit_ts_31m=$(date -v-31M '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '31 minutes ago' '+%Y-%m-%d %H:%M:%S')   # 本地時區字串（不加 -u）：git --date 沒有時區後綴時當本地時間解讀，加 -u 會讓字串內容是 UTC 卻被當本地時間，差一個時區（LS-207 R2 實測踩到：511m 而非 31m）
GIT_COMMITTER_DATE="$commit_ts_31m" g -C "$wts/LS-901" commit -qm 'feat: LS-901 x' --date="$commit_ts_31m"
out24="$(FAKE_PGREP_PIDS= PATROL_PUSH_GRACE_MIN=30 bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
l201=$(row "$out24" 'feature/LS-901-nopush')
has   '㉔ 最後 commit 31 分前、寬限 30 分、無行程 → 標 ⚠ 分支未 push（含寬限分鐘與 LS-207）' "$l201" '>30分未偵測到 push-gate.sh 行程，LS-207'
jq_ok '㉔ --json 同案 flag 含「未 push」' "$(FAKE_PGREP_PIDS= PATROL_PUSH_GRACE_MIN=30 bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)" '.worktrees[] | select(.branch=="feature/LS-901-nopush") | (.flag | test("未 push"))'

# ---- ㉔-b 同一分支、同一逾期 commit，但 pgrep 找到一個 push-gate.sh 行程且 cwd 落在這個 worktree 之下 →
#        即使已過寬限期也不標 ⚠、改印 info（行程真的還在跑，不是誤判）----
out24b="$(FAKE_PGREP_PIDS=54321 FAKE_LSOF_CWD="$(cd "$wts/LS-901" && pwd -P)" PATROL_PUSH_GRACE_MIN=30 bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"   # pwd -P：git worktree list 回報的是解析過 symlink 的路徑（macOS /var→/private/var），FAKE_LSOF_CWD 要對得上
l201b=$(row "$out24b" 'feature/LS-901-nopush')
hasnt '㉔-b 偵測到該 worktree 的 push-gate.sh 行程 → 不標 ⚠（即使已過寬限期）' "$l201b" '⚠ 分支未 push'
has   '㉔-b 改印 info：push-gate.sh 仍在跑' "$l201b" 'push-gate.sh 仍在跑'

# ---- ㉔-c 同一逾期 commit，pgrep 找到行程但 cwd 是別的 worktree（沒有 scope 到位）→ 仍標 ⚠（不誤放行）----
out24c="$(FAKE_PGREP_PIDS=54322 FAKE_LSOF_CWD="$(cd "$wts/LS-3" && pwd -P)" PATROL_PUSH_GRACE_MIN=30 bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
l201c=$(row "$out24c" 'feature/LS-901-nopush')
has   '㉔-c 行程 cwd 是別的 worktree → 不算數、仍標 ⚠' "$l201c" '⚠ 分支未 push'
git -C "$repo" worktree remove --force "$wts/LS-901" >/dev/null 2>&1
g -C "$repo" branch -D feature/LS-901-nopush >/dev/null 2>&1

# ---- ㉕ 最後 commit 剛剛、寬限 30 分未到 → 不標 ⚠（只是還沒到寬限期，與有沒有 push-gate.sh 行程無關）----
wt -b feature/LS-902-recent "$wts/LS-902" origin/development
echo y > "$wts/LS-902/y.txt"; g -C "$wts/LS-902" add -A; g -C "$wts/LS-902" commit -qm 'feat: LS-902 y'
out25="$(FAKE_PGREP_PIDS= PATROL_PUSH_GRACE_MIN=30 bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
l202=$(row "$out25" 'feature/LS-902-recent')
hasnt '㉕ 最後 commit 剛剛、寬限 30 分未到 → 不標 ⚠（只是還沒到寬限期）' "$l202" '⚠ 分支未 push'
has   '㉕ 寬限期內印 info：可能還在跑 push gate' "$l202" '可能還在跑 push gate'
git -C "$repo" worktree remove --force "$wts/LS-902" >/dev/null 2>&1
g -C "$repo" branch -D feature/LS-902-recent >/dev/null 2>&1

# mutation A：拿掉寬限＋pgrep 判定（改回無條件立即標 ⚠）→ ㉕ 的「未到寬限期不標」負樣本必須變紅
mut_pg="$work/patrol.no-push-grace.sh"
python3 - "$patrol" "$mut_pg" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '''  if [ -z "$r" ] && [ "$since" != "?" ] && [ "$since" -gt 0 ]; then
    if [ "${lm:-0}" -ge "$PUSH_GRACE_MIN" ] && ! push_gate_running_for "$w"; then
      flag="⚠ 分支未 push（${since} commit 只在本機，最後 commit ${lm}m 前，>${PUSH_GRACE_MIN}分未偵測到 push-gate.sh 行程，LS-207）"
    elif [ "${lm:-0}" -ge "$PUSH_GRACE_MIN" ]; then
      info="${since} commit 尚未 push（${lm:-0}m 前，push-gate.sh 仍在跑）"
    else
      info="${since} commit 尚未 push（${lm:-0}m 前，可能還在跑 push gate）"
    fi
  elif'''
new = '''  if [ -z "$r" ] && [ "$since" != "?" ] && [ "$since" -gt 0 ]; then
    flag="⚠ 分支未 push（${since} commit 只在本機）"
  elif'''
assert old in src, "找不到寬限判定區塊，mutation 樣板需同步"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
wt -b feature/LS-903-recent2 "$wts/LS-903" origin/development
echo z > "$wts/LS-903/z.txt"; g -C "$wts/LS-903" add -A; g -C "$wts/LS-903" commit -qm 'feat: LS-903 z'
out26="$(FAKE_PGREP_PIDS= PATROL_PUSH_GRACE_MIN=30 bash "$mut_pg" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
l203=$(row "$out26" 'feature/LS-903-recent2')
if printf '%s' "$l203" | grep -qF '⚠ 分支未 push'; then
  echo '✓ ㉕ mutant：拿掉寬限判定後「剛 commit 就標 ⚠」的負樣本變紅（證明寬限期是這條規則造成的）'
else
  echo "✗ ㉕ mutant 應標 ⚠（未套寬限期），實際仍未標——mutation 本身可能沒生效" >&2; printf '%s\n' "$l203" | sed 's/^/    /' >&2; fail=1
fi
git -C "$repo" worktree remove --force "$wts/LS-903" >/dev/null 2>&1
g -C "$repo" branch -D feature/LS-903-recent2 >/dev/null 2>&1

# mutation B：只拿掉 `&& ! push_gate_running_for "$w"` 這半（寬限判定還在，但不再排除真的在跑的行程）→
# ㉔-b「偵測到行程不標」的負樣本必須變紅，證明 pgrep／lsof 探測真的是這行為的原因
mut_pg2="$work/patrol.no-pgrep-check.sh"
python3 - "$patrol" "$mut_pg2" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'if [ "${lm:-0}" -ge "$PUSH_GRACE_MIN" ] && ! push_gate_running_for "$w"; then'
new = 'if [ "${lm:-0}" -ge "$PUSH_GRACE_MIN" ]; then'
assert src.count(old) == 1, "找不到 pgrep 判定條件，mutation 樣板需同步"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
wt -b feature/LS-904-running "$wts/LS-904" origin/development
echo w > "$wts/LS-904/w.txt"; g -C "$wts/LS-904" add -A
commit_ts_31m_b=$(date -v-31M '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '31 minutes ago' '+%Y-%m-%d %H:%M:%S')
GIT_COMMITTER_DATE="$commit_ts_31m_b" g -C "$wts/LS-904" commit -qm 'feat: LS-904 w' --date="$commit_ts_31m_b"
out27="$(FAKE_PGREP_PIDS=54323 FAKE_LSOF_CWD="$(cd "$wts/LS-904" && pwd -P)" PATROL_PUSH_GRACE_MIN=30 bash "$mut_pg2" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
l204=$(row "$out27" 'feature/LS-904-running')
if printf '%s' "$l204" | grep -qF '⚠ 分支未 push'; then
  echo '✓ ㉔-b mutant：拿掉 pgrep 排除判定後，即使行程真的在跑也會被標 ⚠（證明 push_gate_running_for 真的是原因）'
else
  echo "✗ ㉔-b mutant 應該標 ⚠（拿掉排除判定），實際沒標——mutation 本身可能無效" >&2; printf '%s\n' "$l204" | sed 's/^/    /' >&2; fail=1
fi
git -C "$repo" worktree remove --force "$wts/LS-904" >/dev/null 2>&1
g -C "$repo" branch -D feature/LS-904-running >/dev/null 2>&1
unset PATROL_PGREP PATROL_LSOF

# ---- ㉗ 螢幕鎖定偵測（LS-220：鎖定會讓模擬器 Keychain 回 -34018，長得像 QA e2e 逾時失敗，見 §4-b 排障順序）----
# 真的 ioreg 讀主機當下狀態不可控（CI／開發機當下是否鎖定與本測試無關），一律用 PATH stub 蓋掉，同 ⑭ 對 xcrun 的作法。
# LS-220 merge-review R2 M1：stub 形狀改成本機實測的真機巢狀 compact 格式（`ioreg -n Root -d1 |
# grep -o 'IOConsoleUsers[^)]*'` 實跑原文，使用者名稱／UUID 已改成無意義佔位字串）——
# `"IOConsoleUsers" = ({"kCGSSessionOnConsoleKey"=Yes,"kSCSecuritySessionID"=100023,
# "kCGSSessionSystemSafeBoot"=No,"kCGSessionLoginDoneKey"=Yes,"kCGSSessionIDKey"=257,
# "kCGSSessionUserNameKey"="testuser","kCGSSessionGroupIDKey"=20,
# "CGSSessionUniqueSessionUUID"="00000000-0000-0000-0000-000000000000",
# "kCGSessionLongUserNameKey"="Test User","kCGSSessionAuditIDKey"=100023,
# "kCGSSessionLoginwindowSafeLogin"=No,"kCGSSessionUserIDKey"=501})`——鎖定時同一個 dict 多一個
# 逗號分隔項 `"CGSSessionScreenIsLocked"=Yes`（`=` 兩側無空白，鍵名照樣加引號），R1 的 stub 誤用
# Root 頂層、`=` 兩側各一空白的形狀，對真機輸出永遠比對不到（見下方 mutation 負控）。
cat > "$work/bin/ioreg" <<'STUB'
#!/bin/bash
console_users='{"kCGSSessionOnConsoleKey"=Yes,"kSCSecuritySessionID"=100023,"kCGSSessionSystemSafeBoot"=No,"kCGSessionLoginDoneKey"=Yes,"kCGSSessionIDKey"=257,"kCGSSessionUserNameKey"="testuser","kCGSSessionGroupIDKey"=20,"CGSSessionUniqueSessionUUID"="00000000-0000-0000-0000-000000000000","kCGSessionLongUserNameKey"="Test User","kCGSSessionAuditIDKey"=100023,"kCGSSessionLoginwindowSafeLogin"=No,"kCGSSessionUserIDKey"=501'
if [ "${FAKE_IOREG_LOCKED:-0}" = 1 ]; then
  console_users="${console_users},\"CGSSessionScreenIsLocked\"=Yes"
fi
printf '+-o Root  <class IORegistryEntry, id 0x100000100, retain 35>\n    {\n      "IOConsoleUsers" = (%s})\n    }\n' "$console_users"
STUB
chmod +x "$work/bin/ioreg"

out27u="$(FAKE_IOREG_LOCKED=0 PATH="$work/bin:$PATH" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
lock_section_u=$(printf '%s\n' "$out27u" | awk '/== 螢幕鎖定/{found=1; next} found{print; exit}')
[ "$lock_section_u" = "  ok" ] && echo '✓ ㉗ 未鎖定 → 螢幕鎖定段印 ok' || { echo "✗ ㉗ 未鎖定應印「  ok」，實得「${lock_section_u}」" >&2; fail=1; }
hasnt '㉗ 未鎖定 → 不進 [screen-lock] 旗標' "$out27u" '[screen-lock]'

out27l="$(FAKE_IOREG_LOCKED=1 PATH="$work/bin:$PATH" bash "$patrol" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
lock_section_l=$(printf '%s\n' "$out27l" | awk '/== 螢幕鎖定/{found=1; next} found{print; exit}')
has '㉗ 鎖定中 → 螢幕鎖定段標 ⚠ 並提示 §4-b 排障順序' "$lock_section_l" '⚠ 主機螢幕鎖定中'
has '㉗ 鎖定中 → -34018 說明字樣' "$lock_section_l" '-34018'

brief27="$(FAKE_IOREG_LOCKED=1 PATH="$work/bin:$PATH" bash "$patrol" --repo "$repo" --no-pr --no-fetch --brief "$STALE" 2>&1)"
has '㉗ --brief 也印 [screen-lock]' "$brief27" '[screen-lock] ⚠ 主機螢幕鎖定中'

json27="$(FAKE_IOREG_LOCKED=1 PATH="$work/bin:$PATH" bash "$patrol" --repo "$repo" --no-pr --no-fetch --json "$STALE" 2>/dev/null)"
jq_ok '㉗ --json：flags 含一筆 [screen-lock]' "$json27" '([.flags[] | select(startswith("[screen-lock]"))] | length == 1)'

# mutation：拿掉 ioreg 偵測（改成永遠空字串）→ 鎖定中的正樣本必須不再標，證明這條規則是偵測的原因
mut_lock="$work/patrol.no-screen-lock-check.sh"
python3 - "$patrol" "$mut_lock" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ("if ioreg -n Root -d1 2>/dev/null | "
       "grep -Eq 'CGSSessionScreenIsLocked\"[[:space:]]*=[[:space:]]*Yes'; then")
new = 'if false; then'
assert src.count(old) == 1, "找不到螢幕鎖定偵測條件，mutation 樣板需同步"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
out27m="$(FAKE_IOREG_LOCKED=1 PATH="$work/bin:$PATH" bash "$mut_lock" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
lock_section_m=$(printf '%s\n' "$out27m" | awk '/== 螢幕鎖定/{found=1; next} found{print; exit}')
if [ "$lock_section_m" = "  ok" ]; then
  echo '✓ ㉗ mutant：拿掉偵測後鎖定中的正樣本變成 ok（證明 ⚠ 是這條規則造成的）'
else
  echo "✗ ㉗ mutant 應變成 ok（偵測已拿掉），實得「${lock_section_m}」——mutation 本身可能無效" >&2; fail=1
fi

# mutation 負控（LS-220 merge-review R2 M1）：把比對字串改回 R1 的舊形狀（Root 頂層、`=` 兩側各一
# 空白、非 -E 精確字串比對）→ 對本測試檔真機 compact 格式（`=` 兩側無空白）的鎖定樣本必須比對不到、
# 變成 ok——證明 R1 那版對真機輸出「永遠不會觸發」的裁定成立，R2 改用 -Eq 容忍空白可有可無才是真的
# 修到。
mut_lock_old="$work/patrol.old-screen-lock-pattern.sh"
python3 - "$patrol" "$mut_lock_old" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = ("if ioreg -n Root -d1 2>/dev/null | "
       "grep -Eq 'CGSSessionScreenIsLocked\"[[:space:]]*=[[:space:]]*Yes'; then")
new = 'if ioreg -n Root -d1 2>/dev/null | grep -q \'CGSSessionScreenIsLocked" = Yes\'; then'
assert src.count(old) == 1, "找不到螢幕鎖定偵測條件，mutation 樣板需同步"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
out27ml="$(FAKE_IOREG_LOCKED=1 PATH="$work/bin:$PATH" bash "$mut_lock_old" --repo "$repo" --no-pr --no-fetch "$STALE" 2>&1)"
lock_section_ml=$(printf '%s\n' "$out27ml" | awk '/== 螢幕鎖定/{found=1; next} found{print; exit}')
if [ "$lock_section_ml" = "  ok" ]; then
  echo '✓ ㉗ mutant（R1 舊形狀）：對真機 compact 格式比對不到、變成 ok（證明 R1 的寫法對真機輸出確實抓不到，R2 -Eq 容忍空白才是真的修到）'
else
  echo "✗ ㉗ mutant（R1 舊形狀）應變成 ok（比對不到鎖定），實得「${lock_section_ml}」——負控本身可能無效" >&2; fail=1
fi

# ---- ㉘（LS-233；merge-review R1 m1／m2 已修）：PR 段 BLOCKED 三分流——讀 check bucket 分「CI 跑中」／
#        「check 全綠仍卡＝缺必要 status」／「check 紅」，取代舊版籠統「無動作（CI 沒回報？）」（09-12
#        #365／#366 兩起事故的重放）。m1：fail 優先於 pending，兩者並存時不再把 fail 整個吞掉（並列印
#        「另 N 項跑中」）。m2：pending 的「已跑幾分」改用 gh pr checks 的 startedAt（取 pending 項裡最早
#        開始、即 elapsed 最大的那個），不再用 PR updatedAt 年齡——09-12 #365 正是「PR 沒被互動更新、但
#        CI 剛開跑」的反例。
# 假 gh：讀 fixtures 目錄回應，不打真的 GitHub API／不需要真的 origin 是 GitHub repo。
#   gh pr list ...                                                → 固定回 pr-list.tsv（已是 -q 處理過的最終 TSV）
#   gh pr checks <n> --json ... -q ...                            → pr-checks-<n>.tsv（無此檔＝exit 1，模擬查詢失敗；
#                                                                    第 4 欄＝pending 項已預先算好的「距今幾分」
#                                                                    （即真實 jq 運算式 `now - (startedAt|fromdateiso8601)`
#                                                                    的結果，假 gh 直接 cat 檔案、不跑 jq，固定值才不會
#                                                                    隨測試執行時間漂移），非 pending 或無 startedAt 留空）
#                                                                  → 若改放 pr-checks-<n>.json（原始陣列，非 TSV），假
#                                                                    gh 改為忠實模擬 gh 自己套用 -q 的行為：把 patrol.sh
#                                                                    實際傳入的 -q 引數（即 pr_check_flag() 裡那條 jq
#                                                                    運算式本尊）原封不動丟給真的 jq 執行（i4，merge-review
#                                                                    R2 delta：假 gh 直接 cat 已算好的 TSV 完全繞過真 jq，
#                                                                    運算式本身寫錯語法／語意也測不出來——m4 的 Go 零值
#                                                                    `strptime` 崩潰就是這樣漏掉的）。兩種形態並存、
#                                                                    .json 優先；既有 .tsv fixture 不必改。
#   gh api repos/:owner/:repo/branches/<b>/protection/required_status_checks -q '.contexts[]'
#                                                                  → protection-<b>.txt
#   gh api repos/:owner/:repo/commits/<oid>/status -q '...'       → status-<oid>.txt（缺檔＝空字串，不當失敗）
mkdir -p "$work/gh-fixtures"
cat > "$work/bin/gh" <<STUB
#!/bin/bash
dir="$work/gh-fixtures"
if [ "\$1" = pr ] && [ "\$2" = list ]; then
  cat "\$dir/pr-list.tsv" 2>/dev/null
  exit 0
fi
if [ "\$1" = pr ] && [ "\$2" = checks ]; then
  n="\$3"
  if [ -f "\$dir/pr-checks-\${n}.json" ]; then
    filter=""
    while [ \$# -gt 0 ]; do
      if [ "\$1" = "-q" ]; then filter="\$2"; break; fi
      shift
    done
    jq -r "\$filter" "\$dir/pr-checks-\${n}.json"
    exit \$?
  fi
  if [ -f "\$dir/pr-checks-\${n}.tsv" ]; then cat "\$dir/pr-checks-\${n}.tsv"; exit 0; else exit 1; fi
fi
if [ "\$1" = api ]; then
  path="\$2"
  case "\$path" in
    */protection/required_status_checks)
      b=\$(printf '%s' "\$path" | sed -E 's#.*/branches/([^/]+)/protection.*#\1#')
      if [ -f "\$dir/protection-\${b}.txt" ]; then cat "\$dir/protection-\${b}.txt"; exit 0; else exit 1; fi
      ;;
    */commits/*/status)
      oid=\$(printf '%s' "\$path" | sed -E 's#.*/commits/([^/]+)/status#\1#')
      cat "\$dir/status-\${oid}.txt" 2>/dev/null
      exit 0
      ;;
  esac
fi
exit 1
STUB
chmod +x "$work/bin/gh"

oid900="a5773c0$(printf '0%.0s' $(seq 1 33))"   # 09-12 #365 head 前綴
oid901="ca5021e$(printf '0%.0s' $(seq 1 33))"   # 09-12 #366 head 前綴
oid902="deadbee$(printf '0%.0s' $(seq 1 33))"
oid903="1234567$(printf '0%.0s' $(seq 1 33))"
oid904="f00f00f$(printf '0%.0s' $(seq 1 33))"   # m1：fail＋pending 並存
oid905="ab00000$(printf '0%.0s' $(seq 1 33))"   # m2 負控：pending 全無 startedAt → 印 ?m
oid906="600d600d$(printf '0%.0s' $(seq 1 32))"  # i4：真 jq 通道，正常 startedAt
oid907="0001000$(printf '0%.0s' $(seq 1 33))"   # i4／m4：真 jq 通道，Go 零值 startedAt
cat > "$work/gh-fixtures/pr-list.tsv" <<TSV
900	BLOCKED	-	48	feature/LS-900-pending	development	false	${oid900}	LS-900 demo pending（重放 #365：18:59 checks 有 pending）
901	BLOCKED	-	48	feature/LS-901-missing	development	false	${oid901}	LS-901 demo missing-status（重放 #366：21:10 五項全 pass、無 pending、仍 BLOCKED）
902	BLOCKED	-	48	feature/LS-902-fail	development	false	${oid902}	LS-902 demo check-red
903	BLOCKED	-	5	feature/LS-903-fresh	development	false	${oid903}	LS-903 demo not-stale-yet
904	BLOCKED	-	48	feature/LS-904-fail-and-pending	development	false	${oid904}	LS-904 demo fail 與 pending 並存（m1）
905	BLOCKED	-	48	feature/LS-905-pending-no-started	development	false	${oid905}	LS-905 demo pending 缺 startedAt（m2 負控）
906	BLOCKED	-	48	feature/LS-906-realjq-normal	development	false	${oid906}	LS-906 demo 真 jq 通道、正常時間（i4）
907	BLOCKED	-	48	feature/LS-907-realjq-zerodate	development	false	${oid907}	LS-907 demo 真 jq 通道、Go 零值 startedAt（m4／i4）
TSV
cat > "$work/gh-fixtures/protection-development.txt" <<TXT
ci
lint
rules
db
merge-review
TXT
# 900（#365 重放）：db／ci 兩項 pending，各自帶已算好的「距今幾分」——db 22、ci 9，db 較早開始（elapsed
# 較大）故取代表值 22；PR 本身 updatedAt 年齡是 48（見 pr-list.tsv），刻意與 22 不同，證明訊息裡的分鐘數
# 來自 check 的 startedAt、不是 PR 年齡（m2 修的正是這個）。
cat > "$work/gh-fixtures/pr-checks-900.tsv" <<TSV
ci-ipad	pass	https://github.com/CLYEH/little-sprout/actions/runs/1001/job/1
lint	pass	https://github.com/CLYEH/little-sprout/actions/runs/1001/job/2
rules	pass	https://github.com/CLYEH/little-sprout/actions/runs/1001/job/3
db	pending	https://github.com/CLYEH/little-sprout/actions/runs/1001/job/4	22
ci	pending	https://github.com/CLYEH/little-sprout/actions/runs/1001/job/5	9
TSV
cat > "$work/gh-fixtures/pr-checks-901.tsv" <<TSV
ci-ipad	pass	https://github.com/CLYEH/little-sprout/actions/runs/1002/job/1
ci	pass	https://github.com/CLYEH/little-sprout/actions/runs/1002/job/2
lint	pass	https://github.com/CLYEH/little-sprout/actions/runs/1002/job/3
rules	pass	https://github.com/CLYEH/little-sprout/actions/runs/1002/job/4
db	pass	https://github.com/CLYEH/little-sprout/actions/runs/1002/job/5
TSV
: > "$work/gh-fixtures/status-${oid901}.txt"   # 21:10 當時 statuses=[]（merge-review 尚未回報）
cat > "$work/gh-fixtures/pr-checks-902.tsv" <<TSV
ci-ipad	pass	https://github.com/CLYEH/little-sprout/actions/runs/1003/job/1
lint	pass	https://github.com/CLYEH/little-sprout/actions/runs/1003/job/2
ci	fail	https://github.com/CLYEH/little-sprout/actions/runs/999888/job/3
TSV
# 903：age 5 < stale 10，不查（沒建 pr-checks-903.tsv；若被誤查，假 gh 會 exit 1，pr_check_flag 會印
# 「查詢失敗」，即可揭穿 age 門檻退化成無條件查詢）

# 904（m1：09-12 #355 那種「必要 job 已紅、另一個還在跑」的形狀）：ci fail＋lint pending 並存。
cat > "$work/gh-fixtures/pr-checks-904.tsv" <<TSV
ci-ipad	pass	https://github.com/CLYEH/little-sprout/actions/runs/2001/job/1
lint	pending	https://github.com/CLYEH/little-sprout/actions/runs/2001/job/2	15
ci	fail	https://github.com/CLYEH/little-sprout/actions/runs/777111/job/3
TSV

# 905（m2 負控）：唯一的 pending 項沒有 startedAt（第 4 欄空）→ 代表值印 ?，不是 0 或空字串。
cat > "$work/gh-fixtures/pr-checks-905.tsv" <<TSV
lint	pass	https://github.com/CLYEH/little-sprout/actions/runs/3001/job/1
ci	pending	https://github.com/CLYEH/little-sprout/actions/runs/3001/job/2
TSV

# 906／907（i4，merge-review R2 delta：假 gh 直接 cat 已算好的 TSV 完全繞過真 jq，`now - (startedAt|
# fromdateiso8601)` 這條本輪唯一新增的查詢邏輯從未真的被執行過——語法／語意寫錯，自測仍全綠）：改用
# .json 原始陣列＋假 gh 對 -q 引數跑真的 jq（見上面假 gh 腳本），忠實驗證 patrol.sh 裡那條 jq 運算式本尊。
# 906：兩項 pending 帶真實 ISO 時間（ci 17 分前、ci-ipad 5 分前，取代表值＝較早開始者 17）＋一項 pass
# 帶 Go 零值 startedAt（重放 09-12 真實觀察：`gh pr checks 355／349` 的 merge-review 項就是這個值）——
# 驗證 pass bucket 的零值不會被求值（jq if/then/else 短路，只有 bucket=="pending" 才會走到
# fromdateiso8601 那支），不誤觸 m4 的崩潰。
ci17_epoch=$(( $(date +%s) - 17 * 60 )); ci17_iso=$(date -u -r "$ci17_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@${ci17_epoch}" +%Y-%m-%dT%H:%M:%SZ)
ipad5_epoch=$(( $(date +%s) - 5 * 60 )); ipad5_iso=$(date -u -r "$ipad5_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@${ipad5_epoch}" +%Y-%m-%dT%H:%M:%SZ)
cat > "$work/gh-fixtures/pr-checks-906.json" <<JSON
[
  {"name":"merge-review","bucket":"pass","link":"https://linear.app/x","startedAt":"0001-01-01T00:00:00Z"},
  {"name":"ci","bucket":"pending","link":"https://github.com/CLYEH/little-sprout/actions/runs/4001/job/1","startedAt":"${ci17_iso}"},
  {"name":"ci-ipad","bucket":"pending","link":"https://github.com/CLYEH/little-sprout/actions/runs/4001/job/2","startedAt":"${ipad5_iso}"}
]
JSON
# 907：兩種「解析不了」都要印 `?m`，不是查詢失敗。
#   - merge-review：bucket=pending 且 startedAt 為 Go 零值（m4 觸發條件本尊，merge-review R2 delta 端
#     到端重現用的正是這個組合，而非 355／349 實測到的 pass bucket 零值，因為只有 pending 才會真的
#     求值 fromdateiso8601）——這個值靠字串前綴守門擋下，跟平台無關（比對發生在呼叫 fromdateiso8601
#     之前）。
#   - ci：bucket=pending 且 startedAt 是完全不合格式的垃圾值「not-a-date」（merge-review R3 delta
#     i5／m4：本機兩個 jq 版本（1.6、系統版 jq-1.7.1-apple）對 Go 零值都會拋錯，但 CI 的 Ubuntu jq
#     不會——`fromdateiso8601` 拋不拋錯是 C 函式庫的 gmtime 範圍驗證行為、macOS 與 glibc 不一致，
#     字串前綴守門本身不受這個平台差異影響，但只覆蓋這一個已知值；`not-a-date` 是 strptime **格式
#     比對失敗**（不是範圍驗證），這一類失敗在所有平台的 jq 上都一致會拋錯——本機已用 jq 1.6 與
#     jq-1.7.1-apple 各自驗證兩者皆拋錯，是可攜的 mutation 觸發點，`0001-01-01` 則不是）由 try/catch
#     接住。
cat > "$work/gh-fixtures/pr-checks-907.json" <<JSON
[
  {"name":"merge-review","bucket":"pending","link":"https://linear.app/y","startedAt":"0001-01-01T00:00:00Z"},
  {"name":"ci","bucket":"pending","link":"https://linear.app/z","startedAt":"not-a-date"}
]
JSON

t0=$(date +%s)
out28="$(PATH="$work/bin:$PATH" bash "$patrol" --repo "$repo" --no-fetch 10 2>&1)"; rc=$?
t28=$(( $(date +%s) - t0 ))
rc_is '㉘ exit 0' 0 "$rc" "$out28"
l900=$(row "$out28" 'feature/LS-900-pending')
has   '㉘ #365 重放：pending → CI 跑中' "$l900" '⏳ CI 跑中'
has   '㉘ #365 重放：pending 名單含 db、ci' "$l900" 'db、ci'
has   '㉘ m2：分鐘數取自 check startedAt（db 22＝pending 裡最早開始者）' "$l900" 'CI 跑中 22m'
# 註：整行本來就含裸的「48m」——那是表格固定欄位印的 PR 原始 age（與 flag 無關，任何 PR 都會印），
# 這裡要驗的是「flag 訊息本身」沒有把 48 當成 CI 時間講，故比對更明確的字串「CI 跑中 48m」而非裸 48m。
hasnt '㉘ m2：不再是 PR updatedAt 年齡（48，與 22 刻意不同）' "$l900" 'CI 跑中 48m'
hasnt '㉘ m2：pending 訊息不再帶 head sha（已改用 CI 時間，不需要沿用舊格式的 head 提示）' "$l900" "head ${oid900:0:7}"
hasnt '㉘ #365 重放：不再印舊「無動作」字樣' "$l900" '無動作'
l901=$(row "$out28" 'feature/LS-901-missing')
has   '㉘ #366 重放：全綠仍 BLOCKED＝缺必要 status' "$l901" '⚠ check 全綠仍 BLOCKED＝缺必要 status'
has   '㉘ #366 重放：缺 merge-review' "$l901" '缺：merge-review'
has   '㉘ #366 重放：現有 status contexts 印（無）（statuses=[] 當時）' "$l901" '現有 status contexts：（無）'
has   '㉘ #366 重放：head sha7' "$l901" "${oid901:0:7}"
has   '㉘ #366 重放：貼 promote: no content diff 提示' "$l901" 'promote: no content diff'
has   '㉘ #366 重放：否則派 review 提示' "$l901" '否則派 review'
hasnt '㉘ #366 重放：不再印舊「無動作」字樣' "$l901" '無動作'
l902=$(row "$out28" 'feature/LS-902-fail')
has   '㉘ check 紅：列出失敗名稱' "$l902" '✗ check 紅：ci'
has   '㉘ check 紅：rerun 指令' "$l902" 'gh run rerun'
has   '㉘ check 紅：--failed（flaky）或修' "$l902" '--failed（flaky）或修'
has   '㉘ check 紅：附 run id' "$l902" '999888'
hasnt '㉘ check 紅（純 fail，無 pending）：不印「另 N 項跑中」' "$l902" '另'
l903=$(row "$out28" 'feature/LS-903-fresh')
has   '㉘ age 未達 stale → 不查、維持 ok' "$l903" ' ok'
hasnt '㉘ age 未達 stale → 未觸發查詢失敗（門檻仍生效，未退化成無條件查）' "$l903" '查詢失敗'
l904=$(row "$out28" 'feature/LS-904-fail-and-pending')
has   '㉘ m1：fail＋pending 並存 → fail 優先，不被 pending 吞掉' "$l904" '✗ check 紅：ci'
has   '㉘ m1：fail 附 run id（777111，證明真的走 fail 分支）' "$l904" '777111'
has   '㉘ m1：併印「另 1 項跑中（lint）」，pending 資訊沒有整個消失' "$l904" '另 1 項跑中（lint）'
hasnt '㉘ m1：不誤判成純 CI 跑中（fail 沒被吞）' "$l904" '⏳ CI 跑中'
l905=$(row "$out28" 'feature/LS-905-pending-no-started')
has   '㉘ m2 負控：pending 缺 startedAt → 印 ?m（不是 0 或空字串）' "$l905" 'CI 跑中 ?m（ci）'
l906=$(row "$out28" 'feature/LS-906-realjq-normal')
has   '㉘ i4：真 jq 通道，正常時間 → 取最早開始者（ci 17 分前 ＞ ci-ipad 5 分前）' "$l906" 'CI 跑中 17m（ci、ci-ipad）'
hasnt '㉘ i4：pass bucket 的 Go 零值 startedAt 不觸發查詢失敗（if/then/else 短路，只有 pending 才求值）' "$l906" '查詢失敗'
l907=$(row "$out28" 'feature/LS-907-realjq-zerodate')
has   '㉘ m4（真 jq 通道）：pending 項 startedAt 是 Go 零值 → 視同缺值印 ?m，不再讓整條查詢中止' "$l907" 'CI 跑中 ?m（merge-review、ci）'
hasnt '㉘ m4：不再印查詢失敗' "$l907" '查詢失敗'
has   '㉘ i5：pending 項 startedAt 是完全不合格式的垃圾值（not-a-date）→ try/catch 接住、同樣印 ?m' "$l907" 'ci'
brief28="$(PATH="$work/bin:$PATH" bash "$patrol" --repo "$repo" --no-fetch --brief 10 2>&1)"
has   '㉘ --brief 同步分流：CI 跑中' "$brief28" '⏳ CI 跑中'
has   '㉘ --brief 同步分流：缺必要 status' "$brief28" '缺必要 status'
has   '㉘ --brief 同步分流：check 紅' "$brief28" '✗ check 紅：ci'
has   '㉘ --brief 同步分流：m1 的「另 N 項跑中」也帶出去' "$brief28" '另 1 項跑中（lint）'
echo "ⓘ ㉘ 巡檢耗時（含 5 筆 BLOCKED-且-stale 各 1～3 次 gh 呼叫，1 筆未達 stale 不查）：${t28}s"

# mutation：拿掉三分流、退回舊版單純看 age 印「無動作（CI 沒回報？）」→ #366 重放樣本必須變回舊字樣，
# 證明上面的分流訊息確實是這段程式碼造成的（同 ㉕／㉗ 慣例：python3 精確替換、count==1 才算找對）。
mut_pr="$work/patrol.no-blocked-triage.sh"
python3 - "$patrol" "$mut_pr" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '*) if [ "$age" -ge "$STALE" ]; then flag=$(pr_check_flag "$n" "$oid" "$base" "$st"); fi ;;'
new = '*) if [ "$age" -ge "$STALE" ]; then flag="⏳ ${st} ${age}m 無動作（CI 沒回報？）"; fi ;;'
assert src.count(old) == 1, "找不到 BLOCKED 三分流呼叫，mutation 樣板需同步"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
out28m="$(PATH="$work/bin:$PATH" bash "$mut_pr" --repo "$repo" --no-fetch 10 2>&1)"
l901m=$(row "$out28m" 'feature/LS-901-missing')
has   '㉘ mutant：拿掉三分流後退回舊字樣「無動作（CI 沒回報？）」（證明分流訊息是這段程式碼造成的）' "$l901m" '無動作（CI 沒回報？）'
hasnt '㉘ mutant：不再印新版缺必要 status 訊息' "$l901m" '缺必要 status'

# mutation（m1，merge-review R1）：把 pending／fail 兩個完整區塊（條件＋printf 內文）整段對調順序，
# 復原 R1「pending 先判、fail 被整個吞掉」的舊行為——904（fail＋pending 並存）的 pend 非空會先命中、
# 直接 return 印出舊版純「CI 跑中」訊息，永遠輪不到 fail 那段。用 Python raw 字串精準比對兩個完整區塊
# （含 emoji／中文 printf 內文與行尾 `\` 續行），count==1 才算找對，證明「fail 優先」是這段程式碼造成的。
mut_pr_m1="$work/patrol.pending-before-fail.sh"
python3 - "$patrol" "$mut_pr_m1" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = r'''  if [ -n "$fail_names" ]; then
    printf '✗ check 紅：%s → gh run rerun <run-id> --failed（flaky）或修（run id：%s）%s' \
      "$fail_names" "${fail_ids:-未取得，見 PR #${n} 頁面}" "${pend:+；另 ${pend_count} 項跑中（${pend}）}"
    return
  fi
  if [ -n "$pend" ]; then
    printf '⏳ CI 跑中 %sm（%s）' "${pend_max_m:-?}" "$pend"
    return
  fi'''
new = r'''  if [ -n "$pend" ]; then
    printf '⏳ CI 跑中 %sm（%s）' "${pend_max_m:-?}" "$pend"
    return
  fi
  if [ -n "$fail_names" ]; then
    printf '✗ check 紅：%s → gh run rerun <run-id> --failed（flaky）或修（run id：%s）%s' \
      "$fail_names" "${fail_ids:-未取得，見 PR #${n} 頁面}" "${pend:+；另 ${pend_count} 項跑中（${pend}）}"
    return
  fi'''
assert src.count(old) == 1, "找不到 fail/pending 判定區塊，mutation 樣板需同步"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
out28m1="$(PATH="$work/bin:$PATH" bash "$mut_pr_m1" --repo "$repo" --no-fetch 10 2>&1)"
l904m=$(row "$out28m1" 'feature/LS-904-fail-and-pending')
has   '㉘ mutant（m1）：pending 判斷搬到 fail 之前 → 904 的 fail 被吞、變回純「CI 跑中」（證明 fail 優先是這段程式碼造成的）' "$l904m" '⏳ CI 跑中'
hasnt '㉘ mutant（m1）：check 紅／run id 資訊消失' "$l904m" 'check 紅'

# mutation（m4 舊版守門，仍保留：拿掉 Go 零值前綴守門，只留 try/catch）：merge-review R3 delta 發現
# `0001-01-01` 這個特定值是否讓 fromdateiso8601 拋錯是平台相依的——本機 macOS 兩個 jq 版本都會拋、
# CI 的 Ubuntu（glibc）jq **不會拋錯**，而是把它算成一個巨大的垃圾分鐘數（merge-review R4 delta B1
# 實測：CI run 34702037809 印出 `⏳ CI 跑中 1065413727m（merge-review、ci）`，R3 那次 run 34700632619
# 同位置是 `1065413699m`）——這正是保留前綴守門的理由：glibc 平台上 try/catch 完全不會被觸發（沒有
# 拋出例外可 catch），前綴守門才是唯一能擋下垃圾數字的機制。R4 delta B1（blocker，已修）：這裡原本
# 斷言「印出 `CI 跑中 ?m`」在 macOS 成立、在 glibc 不成立（垃圾數字不是 `?`）——`has` 是硬斷言，
# 「不強求」的註解軟化不了，CI 因此紅。改成只留兩個平台都成立的斷言：`hasnt 查詢失敗`（macOS `?m`、
# glibc 垃圾數字皆非查詢失敗）＋`has CI 跑中`（不管後面接的是 `?` 還是垃圾數字，只要走了 pending 分支
# 就一定印這四個字，不依賴 jq 對這個值的日期解析結果）；不再對分鐘值本身斷言。
mut_pr_m4a="$work/patrol.no-zerodate-prefix.sh"
python3 - "$patrol" "$mut_pr_m4a" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = 'if $s == "" or ($s | startswith("0001-01-01")) then ""'
new = 'if $s == "" then ""'
assert src.count(old) == 1, "找不到 Go 零值前綴守門，mutation 樣板需同步"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
out28m4a="$(PATH="$work/bin:$PATH" bash "$mut_pr_m4a" --repo "$repo" --no-fetch 10 2>&1)"
l907m4a=$(row "$out28m4a" 'feature/LS-907-realjq-zerodate')
has   '㉘ mutant（拿掉零值前綴守門，留 try/catch）：仍走 pending 分支印「CI 跑中」（不斷言分鐘值——macOS 印 ?、glibc 印垃圾數字，兩者都對）' "$l907m4a" 'CI 跑中'
hasnt '㉘ mutant（拿掉零值前綴守門，留 try/catch）：不應退回查詢失敗（macOS try/catch 兜底、glibc 根本不拋錯，兩者皆不會查詢失敗）' "$l907m4a" '查詢失敗'

# mutation（m4，merge-review R3 delta i5，主要證據）：拿掉 try/catch（退回只有前綴守門的舊寫法）——
# 907 的 ci 項（startedAt="not-a-date"，strptime 格式比對失敗，不是範圍驗證，**所有** jq 版本都一致
# 拋錯——本機已用 jq 1.6 與系統版 jq-1.7.1-apple 個別驗證過，見 handoff）應該從「?m」變回「查詢
# 失敗」，證明 try/catch 正是這段程式碼造成的、且是可攜（不受平台影響）的驗證方式，不像舊版 mutation
# 依賴會因 jq 版本而異的零值拋錯行為。
mut_pr_m4="$work/patrol.no-trycatch.sh"
python3 - "$patrol" "$mut_pr_m4" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '(try (((now - ($s | fromdateiso8601)) / 60) | floor | tostring) catch "")'
new = '(((now - ($s | fromdateiso8601)) / 60) | floor | tostring)'
assert src.count(old) == 1, "找不到 try/catch 包裝，mutation 樣板需同步"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
out28m4="$(PATH="$work/bin:$PATH" bash "$mut_pr_m4" --repo "$repo" --no-fetch 10 2>&1)"
l907m=$(row "$out28m4" 'feature/LS-907-realjq-zerodate')
has   '㉘ mutant（m4／i5）：拿掉 try/catch → 907 的 not-a-date 項從「?m」退回「查詢失敗」（證明 try/catch 是這段程式碼造成的，且用可攜的 not-a-date 而非平台相依的零值）' "$l907m" '查詢失敗'
hasnt '㉘ mutant（m4／i5）：不再印出正確的 ?m 結果' "$l907m" 'CI 跑中 ?m'
l906m4=$(row "$out28m4" 'feature/LS-906-realjq-normal')
has   '㉘ mutant（m4／i5）對照：906（沒有 not-a-date、只有正常時間＋pass 零值）不受影響仍正確' "$l906m4" 'CI 跑中 17m（ci、ci-ipad）'

if [ "$fail" -eq 0 ]; then
  echo "✓ patrol／session-start 自測通過"
fi
exit "$fail"
