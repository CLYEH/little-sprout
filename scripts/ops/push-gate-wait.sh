#!/bin/bash
# push-gate-wait.sh — LS-358（09-24 prompt 稽核 A-L1）：ios-dev.md 原本約 3,000 字的「暖 push gate 快取→570s
# 分段等待→分辨仍在跑／真的跑完→重跑一次確認快取命中→git push→origin 對 HEAD」全是由輸入決定的步驟，
# 交給模型逐步照做已出三次事故、累積一層層補丁；這支把它寫成可重入的獨立命令，agent 只照 exit code 走。
# Incidents: LS-313, LS-315, LS-341
#   LS-313：pre-push hook 跑 20–40 分鐘 push gate，SSH 閒置被對端重置（exit 141），背景通知的 exit 0 是尾端 echo 的
#   LS-315：全域 `pgrep -f xcodebuild` 等待迴圈等到別票的 xcodebuild，四支迴圈疊到 3h53m
#   LS-341：`pgrep -f 'worktrees/LS-33'` 不帶尾斜線，子字串比對誤配到 LS-333 的路徑
#
# 用法（在票 worktree 內呼叫；給 --ticket 時也可從同 repo 任何 checkout 呼叫，腳本用 git worktree list 找路徑）：
#   push-gate-wait.sh [--ticket LS-<n>] [--worktree <path>]          ① 暖快取／分段等待
#   push-gate-wait.sh [--ticket LS-<n>] --confirm                   ② push 前確認快取命中
#   push-gate-wait.sh [--ticket LS-<n>] --verify-push <branch>      ③ push 後以 origin/<branch> 對本機 HEAD
#   --max-seconds <n>  ① 單次呼叫最長等待秒數（預設 520）；--interval <sec> 輪詢間隔（預設 20）——兩者相加須
#                      <570（Bash 工具 600s 上限前留 30s，呼叫本身永遠不會被截斷）；非自測不要調
#
# ① 預設模式：本 worktree 沒有 push gate 在跑、這個 tree 也還沒有結果 → 在 worktree 內以**絕對路徑**、stdin 接
#    /dev/null 脫離啟動 push-gate.sh（輸出＋`push-gate rc=<n>` 寫進 log；log 第一行記 tree），然後前景最多等
#    --max-seconds 秒。gate 常跑 2–25 分，遠超 Bash 工具 10 分上限——舊流程是「前景跑到被截斷、殘留行程在背景
#    繼續跑、再手寫 pgrep 迴圈等它」，正是 ios-dev.md「不得依賴截斷後的自動背景化」禁止的形狀；這裡改成 gate
#    一開始就脫離、每次呼叫都在上限內自己乾淨回傳，同一支命令重呼叫即可接續等待，不會重複啟動第二輪。
#    「在跑」的判定只看命令列含 `<worktree 絕對路徑>/`（帶尾斜線，LS-341）且含 xcodebuild／push-gate 的行程，
#    濾掉命令列含 `push-gate-wait`（自己與並行的另一次呼叫，LS-344／LS-346 sibling 形狀）與 `pgrep -f`（照舊
#    ios-dev.md 手寫、還活著的等待迴圈）的候選；別票的 gate 永遠不會被等到（LS-315）。`git push` 觸發、還在
#    跑的 pre-push gate 也會被等到（它的命令列同樣帶 worktree 絕對路徑）。
# ② --confirm：以 LS_PUSH_GATE_CACHE_ONLY=1 前景重跑一次 push-gate.sh（stdin 接 /dev/null）——快取命中（或本分支
#    無 Swift 變更、根本不跑 unit tests）→ exit 0，可以 `git push`，pre-push 只會重放快取、幾秒完成；快取未寫入
#    → push-gate.sh 不跑 unit tests 直接 exit 4，本腳本也 exit 4（回到 ①）。
# ③ --verify-push：`git log -1 origin/<branch>` 對照本機 HEAD——push 是否成功只看這個，不看背景通知或管線尾端
#    的 exit code（LS-313）。
#
# stdin 保護（LS-354 池 0f76bf7a）：push-gate.sh 在 stdin 不是 tty 時會把 stdin 交給 push-ref-check.sh 逐行讀
# pre-push 的 ref 清單；從 Bash 工具（或任何沒關的管線）呼叫時 stdin 可能永遠不會 EOF，gate 就卡在讀 stdin。
# 本腳本呼叫 push-gate.sh 的兩處（① 脫離啟動、② 前景重跑）一律 `< /dev/null`，讀到空清單＝照常跑完整 gate。
#
# exit：
#   0＝① 本 tree 的 gate 已跑完且 rc=0（印 log 尾與 rc，下一步 --confirm）／② 可以 git push／③ origin 已是 HEAD
#   1＝① gate 已跑完但 rc≠0（印 log 尾；修好或照 gate 印的建議處理後再呼叫一次＝重跑）／② gate 在便宜檢查就紅
#     ／③ origin/<branch> 不是本機 HEAD（push 沒成功，前景重跑 git push）
#   2＝參數或環境錯（不在票 worktree、--ticket 與 --worktree 不一致、找不到 push-gate.sh…）
#   3＝① 到 --max-seconds 仍在跑，印「仍在跑…再呼叫一次」——照印出的命令再呼叫；② 呼叫時 gate 仍在跑
#   4＝② 快取未寫入（上一輪沒全綠或 tree 變了）→ 回到 ① 再暖一次
#
# 自測：scripts/ops/push-gate-wait.test.sh（CI rules job「Ops 腳本自測」step；selftest-wiring-check 清單）。
# 規約：.claude/agents/ios-dev.md（push 前一條）、docs/COLLABORATION.md §7。
set -uo pipefail

MAX_TOTAL_SEC=570

usage() {
  sed -n '10,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

ticket=
worktree=
mode='wait'
verify_branch=
max_seconds=520
interval=20

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --ticket)
      [ -n "${2:-}" ] || { echo "✗ push-gate-wait：--ticket 缺值" >&2; exit 2; }
      ticket=$2; shift 2 ;;
    --worktree)
      [ -n "${2:-}" ] || { echo "✗ push-gate-wait：--worktree 缺值" >&2; exit 2; }
      worktree=$2; shift 2 ;;
    --confirm) mode=confirm; shift ;;
    --verify-push)
      [ -n "${2:-}" ] || { echo "✗ push-gate-wait：--verify-push 缺 <branch>" >&2; exit 2; }
      mode=verify; verify_branch=$2; shift 2 ;;
    --max-seconds)
      [ -n "${2:-}" ] || { echo "✗ push-gate-wait：--max-seconds 缺值" >&2; exit 2; }
      max_seconds=$2; shift 2 ;;
    --interval)
      [ -n "${2:-}" ] || { echo "✗ push-gate-wait：--interval 缺值" >&2; exit 2; }
      interval=$2; shift 2 ;;
    *) echo "✗ push-gate-wait：未知參數「$1」" >&2; usage; exit 2 ;;
  esac
done

case "$max_seconds" in ''|*[!0-9]*) echo "✗ push-gate-wait：--max-seconds 必須是正整數" >&2; exit 2 ;; esac
case "$interval" in ''|0|*[!0-9]*) echo "✗ push-gate-wait：--interval 必須是正整數" >&2; exit 2 ;; esac
if [ $((max_seconds + interval)) -ge "$MAX_TOTAL_SEC" ]; then
  echo "✗ push-gate-wait：--max-seconds ${max_seconds}＋--interval ${interval} ≥ ${MAX_TOTAL_SEC}s，逼近 Bash 工具 600s 上限——調小" >&2
  exit 2
fi
if [ -n "$ticket" ]; then
  case "$ticket" in LS-[1-9]*) ;; *) echo "✗ push-gate-wait：--ticket 必須是 LS-<n>（得到「${ticket}」）" >&2; exit 2 ;; esac
  case "${ticket#LS-}" in *[!0-9]*) echo "✗ push-gate-wait：--ticket 必須是 LS-<n>（得到「${ticket}」）" >&2; exit 2 ;; esac
fi

# ---- 找票 worktree：--worktree ＞ --ticket（git worktree list）＞ cwd 所在 worktree ----
if [ -z "$worktree" ] && [ -n "$ticket" ]; then
  worktree=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | grep -E "/worktrees/${ticket}\$" | head -n 1)
  [ -n "$worktree" ] || { echo "✗ push-gate-wait：git worktree list 找不到 */worktrees/${ticket}（在同一個 repo 內呼叫，或改給 --worktree）" >&2; exit 2; }
fi
[ -n "$worktree" ] || worktree=$(git rev-parse --show-toplevel 2>/dev/null) \
  || { echo "✗ push-gate-wait：cwd 不在 git repo 內（改給 --ticket LS-<n> 或 --worktree <path>）" >&2; exit 2; }
worktree=$(cd "$worktree" 2>/dev/null && pwd -P) || { echo "✗ push-gate-wait：--worktree 不是目錄" >&2; exit 2; }
wt_ticket=$(basename "$worktree")
case "$worktree" in
  */worktrees/LS-[1-9]*) ;;
  *) echo "✗ push-gate-wait：${worktree} 不是票 worktree（*/worktrees/LS-<n>）——在主 checkout 暖到的是 main 的 tree，對票分支沒用" >&2; exit 2 ;;
esac
case "${wt_ticket#LS-}" in *[!0-9]*) echo "✗ push-gate-wait：${worktree} 不是票 worktree（*/worktrees/LS-<n>）" >&2; exit 2 ;; esac
if [ -n "$ticket" ] && [ "$ticket" != "$wt_ticket" ]; then
  echo "✗ push-gate-wait：--ticket ${ticket} 與 worktree ${worktree}（${wt_ticket}）不一致" >&2; exit 2
fi
ticket=$wt_ticket
gate="${worktree}/scripts/gates/push-gate.sh"
[ -f "$gate" ] || { echo "✗ push-gate-wait：找不到 ${gate}" >&2; exit 2; }

self_cmd="bash ${worktree}/scripts/ops/push-gate-wait.sh --ticket ${ticket}"

# ---- ③ --verify-push ----
if [ "$mode" = verify ]; then
  head_sha=$(git -C "$worktree" rev-parse HEAD) || exit 2
  remote_sha=$(git -C "$worktree" rev-parse -q --verify "refs/remotes/origin/${verify_branch}" 2>/dev/null)
  echo "origin/${verify_branch}：$(git -C "$worktree" log -1 --format='%h %s' "refs/remotes/origin/${verify_branch}" 2>/dev/null || echo '（不存在）')"
  echo "本機 HEAD：$(git -C "$worktree" log -1 --format='%h %s' HEAD)"
  if [ "$remote_sha" = "$head_sha" ]; then
    echo "✓ push-gate-wait：origin/${verify_branch} = 本機 HEAD ${head_sha}，push 成功"
    exit 0
  fi
  echo "✗ push-gate-wait：origin/${verify_branch}（${remote_sha:-不存在}）≠ 本機 HEAD ${head_sha}——push 沒成功（不看背景通知或管線尾端的 exit code），前景重跑 git push 後再驗" >&2
  exit 1
fi

# ---- 共用：log 位置（git-common-dir，所有 worktree 共用、呼叫之間不會消失）與「在跑」判定 ----
common_dir=$(cd "$worktree" && cd "$(git rev-parse --git-common-dir)" && pwd -P) \
  || { echo "✗ push-gate-wait：解不出 git-common-dir" >&2; exit 2; }
# 目錄名不可含 push-gate-wait：log 路徑會出現在脫離行程的命令列上，含這個字會被 gate_running() 的自我過濾濾掉
log_dir="${common_dir}/ls-gate-logs"
log="${log_dir}/${ticket}-push-gate.log"
lock="${log_dir}/${ticket}.launch.lock"
mkdir -p "$log_dir" || { echo "✗ push-gate-wait：無法建立 ${log_dir}" >&2; exit 2; }

# MUTATION-SCOPE（自測把尾斜線拿掉：LS-9001 會誤配 LS-90011 的行程）
scope_pattern="${worktree}/"
gate_running() {
  local pids p cmds=
  pids=$(pgrep -f "$scope_pattern" 2>/dev/null) || return 1
  for p in $pids; do
    cmds="${cmds}$(ps -o command= -p "$p" 2>/dev/null)
"
  done
  # MUTATION-FILTER（自測拿掉其中一層：sibling 呼叫或舊手寫迴圈會被當成 gate、等到逾時）
  # 刻意比對輸出而不用 grep -q：pipefail 下 grep -q 提早結束會讓上游吃 SIGPIPE、整條管線誤判失敗（LS-270）
  # shellcheck disable=SC2143
  [ -n "$(printf '%s' "$cmds" | grep -v 'push-gate-wait' | grep -v 'pgrep -f' | grep 'xcodebuild\|push-gate')" ]
}

# ---- ② --confirm ----
if [ "$mode" = confirm ]; then
  if gate_running; then
    echo "✗ push-gate-wait：${worktree} 的 push gate 仍在跑——先用 ${self_cmd} 等它結束（exit 0）再 --confirm" >&2
    exit 3
  fi
  # MUTATION-STDIN-CONFIRM（`< /dev/null`：前景呼叫不像 `&` 會自動接 /dev/null，拿掉就繼承呼叫端沒關的 stdin、卡在 push-ref-check）
  out=$(cd "$worktree" && LS_PUSH_GATE_CACHE_ONLY=1 bash "$gate" < /dev/null 2>&1); rc=$?
  printf '%s\n' "$out" | tail -n 15 | sed 's/^/  /'
  if [ "$rc" -eq 4 ] && grep -qF '快取未命中' <<<"$out"; then
    echo "✗ push-gate-wait：快取未寫入（上一輪沒全綠或 tree 變了）——不要 git push，回到 ${self_cmd} 再暖一次（exit 4）" >&2
    exit 4
  fi
  if [ "$rc" -ne 0 ]; then
    echo "✗ push-gate-wait：push-gate.sh rc=${rc}（unit tests 以外的檢查紅了，見上面輸出）——修好再從 ${self_cmd} 開始" >&2
    exit 1
  fi
  if grep -qF -e '跳過（快取' -e '跳過 unit tests' -e '無需完整 gate' -e '尚未建立 Xcode 專案' <<<"$out"; then
    echo "✓ push-gate-wait：快取命中（或本分支不跑 unit tests）——現在前景 git push（timeout 600000、< /dev/null），push 後 ${self_cmd} --verify-push <branch>"
    exit 0
  fi
  echo "✗ push-gate-wait：push-gate.sh rc=0 但輸出沒有「跳過（快取」等任何已知字樣——push-gate.sh 的字樣可能改了，本腳本需同步（fail closed）" >&2
  exit 1
fi

# ---- ① 預設模式 ----
cur_tree=$(git -C "$worktree" rev-parse 'HEAD^{tree}') || exit 2
log_tree() { [ -f "$log" ] && sed -n '1s/^# push-gate-wait: tree=\([0-9a-f]*\).*/\1/p' "$log"; }
log_rc() { [ -f "$log" ] && sed -n 's/^push-gate rc=\([0-9][0-9]*\)$/\1/p' "$log" | tail -n 1; }

report() {
  local rc
  rc=$(log_rc)
  echo "── log 尾 20 行（${log}）──"
  tail -n 20 "$log" | sed 's/^/  /'
  if [ "$rc" = 0 ]; then
    echo "✓ push-gate-wait：push gate 已結束 rc=0（tree ${cur_tree}）——下一步 ${self_cmd} --confirm"
    exit 0
  fi
  # 失敗結果不留：改名保存，下一次呼叫＝重跑（照 gate 印的建議處理完、或修好 code 後直接再呼叫）
  mv -f "$log" "${log}.failed"
  echo "✗ push-gate-wait：push gate 已結束 rc=${rc}（log 已改名 ${log}.failed）——依上面輸出修好（逾時／宿主 crash 照 gate 印的建議）後再呼叫 ${self_cmd}" >&2
  exit 1
}

acquire_launch_lock() {
  local owner
  if mkdir "$lock" 2>/dev/null; then echo $$ > "$lock/pid"; return 0; fi
  owner=$(cat "$lock/pid" 2>/dev/null)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then return 1; fi
  rm -rf "$lock"
  mkdir "$lock" 2>/dev/null && { echo $$ > "$lock/pid"; return 0; }
  return 1
}

launch() {
  local _
  {
    echo "# push-gate-wait: tree=${cur_tree} head=$(git -C "$worktree" rev-parse HEAD) started=$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$log"
  # 整個脫離子樹的 stdin／stdout／stderr 一起改接：stdin 接 /dev/null＝gate 讀到空 ref 清單照跑完整 gate（非互動
  # bash 的 `&` 本來就會把 stdin 接到 /dev/null，這裡明寫不靠隱含行為）；stdout／stderr 不接走的話，`cd && nohup … &`
  # 這層背景子 shell 會一直握著呼叫端的輸出管線，呼叫端（Bash 工具／$(...)）要等 gate 跑完才拿得到結果＝又被截斷。
  # shellcheck disable=SC2016  # $1／$2 由 bash -c 的位置參數展開，刻意單引號
  ( cd "$worktree" && nohup bash -c 'bash "$1" >> "$2" 2>&1; echo "push-gate rc=$?" >> "$2"' push-gate-run "$gate" "$log" & ) < /dev/null > /dev/null 2>&1
  echo "→ push-gate-wait：已脫離啟動 ${gate}（$(date '+%H:%M:%S')；log ${log}）"
  # 等脫離行程 exec 完、命令列出現在行程表上，再放掉啟動鎖——避免並行的另一次呼叫在這個空檔判定「沒在跑」又啟動一輪
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    gate_running && return 0
    [ -n "$(log_rc)" ] && return 0
    sleep 0.5
  done
}

start_ts=$(date +%s)
launched=0
while :; do
  elapsed=$(( $(date +%s) - start_ts ))
  # MUTATION-BUDGET-START（自測拿掉：gate 比 --max-seconds 久時呼叫不再乾淨回傳，一路等到 gate 結束＝被 Bash 工具截斷）
  if [ "$elapsed" -ge "$max_seconds" ]; then
    echo "仍在跑：本次已等 $((elapsed / 60)) 分 $((elapsed % 60)) 秒（log ${log}）／再呼叫一次 ${self_cmd}"
    [ -f "$log" ] && tail -n 3 "$log" | sed 's/^/  /'
    exit 3
  fi
  # MUTATION-BUDGET-END
  if gate_running; then
    sleep "$interval"; continue
  fi
  if [ "$(log_tree)" = "$cur_tree" ] && [ -n "$(log_rc)" ]; then
    report
  fi
  if [ "$(log_tree)" = "$cur_tree" ] && [ "$launched" -eq 1 ]; then
    echo "✗ push-gate-wait：本次啟動的 gate 已不在行程表上，但 log 沒有 rc 行（被外力中止？）——看 ${log}，再呼叫 ${self_cmd} 會重跑" >&2
    mv -f "$log" "${log}.failed"
    exit 1
  fi
  if acquire_launch_lock; then
    if ! gate_running; then
      if [ -f "$log" ] && [ "$(log_tree)" = "$cur_tree" ]; then
        echo "⚠ push-gate-wait：上一輪 log 沒有 rc 行、也沒有 gate 在跑（被中止？）——重新啟動" >&2
      elif [ -f "$log" ]; then
        echo "→ push-gate-wait：tree 已變（log 記 $(log_tree)，現在 ${cur_tree}）——重新暖快取"
      fi
      launch
      launched=1
    fi
    rm -rf "$lock"
    continue
  fi
  # 啟動鎖在別的呼叫手上（它正在啟動）：稍等再看
  sleep 1
done
