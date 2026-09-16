#!/bin/bash
# pen-open.sh 的自測（LS-91；R2 補自動清場 3 組）。CI 自測 step 每個 PR 都跑。
# stub `open`（記錄呼叫；依 $PEN_STUB_OPEN_SUCCEED_AT 決定第幾次呼叫才真的切換 active document，模擬
# 「清場後重開才成功」）、`pen`（依控制檔決定 get_app_state 的輸出：命中目標路徑／命中別的路徑／讀不到／
# 掛住）、`pgrep`（回傳測試自己起的假 Pen 行程 pid）、`osascript`（依 $PEN_STUB_OSASCRIPT_KILLS 決定「優雅
# 退出」是否真的把假行程殺掉，藉此驗兩條路徑：osascript 成功、osascript 沒反應時 fall back 到 `kill -TERM`——
# 這兩個字都是真的 shell 內建 `kill`，作用在測試自己 `sleep &` 出來的真行程上，不需要另外 stub `kill`）——
# 全程不碰真正的 Pen app 或 pen CLI session。
# 「前饋必有反饋」對 gate 本身也適用：若路徑比對退化成子字串、逾時判斷漏放行不一致案例、
# Pen 未開時誤放行、--status 模式意外呼叫了 `open`、清場前沒先驗安全就 quit、或清場後沒有真的重試，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/pen-open.sh"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
cleanup() {
  [ -f "${work}/fake_pen.pid" ] && kill -9 "$(cat "${work}/fake_pen.pid")" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

bin="${work}/bin"
mkdir -p "$bin"
wt="${work}/wt"
mkdir -p "${wt}/design"
cat > "${wt}/design/littlesprout.pen" <<'JSON'
{"version":1,"children":[]}
JSON
want="$(cd "${wt}/design" && pwd -P)/littlesprout.pen"

export PEN_STUB_STATE="${work}/state"
export PEN_STUB_OPEN_LOG="${work}/open.log"
export PEN_STUB_OPEN_COUNT="${work}/open.count"
export PEN_STUB_PID_FILE="${work}/fake_pen.pid"
: > "$PEN_STUB_OPEN_LOG"

# stub `open`：記錄呼叫參數；第 3 個參數是目標路徑。預設（PEN_STUB_OPEN_SUCCEED_AT 未設或 0）永遠不切換
# active document（模擬「殘留視窗擋住」）；設成 N 時，第 N 次呼叫會把 $PEN_STUB_STATE 寫成該次的目標路徑
# （模擬「清場後這次真的開成功」）。
cat > "${bin}/open" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${PEN_STUB_OPEN_LOG:?}"
target_path=$3
count=$(( $(cat "${PEN_STUB_OPEN_COUNT:?}" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$count" > "${PEN_STUB_OPEN_COUNT}"
succeed_at="${PEN_STUB_OPEN_SUCCEED_AT:-0}"
if [ "$succeed_at" != 0 ] && [ "$count" -ge "$succeed_at" ]; then
  printf 'PATH:%s' "$target_path" > "${PEN_STUB_STATE:?}"
fi
exit 0
STUB
chmod +x "${bin}/open"

# stub `pgrep`：只回傳測試自己起的假 Pen 行程 pid（$PEN_STUB_PID_FILE 有內容就印出來，沒有就不印任何東西，
# 模擬「找不到殘留行程」）。**LS-308 A3**：pen-open.sh --kill 清場後會另外用 pgrep -f <mcp-server 樣式> 查 mcp-server
# 行程（lib/pencil-mcp.sh 的 pencil_mcp_probe）——依樣式分流到獨立的 $PEN_STUB_MCP_PIDS（預設空，不干擾既有的
# Pen 主行程夾具）。
export PEN_STUB_MCP_PIDS="${work}/mcp_pids"
: > "$PEN_STUB_MCP_PIDS"
cat > "${bin}/pgrep" <<'STUB'
#!/bin/bash
case "$*" in
  *mcp-server*) [ -s "${PEN_STUB_MCP_PIDS:?}" ] && cat "${PEN_STUB_MCP_PIDS}" ;;
  *) [ -s "${PEN_STUB_PID_FILE:?}" ] && cat "${PEN_STUB_PID_FILE}" ;;
esac
exit 0
STUB
chmod +x "${bin}/pgrep"
set_mcp_pids() { printf '%s\n' "$1" > "$PEN_STUB_MCP_PIDS"; }
clear_mcp_pids() { : > "$PEN_STUB_MCP_PIDS"; : > "${PEN_STUB_MCP_PS_DB:?}"; }

# stub `osascript`：依 $PEN_STUB_OSASCRIPT_KILLS（1｜0，預設 0）決定「優雅退出」是否真的把假行程殺掉；
# 0 時什麼都不做，讓 pen-open.sh 自己之後補的 `kill -TERM`（真指令，不是 stub）去善後。
cat > "${bin}/osascript" <<'STUB'
#!/bin/bash
if [ "${PEN_STUB_OSASCRIPT_KILLS:-0}" = 1 ] && [ -s "${PEN_STUB_PID_FILE:?}" ]; then
  kill -TERM "$(cat "${PEN_STUB_PID_FILE}")" 2>/dev/null
fi
exit 0
STUB
chmod +x "${bin}/osascript"

# stub `ps`：R3 F1 的完整修法會用 `ps -Ao command | grep 'Pen Helper' | grep -oE ...` 唯讀枚舉目前所有開著的
# .pen——這裡必須 stub 掉真正的系統 `ps`，否則測試會撈到這台機器上真正在跑的 Pen（若有）並汙染候選清單。
# 只印 $PEN_STUB_PS_OUTPUT 檔案內容（沒有該檔就印空，等同「ps 沒撈到任何額外視窗」）。**LS-308 A3**：同一支 `ps`
# 也要應付 `lib/pencil-mcp.sh` 的 `-o ppid=／-o command= -p <pid>` 用法——用 `-Ao` 開頭分流到舊行為，其餘走
# $PEN_STUB_MCP_PS_DB（「<pid> <ppid> <command>」表，格式同 pen-status.test.sh 的 set_mcp_parent）。
export PEN_STUB_PS_OUTPUT="${work}/ps_output"
export PEN_STUB_MCP_PS_DB="${work}/mcp_ps.db"
: > "$PEN_STUB_PS_OUTPUT"
: > "$PEN_STUB_MCP_PS_DB"
cat > "${bin}/ps" <<'STUB'
#!/bin/bash
if [ "${1:-}" = -Ao ]; then
  [ -f "${PEN_STUB_PS_OUTPUT:?}" ] && cat "${PEN_STUB_PS_OUTPUT}"
  exit 0
fi
mode=; pid=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) mode=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -f "${PEN_STUB_MCP_PS_DB:?}" ] || exit 0
row=$(awk -v p="$pid" '$1 == p { $1=""; sub(/^ /, ""); print }' "${PEN_STUB_MCP_PS_DB}")
[ -n "$row" ] || exit 0
ppid=${row%% *}
cmd=${row#* }
case "$mode" in
  ppid=) printf '%s\n' "$ppid" ;;
  command=) printf '%s\n' "$cmd" ;;
esac
exit 0
STUB
chmod +x "${bin}/ps"
# set_mcp_parent <mcp pid> <parent pid> <parent command>：補齊 pencil_mcp_probe 兩次查詢需要的兩筆——
# mcp pid 自己的 ppid＝parent_pid；parent_pid 自己的 command＝parent_cmd（同 pen-status.test.sh 的慣例）。
set_mcp_parent() {
  local mcp_pid=$1 parent_pid=$2 parent_cmd=$3
  printf '%s %s -\n' "$mcp_pid" "$parent_pid" >> "$PEN_STUB_MCP_PS_DB"
  printf '%s 1 %s\n' "$parent_pid" "$parent_cmd" >> "$PEN_STUB_MCP_PS_DB"
}
# set_ps_pen_files <path>...：模擬 `ps -Ao command` 印出的 Pen renderer 命令列，每個路徑一行，格式貼近本票
# 實機格式（`--init-params={"documentState":{"fileURI":"file://<path>",...}}`），讓 grep -oE 的樣式抓得到。
set_ps_pen_files() {
  : > "$PEN_STUB_PS_OUTPUT"
  local p
  for p in "$@"; do
    printf '/Applications/Pen.app/.../Pen Helper (Renderer) --init-params={"documentState":{"fileURI":"file://%s","isDirty":false}}\n' "$p" >> "$PEN_STUB_PS_OUTPUT"
  done
}
clear_ps_pen_files() { : > "$PEN_STUB_PS_OUTPUT"; }

# stub `pen`：只認 `interactive --app desktop`，讀 stdin 分兩路——
#   餵進來的是 `execute(`（LS-180／LS-309 tree_hash 回讀）：**先看 $PEN_STUB_HASH_QUEUE**（LS-309 分段測試用）——
#     檔案存在且非空時，依「第 N 次 execute 呼叫」（N＝本次遞增後的 $PEN_STUB_EXEC_COUNT）取該檔第 N 行當作這次的
#     原文輸出（`FAIL` 或缺該行＝模擬 InternalError: interrupted），一行對應 pen-open.sh 依序送出的每一次 execute
#     （整棵單次 → root 數量探測 → 各分段），讓測試能精確控制「這一次呼叫是分段流程的第幾步、成功還是失敗」，
#     不必猜 pen-open.sh 內部怎麼組 SCAN_HASH_ROOTS。**沒有 queue 檔（多數既有 LS-180 測試）才退回舊版**：依
#     $PEN_STUB_HASH 控制檔——HASH:<16 hex> → 印 `SUMMARY-HASH total_nodes=… tree_hash=<hex>`；HANG → sleep 5
#     （測 PEN_OPEN_HASH_TIMEOUT 看門狗）；其他／空 → 模擬 Pencil `InternalError: interrupted`。每次呼叫把
#     $PEN_STUB_EXEC_COUNT 加一（驗「預設模式不回讀雜湊」／LS-309 分段測試靠這個數字對應 queue 行號）。
#   其他（get_app_state）：依 $PEN_STUB_STATE——PATH:<path> → 印 get_app_state 格式的那一行；HANG → sleep 5（測
#     ATTEMPT_TIMEOUT 看門狗）；其他 → 模擬讀不到
export PEN_STUB_HASH="${work}/hash"
export PEN_STUB_EXEC_COUNT="${work}/exec.count"
export PEN_STUB_HASH_QUEUE="${work}/hash.queue"
cat > "${bin}/pen" <<'STUB'
#!/bin/bash
if [ "$1" != interactive ]; then exit 1; fi
input="$(cat)"
case "$input" in
  *execute\(*)
    n=$(( $(cat "${PEN_STUB_EXEC_COUNT:?}" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "${PEN_STUB_EXEC_COUNT}"
    if [ -s "${PEN_STUB_HASH_QUEUE:-/nonexistent-hash-queue}" ]; then
      line=$(sed -n "${n}p" "${PEN_STUB_HASH_QUEUE}")
      if [ -z "$line" ] || [ "$line" = FAIL ]; then
        echo "Error: InternalError: interrupted"
      else
        printf '%s\n' "$line"
      fi
      exit 0
    fi
    hc="$(cat "${PEN_STUB_HASH:?}" 2>/dev/null || true)"
    case "$hc" in
      HASH:*) printf 'SUMMARY-HASH total_nodes=1 tree_hash=%s\n' "${hc#HASH:}" ;;
      HANG) sleep 5 ;;
      *) echo "Error: InternalError: interrupted" ;;
    esac
    exit 0
    ;;
esac
content="$(cat "${PEN_STUB_STATE:?}" 2>/dev/null || true)"
case "$content" in
  PATH:*)
    p=${content#PATH:}
    printf 'Currently active canvas editor: `%s`\n' "$p"
    ;;
  HANG)
    sleep 5
    ;;
  *)
    echo "(no active document)"
    ;;
esac
STUB
chmod +x "${bin}/pen"

export PATH="${bin}:${PATH}"
export PEN_OPEN_TIMEOUT=2 PEN_OPEN_ATTEMPT_TIMEOUT=1 PEN_OPEN_POLL_INTERVAL=1
export PEN_OPEN_QUIT_TIMEOUT=3 PEN_OPEN_QUIT_GRACE=1
export PEN_OPEN_HASH_TIMEOUT=2 PEN_OPEN_HASH_ATTEMPTS=1
export PEN_BACKUP_DIR="${work}/backup"
mkdir -p "$PEN_BACKUP_DIR"

set_state() { printf '%s' "$1" > "$PEN_STUB_STATE"; }
set_hash() { printf '%s' "$1" > "$PEN_STUB_HASH"; }
open_calls() { wc -l < "$PEN_STUB_OPEN_LOG" | tr -d ' '; }
exec_calls() { cat "$PEN_STUB_EXEC_COUNT" 2>/dev/null || echo 0; }
reset_open_tracking() { : > "$PEN_STUB_OPEN_LOG"; rm -f "$PEN_STUB_OPEN_COUNT" "$PEN_STUB_EXEC_COUNT"; unset PEN_STUB_OPEN_SUCCEED_AT; }
# 磁碟端 tree_hash（與 pen-open.sh 用同一支 design_tree_hash.py 算），LS-180 案例拿它餵 stub 當「Pencil 端相符」的值。
WT_HASH="$(python3 "${root}/scripts/gates/design_tree_hash.py" "$want")"
# 預設讓 --force-reload 的雜湊回讀「不相符」（沿用 LS-118 案例的清場語意）；⑮ 各案自己覆寫。
set_hash 'HASH:ffffffffffffffff'

# start_fake_pen：起一支真的背景 sleep 當「假 Pen 主行程」，pid 寫進 $PEN_STUB_PID_FILE 給 pgrep stub 讀。
# fake_pen_alive：該行程是否還活著（kill -0，不 stub，因為這是測試自己起的真行程）。
# R3 I4：`disown` 讓這個背景 job 離開 shell 的 job table，被 kill 時 bash 才不會在下一次排程點印
# 「Terminated: 15」／「Killed: 9」這種 job-control 通知到 stderr（CI log 噪音，不影響判定，但 disown 後乾淨）。
start_fake_pen() { sleep 100 & echo $! > "$PEN_STUB_PID_FILE"; disown; }
fake_pen_alive() { kill -0 "$(cat "$PEN_STUB_PID_FILE" 2>/dev/null)" 2>/dev/null; }
# clear_fake_pen：測試場景交接用——先把上一輪可能還活著的假行程收乾淨（避免遺留 `sleep 100` 一路跑到自然到期），
# 再清掉 pid 檔記錄。
clear_fake_pen() {
  [ -s "$PEN_STUB_PID_FILE" ] && kill -9 "$(cat "$PEN_STUB_PID_FILE")" 2>/dev/null
  rm -f "$PEN_STUB_PID_FILE"
}

# wt2：第二個 worktree fixture，供「殘留視窗」情境的安全性檢查（pen-land.sh --dry-run）用。
wt2="${work}/wt2"
mkdir -p "${wt2}/design"
WT2_SAFE='{"version":1,"fileToken":"tok1","variables":{},"themes":{},"children":[{"id":"m1","x":1,"children":[]}]}'
printf '%s' "$WT2_SAFE" > "${wt2}/design/littlesprout.pen"
want2="$(cd "${wt2}/design" && pwd -P)/littlesprout.pen"
wt2_resolved="$(cd "$wt2" && pwd -P)"
wt2_backup_safe() { printf '%s' "$WT2_SAFE" > "${PEN_BACKUP_DIR}/$(printf '%s' "file://${want2}" | shasum | awk '{print $1}')"; }
wt2_backup_unsafe() { printf '%s' '{"version":1,"fileToken":"tok1","variables":{},"themes":{},"children":[{"id":"m1","x":1,"children":[{"id":"m2","y":9,"children":[]}]}]}' > "${PEN_BACKUP_DIR}/$(printf '%s' "file://${want2}" | shasum | awk '{print $1}')"; }
# wt 自己（目標文件）也要能標成安全，供 ⑪e 驗證「隱藏第三視窗」單獨拒絕清場的情境。
WT_SAFE='{"version":1,"children":[]}'
wt_backup_safe() { printf '%s' "$WT_SAFE" > "${PEN_BACKUP_DIR}/$(printf '%s' "file://${want}" | shasum | awk '{print $1}')"; }
# LS-118 ⑬b：wt 自己的 backup 帶一個落地檔沒有的節點——真實（非白名單）差異，供「目標即使已是 active
# 仍可能有未落地變更」的 --force-reload 拒絕案例。
wt_backup_unsafe() { printf '%s' '{"version":1,"children":[{"id":"newnode","x":1,"children":[]}]}' > "${PEN_BACKUP_DIR}/$(printf '%s' "file://${want}" | shasum | awk '{print $1}')"; }

# wt3：只透過 ps 枚舉才會被看見的「隱藏」第三個視窗（LAST_SEEN／want 都不指向它）——驗證 R3 F1 完整修法：
# 沒有它，get_app_state 只回得出一個 active，這份不安全的視窗永遠不會被檢查到。
wt3="${work}/wt3"
mkdir -p "${wt3}/design"
WT3_SAFE='{"version":1,"fileToken":"tok1","variables":{},"themes":{},"children":[{"id":"z1","x":1,"children":[]}]}'
printf '%s' "$WT3_SAFE" > "${wt3}/design/littlesprout.pen"
want3="$(cd "${wt3}/design" && pwd -P)/littlesprout.pen"
wt3_backup_unsafe() { printf '%s' '{"version":1,"fileToken":"tok1","variables":{},"themes":{},"children":[{"id":"z1","x":1,"children":[{"id":"z2","y":2,"children":[]}]}]}' > "${PEN_BACKUP_DIR}/$(printf '%s' "file://${want3}" | shasum | awk '{print $1}')"; }

# wtP：LS-117 defect 1／2 用——真的 git 倉庫，.pen 已 commit（模擬「主 checkout：保護分支，本就不該被直接
# 編輯」），供 placeholder-only 漂移的安全判定測試。
wtP="${work}/wtP"
mkdir -p "${wtP}/design"
WTP_CLEAN='{"version":1,"fileToken":"tokP","variables":{},"themes":{},"children":[{"id":"iq3Ic","x":1,"placeholder":false,"children":[]}]}'
printf '%s' "$WTP_CLEAN" > "${wtP}/design/littlesprout.pen"
( cd "$wtP" && git init -q && git add -A && git -c user.email=test@example.com -c user.name=test commit -q -m init ) >/dev/null 2>&1
wantP="$(cd "${wtP}/design" && pwd -P)/littlesprout.pen"
wtP_backup() { printf '%s' "$1" > "${PEN_BACKUP_DIR}/$(printf '%s' "file://${wantP}" | shasum | awk '{print $1}')"; }
# 僅 iq3Ic 的 placeholder false→true，節點總數／id 不變：defect 1 的白名單漂移。
wtP_backup_placeholder_only() { wtP_backup '{"version":1,"fileToken":"tokP","variables":{},"themes":{},"children":[{"id":"iq3Ic","x":1,"placeholder":true,"children":[]}]}'; }
# 同時改了 x（非白名單屬性），即使節點總數不變也不是「僅白名單」。
wtP_backup_realdiff() { wtP_backup '{"version":1,"fileToken":"tokP","variables":{},"themes":{},"children":[{"id":"iq3Ic","x":2,"placeholder":true,"children":[]}]}'; }
# 弄髒 wtP 的落地檔本身（模擬「其實有人直接改了主 checkout 內容」）——仍是合法 JSON，只改 x。
wtP_make_dirty() { printf '%s' '{"version":1,"fileToken":"tokP","variables":{},"themes":{},"children":[{"id":"iq3Ic","x":5,"placeholder":false,"children":[]}]}' > "${wtP}/design/littlesprout.pen"; }
# backup 對齊「已弄髒」的落地檔，只多 placeholder 差異——結構上仍是「僅白名單」，但落地檔對 git 不 clean。
wtP_backup_placeholder_only_dirty() { wtP_backup '{"version":1,"fileToken":"tokP","variables":{},"themes":{},"children":[{"id":"iq3Ic","x":5,"placeholder":true,"children":[]}]}'; }
wtP_reset_clean() { git -C "$wtP" checkout -q -- design/littlesprout.pen; }

# wtQ：LS-118 R1 F2 用（merge-review）——真的 git 倉庫，落地檔 2 節點且 git-clean，backup 是舊快照
# （1 節點，backup mtime 明確早於落地檔）——mtime 方向偵測的正案例／邊界案例共用 fixture。
wtQ="${work}/wtQ"
mkdir -p "${wtQ}/design"
WTQ_CLEAN='{"version":1,"fileToken":"tokQ","variables":{},"themes":{},"children":[{"id":"q1","x":1,"children":[]},{"id":"q2","x":2,"children":[]}]}'
printf '%s' "$WTQ_CLEAN" > "${wtQ}/design/littlesprout.pen"
( cd "$wtQ" && git init -q && git add -A && git -c user.email=test@example.com -c user.name=test commit -q -m init ) >/dev/null 2>&1
wantQ="$(cd "${wtQ}/design" && pwd -P)/littlesprout.pen"
# backup＝落地檔的舊子集（少 q2），mtime 刻意設成很早，再把落地檔 touch 成「現在」確保方向明確不受時序影響。
wtQ_backup_stale() {
  printf '%s' '{"version":1,"fileToken":"tokQ","variables":{},"themes":{},"children":[{"id":"q1","x":1,"children":[]}]}' > "${PEN_BACKUP_DIR}/$(printf '%s' "file://${wantQ}" | shasum | awk '{print $1}')"
  touch -t 202501010000 "${PEN_BACKUP_DIR}/$(printf '%s' "file://${wantQ}" | shasum | awk '{print $1}')"
  touch "${wtQ}/design/littlesprout.pen"
}
# 弄髒落地檔本身（模擬「其實有人直接改了內容」），mtime 方向仍是落地檔較新，但不該被判定安全。
wtQ_make_dirty() { printf '%s' '{"version":1,"fileToken":"tokQ","variables":{},"themes":{},"children":[{"id":"q1","x":9,"children":[]},{"id":"q2","x":2,"children":[]}]}' > "${wtQ}/design/littlesprout.pen"; }
wtQ_reset_clean() { git -C "$wtQ" checkout -q -- design/littlesprout.pen; }

# wt4：LS-117 defect 3 用——從未被 Pen 開過的路徑，$PEN_BACKUP_DIR 裡刻意不建立對應 backup。
wt4="${work}/wt4"
mkdir -p "${wt4}/design"
printf '%s' '{"version":1,"children":[]}' > "${wt4}/design/littlesprout.pen"
want4="$(cd "${wt4}/design" && pwd -P)/littlesprout.pen"

# 「頑固」假 Pen 主行程：忽略 SIGTERM（`trap '' TERM` 的 ignore 處置在 `exec` 之後仍保留，符合真實
# Automation 權限被擋時 osascript／SIGTERM 皆無效的情境），只有 SIGKILL 殺得掉——驗證 LS-117 defect 2 的
# 強制路徑。用 `exec` 讓最終只有一個行程（就是 sleep 本身），不留孤兒行程。
stubborn_script="${work}/stubborn_pen.sh"
cat > "$stubborn_script" <<'STUB'
#!/bin/bash
trap '' TERM
exec sleep 20
STUB
chmod +x "$stubborn_script"
start_fake_pen_stubborn() { "$stubborn_script" & echo $! > "$PEN_STUB_PID_FILE"; disown; }

# mainCk／mainCkWt（LS-236）：真的 git 倉庫＋真的 linked worktree，供 `--restore` 與 `--kill` 清場後自動
# 還原主 checkout `design/littlesprout.pen` 用。mainCk 本身是主 working tree（`--git-dir`＝`--git-common-dir`），
# mainCkWt 是它的 linked worktree（兩者不相等）——比照 wtP 的「真的 git 倉庫」作法，不建 backup（同 wt4：
# 「查無 backup」是安全訊號，check_root_safe() 會判定可以清場，不需要為了通過安全判定去偽造 backup 內容）。
mainCk="${work}/mainCk"
mkdir -p "${mainCk}/design"
printf '%s' '{"version":1,"children":[]}' > "${mainCk}/design/littlesprout.pen"
( cd "$mainCk" && git init -q && git add -A && git -c user.email=test@example.com -c user.name=test commit -q -m init ) >/dev/null 2>&1
wantMain="$(cd "${mainCk}/design" && pwd -P)/littlesprout.pen"
mainCk_dirty() { printf '%s' '{"version":1,"children":[{"id":"polluted","children":[]}]}' > "${mainCk}/design/littlesprout.pen"; }
mainCk_reset_clean() { git -C "$mainCk" checkout -q -- design/littlesprout.pen; }

mainCkWt="${work}/mainCk-linked"
( cd "$mainCk" && git worktree add -q -b ls236-linked-branch "$mainCkWt" ) >/dev/null 2>&1
wantMainWt="$(cd "${mainCkWt}/design" && pwd -P)/littlesprout.pen"
mainCkWt_dirty() { printf '%s' '{"version":1,"children":[{"id":"polluted-wt","children":[]}]}' > "${mainCkWt}/design/littlesprout.pen"; }
mainCkWt_reset_clean() { git -C "$mainCkWt" checkout -q -- design/littlesprout.pen; }

run() { bash "$script" "$@"; }

# ---- 一致 ----
set_state "PATH:${want}"
before=$(open_calls)
out="$(run "$wt" 2>&1)"; got=$?
after=$(open_calls)
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "Pen 目前文件＝${want}" \
  && [ "$after" -eq $((before + 1)) ] && grep -qF -- "-a Pen ${want}" "$PEN_STUB_OPEN_LOG"; then
  ok '一致：路徑相符 → exit 0，且真的呼叫了 open -a Pen <want>'
else
  bad "一致案例應 exit 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- ⑭a LS-176（LS-96 池項 56eeaee0）：Pen 目前是「已被 cleanup-merged.sh 移除的 worktree」的路徑（推出的 root
#      與 .pen 都不在磁碟上）→ 無檔即無未落地變更可失，視為已捨棄，照常清場切檔成功（LS-176 之前判「不存在→
#      無法確認安全」而拒絕、exit 1，LS-152／LS-163 清理後每張後續設計票的 pen-read 都被擋）。$want 自己也在候選
#      清單裡，先給它安全 backup，讓「安全」的判定單純來自不存在的 other；訊息仍須含兩邊路徑 ----
other="${work}/wt-other/design/littlesprout.pen"
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_safe
set_state "PATH:${other}"
start_fake_pen
export PEN_STUB_OPEN_SUCCEED_AT=2 PEN_STUB_OSASCRIPT_KILLS=1
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "${want}" && printf '%s' "$out" | grep -qF "${other}" \
  && printf '%s' "$out" | grep -qF "舊路徑不存在，視為已捨棄：${other}" \
  && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" && ! fake_pen_alive; then
  ok '⑭a LS-176 舊路徑不存在：Pen 目前是已刪 worktree 的檔 → 視為已捨棄，清場切檔成功，訊息含兩邊路徑'
else
  bad "⑭a 應 exit 0 且清場切檔成功（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT PEN_STUB_OSASCRIPT_KILLS
clear_fake_pen
rm -f "${PEN_BACKUP_DIR}/$(printf '%s' "file://${want}" | shasum | awk '{print $1}')"

# ---- Pen 未開／讀不到（開檔模式） ----
set_state EMPTY
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '讀不到 Pen 文件路徑'; then
  ok 'Pen 未開（開檔模式）：讀不到路徑 → exit 2（fail closed）'
else
  bad "Pen 未開應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- 掛住：ATTEMPT_TIMEOUT 看門狗要能把卡住的 pen 進程殺掉，不讓整支腳本卡死 ----
set_state HANG
t0=$SECONDS
out="$(run "$wt" 2>&1)"; got=$?
elapsed=$((SECONDS - t0))
if [ "$got" -eq 2 ] && [ "$elapsed" -le 4 ]; then
  ok "掛住：pen 進程 sleep 5 但看門狗在 ${elapsed}s 內收工 → exit 2"
else
  bad "掛住案例應在數秒內 exit 2（實得 ${got}，耗時 ${elapsed}s）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- --status 模式 ----
set_state "PATH:${want}"
before=$(open_calls)
out="$(run --status 2>&1)"; got=$?
after=$(open_calls)
if [ "$got" -eq 0 ] && [ "$out" = "$want" ] && [ "$after" -eq "$before" ]; then
  ok '--status：讀到路徑就印出、exit 0，且不呼叫 open（不切檔）'
else
  bad "--status 成功案例應 exit 0 印出路徑且不呼叫 open（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

set_state EMPTY
out="$(run --status 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '讀不到 Pen 目前文件路徑'; then
  ok '--status：讀不到 → exit 2'
else
  bad "--status 失敗案例應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- 參數形狀 ----
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '用法'; then ok '無參數 → exit 2'; else bad "無參數應 exit 2（實得 ${got}）"; fi
out="$(run "$wt" extra 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '用法'; then ok '多參數 → exit 2'; else bad "多參數應 exit 2（實得 ${got}）"; fi

# ---- 環境與路徑錯誤 ----
out="$(PEN_BIN=does-not-exist-789 run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '找不到 pen CLI'; then ok 'PEN_BIN 找不到 → exit 2'; else bad "PEN_BIN 缺應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi

out="$(PEN_OPEN_TIMEOUT=abc run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '須為整數秒'; then ok '逾時參數非整數 → exit 2'; else bad "非整數逾時應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi

out="$(run "${work}/nope" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '找不到目錄'; then ok '目標目錄不存在 → exit 2'; else bad "目錄不存在應 exit 2（實得 ${got}）"; fi

mkdir -p "${work}/no-pen-file/design"
out="$(run "${work}/no-pen-file" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '找不到'; then ok 'design/littlesprout.pen 不存在 → exit 2'; else bad ".pen 缺應 exit 2（實得 ${got}）"; fi

# ---- R2：自動清場（殘留視窗指向真的存在、可判斷安不安全的 worktree）----

# ⑪a 殘留＋安全（wt2 與 want 自己的 backup 皆與磁碟檔一致，沒有未落地變更）→ osascript 優雅退出成功 → 重開切換成功
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt2_backup_safe; wt_backup_safe
set_state "PATH:${want2}"
start_fake_pen
export PEN_STUB_OPEN_SUCCEED_AT=2 PEN_STUB_OSASCRIPT_KILLS=1
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" \
  && printf '%s' "$out" | grep -qF '已確認' && ! fake_pen_alive \
  && printf '%s' "$out" | grep -qF 'Pencil MCP：下一次 MCP 呼叫會自動重連'; then
  ok '⑪a 殘留＋安全：osascript 優雅退出成功 → 重開切換成功，假行程真的結束，且印「下一次 MCP 呼叫會自動重連」（LS-180）'
else
  bad "⑪a 應 exit 0 且假行程結束（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT PEN_STUB_OSASCRIPT_KILLS

# ⑪b 殘留＋安全，但 osascript 沒反應（模擬 Automation 權限被擋，同本票實機發現）→ fall back 到 kill -TERM
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt2_backup_safe; wt_backup_safe
set_state "PATH:${want2}"
start_fake_pen
export PEN_STUB_OPEN_SUCCEED_AT=2 PEN_STUB_OSASCRIPT_KILLS=0
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" && ! fake_pen_alive; then
  ok '⑪b 殘留＋安全：osascript 沒反應 → fall back kill -TERM → 假行程結束、重開切換成功'
else
  bad "⑪b 應 exit 0 且假行程結束（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT PEN_STUB_OSASCRIPT_KILLS

# ⑪c 殘留＋有未落地變更（wt2 的 backup 與磁碟檔不同）→ 不 quit、不第二次 open，exit 1
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt2_backup_unsafe
set_state "PATH:${want2}"
start_fake_pen
export PEN_STUB_OPEN_SUCCEED_AT=2
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF "bash scripts/ops/pen-land.sh ${wt2_resolved}" \
  && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok '⑪c 殘留＋有未落地變更：不 quit、不重開，exit 1，假行程仍活著（LS-118 R1：訊息改為方向感知措辭，仍提及 pen-land.sh）'
else
  bad "⑪c 應 exit 1 且不動假行程（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)，open 呼叫次數＝$(open_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT

# ⑪d --no-quit：殘留時完全不嘗試清場（即使 wt2 其實安全），exit 1
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt2_backup_safe
set_state "PATH:${want2}"
start_fake_pen
out="$(run "$wt" --no-quit 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF -- '--no-quit：不嘗試清場' \
  && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok '⑪d --no-quit：殘留時不清場，exit 1，假行程不受影響'
else
  bad "⑪d 應 exit 1 且不清場（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ⑪e R3 F1 完整修法：ps 枚舉揪出「隱藏」的第三個視窗（get_app_state 只回得出一個 active，LAST_SEEN／want
# 都不指向它，光靠這兩個永遠看不到）——它有未落地變更，即使 active（wt2）與目標（want）自己都安全，整體
# 仍完全不清場。
reset_open_tracking; clear_fake_pen; wt2_backup_safe; wt_backup_safe; wt3_backup_unsafe
set_state "PATH:${want2}"
set_ps_pen_files "$want3"
start_fake_pen
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF "${want3}"   && printf '%s' "$out" | grep -qF '不自動 quit'   && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok '⑪e ps 枚舉揪出隱藏第三視窗不安全 → 即使 active／目標本身安全仍不清場（R3 F1 完整修法）'
else
  bad "⑪e 應偵測隱藏視窗並拒絕清場（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)，open 呼叫次數＝$(open_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen; clear_ps_pen_files

# ---- LS-117：三個缺陷 ----

# ⑫a defect 1（正案例）：wtP 僅 placeholder 差異、節點總數不變，且對 git 全程 clean → 視為安全，自動清場
#     切檔成功（不需人工 SIGKILL）。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wtP_backup_placeholder_only; wt_backup_safe
set_state "PATH:${wantP}"
start_fake_pen
export PEN_STUB_OPEN_SUCCEED_AT=2 PEN_STUB_OSASCRIPT_KILLS=0
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" \
  && printf '%s' "$out" | grep -qF '僅偵測到白名單' && ! fake_pen_alive; then
  ok '⑫a placeholder-only＋git-clean：視為安全 → 自動切檔成功，不需人工 SIGKILL（defect 1）'
else
  bad "⑫a 應 exit 0 且自動切檔成功（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT PEN_STUB_OSASCRIPT_KILLS

# ⑫b defect 1（負案例）：backup 結構上仍是「僅白名單差異」，但落地檔本身對 git 不 clean（有人直接改了
#     主 checkout 內容）→ 不視為安全，不清場，exit 1。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files
wtP_make_dirty; wtP_backup_placeholder_only_dirty
set_state "PATH:${wantP}"
start_fake_pen
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '不是 git-clean' && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok '⑫b placeholder-only 但落地檔對 git 不 clean → 不視為安全，不清場（defect 1 邊界）'
else
  bad "⑫b 應 exit 1 且不清場（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen
wtP_reset_clean

# ⑫c defect 1（邊界）：節點總數不變，但除了 placeholder 還有非白名單屬性（x）差異、git 也 clean → 仍不是
#     「僅白名單」，不視為安全，不清場，exit 1。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wtP_backup_realdiff
set_state "PATH:${wantP}"
start_fake_pen
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 1 ] && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok '⑫c 節點總數不變但混雜非白名單屬性差異 → 仍不視為安全，不清場（defect 1 邊界）'
else
  bad "⑫c 應 exit 1 且不清場（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ⑫d defect 3：查無 backup（從未被 Pen 開過的路徑）→ 視為安全訊號（非「無法確認」），自動清場切檔成功。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_safe
set_state "PATH:${want4}"
start_fake_pen
export PEN_STUB_OPEN_SUCCEED_AT=2 PEN_STUB_OSASCRIPT_KILLS=0
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" \
  && printf '%s' "$out" | grep -qF '查無 Pen backup' && ! fake_pen_alive; then
  ok '⑫d 查無 backup（從未編輯過）→ 視為安全，自動切檔成功（defect 3）'
else
  bad "⑫d 應 exit 0 且自動切檔成功（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT PEN_STUB_OSASCRIPT_KILLS

# ⑫e defect 2（正案例）：osascript／SIGTERM 對「頑固」假行程皆無效，但 SIGKILL 前重新確認仍安全 →
#     escalate SIGKILL，印稽核行，成功重開。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt2_backup_safe; wt_backup_safe
set_state "PATH:${want2}"
start_fake_pen_stubborn
export PEN_STUB_OPEN_SUCCEED_AT=2 PEN_STUB_OSASCRIPT_KILLS=0
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '稽核' && printf '%s' "$out" | grep -qF 'SIGKILL' \
  && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" && ! fake_pen_alive; then
  ok '⑫e SIGTERM 對頑固行程無效，重新確認仍安全 → escalate SIGKILL，印稽核行，重開成功（defect 2）'
else
  bad "⑫e 應 exit 0 且成功 SIGKILL 後重開（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT PEN_STUB_OSASCRIPT_KILLS

# ⑫f defect 2（負案例）：TERM 等待期間，原本安全的候選變得不安全（模擬「等待清場的空檔又生出實質變更」）
#     → SIGKILL 前重新確認發現有實質結構差異 → 拒絕強殺，需人工介入，行程仍活著。時間軸（本案例覆寫逾時
#     參數留出餘裕）：初次安全判定約在 t≈1-2s 完成（此時 backup 仍安全）；t=3s 背景工作把 wt2 的 backup
#     換成有實質差異；SIGKILL 前的重新確認落在 quit 等待結束後、約 t≈6-7s，此時應偵測到差異並拒絕。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt2_backup_safe; wt_backup_safe
set_state "PATH:${want2}"
start_fake_pen_stubborn
( sleep 3; wt2_backup_unsafe ) &
disown
out="$(PEN_OPEN_TIMEOUT=1 PEN_OPEN_QUIT_GRACE=1 PEN_OPEN_QUIT_TIMEOUT=5 run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '拒絕強殺' && fake_pen_alive; then
  ok '⑫f 等待期間變得不安全 → SIGKILL 前重新確認拒絕強殺（defect 2 拒絕路徑）'
else
  bad "⑫f 應 exit 2 且拒絕 SIGKILL（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen; clear_ps_pen_files

# ---- LS-118：--force-reload ----

# ⑬a 目前已一致＋安全，但 Pencil 端 tree_hash 與磁碟不符（renderer 停在磁碟更新前的舊快照）→ 清場重開——
#     驗證「不因已一致就早退」邏輯，且清場前後仍照既有安全判定把關、重開後才真正算成功。LS-180 起這條路徑
#     只在雜湊不符時走（相符不殺見 ⑮a），且結束主行程後必印「下一次 MCP 呼叫會自動重連」。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_safe; set_hash 'HASH:ffffffffffffffff'
set_state "PATH:${want}"
start_fake_pen
export PEN_STUB_OSASCRIPT_KILLS=1
out="$(run "$wt" --force-reload 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF -- '--force-reload' \
  && printf '%s' "$out" | grep -qF 'tree_hash 不一致' \
  && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" \
  && printf '%s' "$out" | grep -qF 'Pencil MCP：下一次 MCP 呼叫會自動重連' \
  && ! fake_pen_alive && [ "$(open_calls)" -eq 2 ] && [ "$(exec_calls)" -eq 1 ]; then
  ok '⑬a --force-reload：已一致但雜湊不符 → 清場重開，假行程真的被換掉，印「下一次 MCP 呼叫會自動重連」（LS-118／LS-180）'
else
  bad "⑬a 應 exit 0 且真的清場重開（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)，open 呼叫次數＝$(open_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OSASCRIPT_KILLS
clear_fake_pen

# ⑬b 目前已一致，雜湊不符，且目標自己的 renderer 有未落地變更——即使已經 active，--force-reload 仍不能為了保
#     新鮮度而默默丟掉真實變更，fail closed 拒絕清場。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_unsafe; set_hash 'HASH:ffffffffffffffff'
set_state "PATH:${want}"
start_fake_pen
out="$(run "$wt" --force-reload 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF -- '--force-reload' \
  && printf '%s' "$out" | grep -qF '不自動 quit' \
  && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok '⑬b --force-reload：目標自己有未落地變更 → 即使已一致仍拒絕清場（LS-118）'
else
  bad "⑬b 應 exit 1 且不清場（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ---- LS-118 R1（merge-review F1／F2）----

# ⑬c F1 正案例：--force-reload 且 pgrep 找不到 Pen 主行程（樣式不符／改名／pgrep 缺失，Pen 其實還在跑）
#     → 不能假裝清場過，fail closed exit 2（不像修前那樣印 ✓ 並 exit 0，但沒真的換 renderer）。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_safe; set_hash 'HASH:ffffffffffffffff'
set_state "PATH:${want}"
out="$(run "$wt" --force-reload 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '但找不到 Pen 主行程'; then
  ok '⑬c --force-reload：雜湊不符且 pgrep 找不到主行程 → fail closed exit 2，不假裝清場過（LS-118 R1 F1）'
else
  bad "⑬c 應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑬d F1 對照：預設模式（不帶 --force-reload）pgrep 找不到主行程時維持原行為——它的成功語意本來就只有
#     「路徑一致」，不含「保證全新 renderer」，跳過清場、直接重開即可視為成功。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt2_backup_safe
set_state "PATH:${want2}"
export PEN_STUB_OPEN_SUCCEED_AT=2
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '跳過清場步驟，直接嘗試重開' \
  && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" \
  && ! printf '%s' "$out" | grep -qF 'Pencil MCP：下一次 MCP 呼叫會自動重連'; then
  ok '⑬d 預設模式 pgrep 找不到主行程：跳過清場、直接重開，不受 --force-reload 新規則影響，沒殺行程就不印「下一次 MCP 呼叫會自動重連」（LS-118 R1 F1 對照）'
else
  bad "⑬d 應 exit 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT

# ⑬e F2 正案例：backup 是陳舊快取（mtime 早於落地檔）且落地檔對 git 全程 clean → 視為安全，強制清場重開
#     成功；訊息絕不能指示 pen-land.sh（會用舊快照覆蓋較新的落地檔）。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wtQ_backup_stale; wt_backup_safe
set_state "PATH:${wantQ}"
start_fake_pen
export PEN_STUB_OPEN_SUCCEED_AT=2 PEN_STUB_OSASCRIPT_KILLS=1
out="$(run "$wt" --force-reload 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF 'backup mtime 早於落地檔' \
  && printf '%s' "$out" | grep -qF '不要跑 pen-land.sh' \
  && ! printf '%s' "$out" | grep -qF '先跑：bash scripts/ops/pen-land.sh' \
  && ! fake_pen_alive; then
  ok '⑬e mtime 方向感知正案例：陳舊快取＋git-clean → 視為安全，強制清場重開，不指示 pen-land（LS-118 R1 F2）'
else
  bad "⑬e 應 exit 0 且不指示 pen-land（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT PEN_STUB_OSASCRIPT_KILLS
clear_fake_pen

# ⑬f F2 邊界：backup 陳舊（mtime 方向相同）但落地檔對 git 不 clean → 不視為安全，不清場，exit 1（防止
#     「落地檔本身也被直接改過內容」被誤放行，同 rule c 的理由）。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wtQ_backup_stale; wtQ_make_dirty
set_state "PATH:${wantQ}"
start_fake_pen
out="$(run "$wt" --force-reload 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '疑似陳舊快取' \
  && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok '⑬f mtime 方向感知邊界：backup 陳舊但落地檔對 git 不 clean → 不視為安全，不清場（LS-118 R1 F2 邊界）'
else
  bad "⑬f 應 exit 1 且不清場（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen
wtQ_reset_clean

# ---- ⑭b LS-176 對照：舊路徑「存在」且有未落地變更（wt2 的 backup 與磁碟檔結構不同）→ 仍照舊擋：不 quit、
#      不第二次 open、exit 1，且絕不印「視為已捨棄」（⑭a 的放行只能來自「磁碟上沒有這個檔」，不得擴大到
#      「檔在但無法判定」；mutation：check_root_safe 的 -e 改成 -d root、或把不存在與無法判定又混在一起 → 紅）----
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt2_backup_unsafe; wt_backup_safe
set_state "PATH:${want2}"
start_fake_pen
export PEN_STUB_OPEN_SUCCEED_AT=2
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '不自動 quit' && ! printf '%s' "$out" | grep -qF '視為已捨棄' \
  && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok '⑭b LS-176 對照：舊路徑存在且 dirty → 仍拒絕清場，exit 1，不印「視為已捨棄」'
else
  bad "⑭b 應 exit 1 且不清場（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)，open 呼叫次數＝$(open_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT
clear_fake_pen

# ---- ⑮ LS-180：--force-reload 先比 tree_hash、相符不殺；--kill 明示清場；預設模式不回讀雜湊 ----

# ⑮a 已一致＋Pencil 端雜湊＝磁碟 → exit 0、不 kill（假行程仍活）、只 open 一次、印「未清場」、不印「下一次 MCP 呼叫會自動重連」。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_safe; set_hash "HASH:${WT_HASH}"
set_state "PATH:${want}"
start_fake_pen
out="$(run "$wt" --force-reload 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "tree_hash=${WT_HASH} 與磁碟一致" \
  && printf '%s' "$out" | grep -qF '未清場' && ! printf '%s' "$out" | grep -qF 'Pencil MCP：下一次 MCP 呼叫會自動重連' \
  && fake_pen_alive && [ "$(open_calls)" -eq 1 ] && [ "$(exec_calls)" -eq 1 ]; then
  ok '⑮a --force-reload：已一致且 tree_hash 相符 → exit 0 不 kill、不重開、不印「下一次 MCP 呼叫會自動重連」（LS-180）'
else
  bad "⑮a 應 exit 0 且不 kill（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)，open 呼叫次數＝$(open_calls)，execute 次數＝$(exec_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ⑮b 已一致＋雜湊不符＋目標 dirty（真實未落地編輯）→ 不 kill、exit 1（不相符也不能為了新鮮度丟掉真編輯）。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_unsafe; set_hash 'HASH:0123456789abcdef'
set_state "PATH:${want}"
start_fake_pen
out="$(run "$wt" --force-reload 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF 'tree_hash 不一致' && printf '%s' "$out" | grep -qF '不自動 quit' \
  && ! printf '%s' "$out" | grep -qF 'Pencil MCP：下一次 MCP 呼叫會自動重連' && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok '⑮b --force-reload：雜湊不符但目標有未落地變更 → 不安全不 kill，exit 1，不印「下一次 MCP 呼叫會自動重連」（LS-180）'
else
  bad "⑮b 應 exit 1 且不 kill（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ⑮c 已一致但 Pencil 端雜湊讀不到（execute 中斷／無 SUMMARY-HASH）→ 不 kill、exit 3、stdout 印期望值與複算指引。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_safe; set_hash 'ERROR'
set_state "PATH:${want}"
start_fake_pen
out="$(run "$wt" --force-reload 2>&1)"; got=$?
if [ "$got" -eq 3 ] && printf '%s' "$out" | grep -qF "期望值 tree_hash=${WT_HASH}" \
  && printf '%s' "$out" | grep -qF 'SCAN_HASH_ONLY' && printf '%s' "$out" | grep -qF -- '--kill' \
  && ! printf '%s' "$out" | grep -qF 'Pencil MCP：下一次 MCP 呼叫會自動重連' \
  && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok '⑮c --force-reload：雜湊讀不到 → 不 kill、exit 3、印期望值與 agent 複算指引（LS-180）'
else
  bad "⑮c 應 exit 3 且不 kill（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ⑮d 雜湊回讀掛住 → PEN_OPEN_HASH_TIMEOUT 看門狗收工，仍是 exit 3、不 kill，整支腳本不卡死。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_safe; set_hash 'HANG'
set_state "PATH:${want}"
start_fake_pen
t0=$SECONDS
out="$(PEN_OPEN_HASH_TIMEOUT=1 run "$wt" --force-reload 2>&1)"; got=$?
elapsed=$((SECONDS - t0))
if [ "$got" -eq 3 ] && [ "$elapsed" -le 5 ] && fake_pen_alive; then
  ok "⑮d --force-reload：雜湊回讀掛住 → 看門狗 ${elapsed}s 內收工，exit 3 不 kill（LS-180）"
else
  bad "⑮d 應在數秒內 exit 3 且不 kill（實得 ${got}，耗時 ${elapsed}s，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ⑮e --kill：已一致且雜湊其實相符，仍不比對、直接安全判定＋清場重開，印「下一次 MCP 呼叫會自動重連」；execute 一次都不呼叫。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_safe; set_hash "HASH:${WT_HASH}"
set_state "PATH:${want}"
start_fake_pen
export PEN_STUB_OSASCRIPT_KILLS=1
out="$(run "$wt" --kill 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF -- '--kill' \
  && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" \
  && printf '%s' "$out" | grep -qF 'Pencil MCP：下一次 MCP 呼叫會自動重連' \
  && ! printf '%s' "$out" | grep -qF 'Pencil MCP 殘留' \
  && ! fake_pen_alive && [ "$(open_calls)" -eq 2 ] && [ "$(exec_calls)" -eq 0 ]; then
  ok '⑮e --kill：不比雜湊、一律清場重開、印「下一次 MCP 呼叫會自動重連」，execute 零次，無殘留 mcp-server 不印殘留行（LS-180／LS-308）'
else
  bad "⑮e 應 exit 0 且清場重開（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)，open 呼叫次數＝$(open_calls)，execute 次數＝$(exec_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OSASCRIPT_KILLS
clear_fake_pen

# ⑮e-2（LS-308 A3）：--kill 清場後有殘留 mcp-server（本 session 一支＋別 session 兩支）→ 印殘留數 2，只印不殺
#      （不呼叫 pgrep -f <mcp-server 樣式> 以外的任何行程操作；假 Pen 主行程真的被換掉但沒人動 mcp-server）。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_safe; set_hash "HASH:${WT_HASH}"
set_state "PATH:${want}"
start_fake_pen
export PEN_STUB_OSASCRIPT_KILLS=1
set_mcp_pids $'24097\n24098\n24099'
set_mcp_parent 24097 900 claude
set_mcp_parent 24098 1 launchd
set_mcp_parent 24099 500 codex
out="$(run "$wt" --kill 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" \
  && printf '%s' "$out" | grep -qF 'Pencil MCP 殘留：另有 2 支別 session 的 mcp-server（僅列出、不處理' \
  && ! fake_pen_alive; then
  ok '⑮e-2 --kill：殘留 2 支別 session 的 mcp-server → 印殘留數，只印不殺（LS-308 A3）'
else
  bad "⑮e-2 應印殘留數 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OSASCRIPT_KILLS
clear_fake_pen; clear_mcp_pids

# ⑮e-3（LS-308 A3）：預設模式（無旗標）自動清場也會結束 Pen 主行程，但殘留 mcp-server 列示只給 --kill；
#      即使當下有殘留也不印那行（A3 票文範圍限定 pen-open.sh --kill）。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt2_backup_safe; wt_backup_safe
set_state "PATH:${want2}"
start_fake_pen
export PEN_STUB_OPEN_SUCCEED_AT=2 PEN_STUB_OSASCRIPT_KILLS=1
set_mcp_pids 24097
set_mcp_parent 24097 1 launchd
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" \
  && ! printf '%s' "$out" | grep -qF 'Pencil MCP 殘留'; then
  ok '⑮e-3 預設模式（非 --kill）自動清場：即使有殘留 mcp-server 也不印殘留行（LS-308 A3 只限 --kill）'
else
  bad "⑮e-3 應 exit 0 且不印殘留行（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT PEN_STUB_OSASCRIPT_KILLS
clear_fake_pen; clear_mcp_pids

# ⑮f --kill 且目標 dirty → 仍 fail closed exit 1，不 kill（--kill 只是跳過雜湊比對，不跳過安全判定）。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_unsafe
set_state "PATH:${want}"
start_fake_pen
out="$(run "$wt" --kill 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '不自動 quit' && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok '⑮f --kill：目標有未落地變更 → 仍拒絕清場 exit 1（--kill 不跳過安全判定，LS-180）'
else
  bad "⑮f 應 exit 1 且不 kill（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ⑮g 預設模式（不帶旗標）已一致 → 照舊 exit 0，且 execute 零次（雜湊回讀只屬 --force-reload）。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; set_hash 'ERROR'
set_state "PATH:${want}"
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && [ "$(exec_calls)" -eq 0 ] && ! printf '%s' "$out" | grep -qF 'tree_hash'; then
  ok '⑮g 預設模式已一致 → exit 0、不回讀雜湊（execute 零次）（LS-180）'
else
  bad "⑮g 應 exit 0 且 execute 零次（實得 ${got}，execute 次數＝$(exec_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ⑮h 旗標互斥／未知旗標：--kill 與 --force-reload 同給、或拼錯 → 用法錯誤 exit 2。
out="$(run "$wt" --force-reload --kill 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '用法'; then ok '⑮h --force-reload 與 --kill 同給 → exit 2'; else bad "⑮h 應 exit 2（實得 ${got}）"; fi
out="$(run "$wt" --kil 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '用法'; then ok '⑮h 拼錯旗標 → exit 2'; else bad "⑮h 拼錯旗標應 exit 2（實得 ${got}）"; fi

# ⑮i 磁碟 .pen 壞 JSON → --force-reload 算不出磁碟雜湊 → exit 2 fail closed，不 kill、不回讀。
wtBad="${work}/wt-bad"; mkdir -p "${wtBad}/design"; printf '%s' '{not json' > "${wtBad}/design/littlesprout.pen"
wantBad="$(cd "${wtBad}/design" && pwd -P)/littlesprout.pen"
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; set_hash "HASH:${WT_HASH}"
set_state "PATH:${wantBad}"
start_fake_pen
out="$(run "$wtBad" --force-reload 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '算不出磁碟 tree_hash' && fake_pen_alive && [ "$(exec_calls)" -eq 0 ]; then
  ok '⑮i --force-reload：磁碟 .pen 壞掉算不出雜湊 → exit 2 fail closed，不 kill 不回讀（LS-180）'
else
  bad "⑮i 應 exit 2（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)，execute 次數＝$(exec_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ---- ㉔／㉕（LS-309）：整棵單次雜湊回讀失敗後的分段路徑——root 數量探測＋對半遞迴分段，各段 hash_part 依
#      mod 2^64 相加合併。用 $PEN_STUB_HASH_QUEUE（第 N 次 execute 呼叫對應第 N 行）精確控制「單次失敗 → 探測
#      root 數 → 分段各自成功／持續失敗」，不依賴 $PEN_STUB_HASH 的單一控制值。夾具 wtSeg 有 4 個頂層節點
#      （root 數量足以分兩段），WT_HASH_SEG 為其磁碟 tree_hash（design_tree_hash.py 算出），供合成 hash_part 組出
#      「相加後與磁碟一致」的正案例。
wtSeg="${work}/wt-seg"; mkdir -p "${wtSeg}/design"
printf '%s' '{"version":1,"children":[{"id":"s1","x":1,"children":[]},{"id":"s2","x":2,"children":[]},{"id":"s3","x":3,"children":[]},{"id":"s4","x":4,"children":[]}]}' > "${wtSeg}/design/littlesprout.pen"
wantSeg="$(cd "${wtSeg}/design" && pwd -P)/littlesprout.pen"
WT_HASH_SEG="$(python3 "${root}/scripts/gates/design_tree_hash.py" "$wantSeg")"

# ㉔ 整棵單次失敗 → root 數量探測成功（n=4）→ 對半兩段皆成功，hash_part 相加（0 + WT_HASH_SEG mod 2^64）＝WT_HASH_SEG
#    → 與磁碟一致，exit 0、不清場（走既有 LS-180「相符不殺」路徑，只是這次雜湊是分段合出來的）。
reset_open_tracking; clear_fake_pen; wt_backup_safe
{
  echo FAIL
  echo "ROOT-COUNT n=4"
  echo "SUMMARY-HASH-PART roots=[0,2) total_nodes=2 hash_part=0000000000000000"
  echo "SUMMARY-HASH-PART roots=[2,4) total_nodes=2 hash_part=${WT_HASH_SEG}"
} > "$PEN_STUB_HASH_QUEUE"
set_state "PATH:${wantSeg}"
start_fake_pen
out="$(run "$wtSeg" --force-reload 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "tree_hash=${WT_HASH_SEG} 與磁碟一致" \
  && printf '%s' "$out" | grep -qF '分段成功（2 段' \
  && fake_pen_alive && [ "$(exec_calls)" -eq 4 ]; then
  ok '㉔ 整棵單次失敗 → root 數量探測＋對半分兩段皆成功，hash_part 相加後與磁碟一致 → exit 0 不清場（LS-309）'
else
  bad "㉔ 應 exit 0 且分段合併成功（實得 ${got}，execute 次數＝$(exec_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ㉕ 整棵單次失敗 → root 數量探測成功 → 每一段（含遞迴再分半後的最小範圍）都持續失敗 → 最終放棄、不清場、
#    exit 3 印期望值交 agent 複算（與 ⑮c 同一組 exit 3 語意，只是這次是分段耗盡後才放棄，不是單次重試耗盡）。
reset_open_tracking; clear_fake_pen; wt_backup_safe
{
  echo FAIL
  echo "ROOT-COUNT n=4"
  echo FAIL
  echo FAIL
  echo FAIL
} > "$PEN_STUB_HASH_QUEUE"
set_state "PATH:${wantSeg}"
start_fake_pen
out="$(run "$wtSeg" --force-reload 2>&1)"; got=$?
if [ "$got" -eq 3 ] && printf '%s' "$out" | grep -qF "期望值 tree_hash=${WT_HASH_SEG}" \
  && printf '%s' "$out" | grep -qF '已無法再分段仍失敗，放棄' \
  && fake_pen_alive; then
  ok '㉕ 分段仍持續失敗（遞迴到最小範圍）→ 放棄，不清場、exit 3 印期望值（LS-309）'
else
  bad "㉕ 應 exit 3 且不清場（實得 ${got}，execute 次數＝$(exec_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen
rm -f "$PEN_STUB_HASH_QUEUE"

# ---- ⑯～⑳（LS-236）：`--restore` 子命令＋`--kill` 清場後自動比對還原主 checkout `design/littlesprout.pen`
#        （來源：LS-208 收尾事故，pen-open.sh <主 checkout> --kill 重開後 Pen 把記憶體中的票檔內容寫回主
#        checkout，主 checkout 變 dirty，巡檢才發現）----

# ⑯ --restore：主 checkout dirty → 自動用 git checkout -- 還原並印「Pen 寫回 → 已還原（+N/−M）」
mainCk_dirty
out16=$( cd "$mainCk" && bash "$script" --restore 2>&1 ); got16=$?
if [ "$got16" -eq 0 ] && printf '%s' "$out16" | grep -qF 'Pen 寫回 → 已還原' \
  && [ -z "$(git -C "$mainCk" status --porcelain -- design/littlesprout.pen)" ]; then
  ok '⑯ --restore：主 checkout dirty → 自動還原，還原後 git status 乾淨'
else
  bad "⑯ 應 exit 0 且已還原（實得 ${got16}）"; printf '%s\n' "$out16" | sed 's/^/    /' >&2
fi

# ⑰ --restore：主 checkout 已一致 → 印「一致，無需還原」，不動任何東西（對照 ⑯ 剛還原完之後再跑一次）
out17=$( cd "$mainCk" && bash "$script" --restore 2>&1 ); got17=$?
if [ "$got17" -eq 0 ] && printf '%s' "$out17" | grep -qF '一致，無需還原'; then
  ok '⑰ --restore：已一致 → 印「一致，無需還原」（不重複還原）'
else
  bad "⑰ 應印一致訊息（實得 exit ${got17}）"; printf '%s\n' "$out17" | sed 's/^/    /' >&2
fi

# ⑱ --restore：不在 git repo 內呼叫 → exit 2（找不到主 checkout）
out18=$( cd "$work" && bash "$script" --restore 2>&1 ); got18=$?
if [ "$got18" -eq 2 ]; then ok '⑱ --restore：不在 git repo 內 → exit 2'; else bad "⑱ 應 exit 2（實得 ${got18}）"; fi

# ⑲ --kill：清場重開後，主 checkout 被寫回（此處直接以「清場後仍 dirty」模擬 Pen 寫回的可觀察結果，
#    成因本身不可控——真正觸發 Pen 寫回需要真的 Pen app）→ 自動還原
reset_open_tracking; clear_fake_pen; clear_ps_pen_files
mainCk_dirty
set_state "PATH:${wantMain}"
start_fake_pen
export PEN_STUB_OSASCRIPT_KILLS=1
out19=$(run "$mainCk" --kill 2>&1); got19=$?
unset PEN_STUB_OSASCRIPT_KILLS
if [ "$got19" -eq 0 ] && printf '%s' "$out19" | grep -qF 'Pen 寫回 → 已還原' \
  && [ -z "$(git -C "$mainCk" status --porcelain -- design/littlesprout.pen)" ]; then
  ok '⑲ --kill：清場重開後自動還原被 Pen 寫回的主 checkout design/littlesprout.pen'
else
  bad "⑲ 應清場成功且自動還原（實得 exit ${got19}）"; printf '%s\n' "$out19" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ⑳ --kill：目標是 linked worktree（不是主 checkout）→ 清場照樣成功，但不比對／不還原它的 dirty .pen
#    （可能是合法的設計 WIP，LS-236 裁決：只動真正的主 checkout）
reset_open_tracking; clear_fake_pen; clear_ps_pen_files
mainCkWt_dirty
set_state "PATH:${wantMainWt}"
start_fake_pen
export PEN_STUB_OSASCRIPT_KILLS=1
out20=$(run "$mainCkWt" --kill 2>&1); got20=$?
unset PEN_STUB_OSASCRIPT_KILLS
if [ "$got20" -eq 0 ] && printf '%s' "$out20" | grep -qF 'linked worktree' \
  && [ -n "$(git -C "$mainCkWt" status --porcelain -- design/littlesprout.pen)" ]; then
  ok '⑳ --kill：linked worktree 的 dirty .pen 清場後保持原樣（不誤還原）'
else
  bad "⑳ 應清場成功但不還原、保持 dirty（實得 exit ${got20}）"; printf '%s\n' "$out20" | sed 's/^/    /' >&2
fi
clear_fake_pen
mainCkWt_reset_clean

# mk_mutant <mut_root_name> <sed 表達式>：把 pen-open.sh 依原本的相對深度（scripts/ops/）複製進
# $work/<mut_root_name>/ 並套用 sed 表達式，同時複製 pen-land.sh（check_root_safe() 用 script_root 相對
# 路徑找它）——直接把 mutant 丟在 $work 頂層（扁平檔案）會讓 `script_root=$(dirname .../../..)` 解到
# $work 的上兩層（系統暫存目錄），連 pen-land.sh 都找不到、`--kill` 清場流程本身就會提早失敗，而不是真的
# 走到我們要驗的那段邏輯——印出 mut_root 路徑供呼叫端組出 mutant script 路徑。
mk_mutant() {
  local mut_root="${work}/$1" sed_expr=$2
  mkdir -p "${mut_root}/scripts/ops/lib"
  sed "$sed_expr" "$script" > "${mut_root}/scripts/ops/pen-open.sh"
  cp "${root}/scripts/ops/pen-land.sh" "${mut_root}/scripts/ops/pen-land.sh"
  cp "${root}/scripts/ops/lib/pencil-mcp.sh" "${mut_root}/scripts/ops/lib/pencil-mcp.sh"
  mkdir -p "${mut_root}/scripts/gates"
  cp "${root}/scripts/gates/design_tree_hash.py" "${mut_root}/scripts/gates/design_tree_hash.py"
}

# ==== mutation A：拿掉 --kill 流程呼叫 restore_main_checkout 那行 → ⑲ 的綠樣本必須變回 dirty（不再還原）====
mk_mutant mutA-root '/\[ "\$kill_mode" -eq 1 \] && { restore_main_checkout "\$root" || restore_rc=\$?; }/d'
mutA="${work}/mutA-root/scripts/ops/pen-open.sh"
if grep -qF 'restore_main_checkout "$root"' "$mutA"; then
  bad "mutation A：拿掉呼叫失敗，負控本身無效"
else
  ok "mutation A：確認已拿掉 --kill 流程對 restore_main_checkout 的呼叫"
fi
mainCk_dirty
reset_open_tracking; clear_fake_pen; clear_ps_pen_files
set_state "PATH:${wantMain}"
start_fake_pen
export PEN_STUB_OSASCRIPT_KILLS=1
outmA=$(bash "$mutA" "$mainCk" --kill 2>&1); gotmA=$?
unset PEN_STUB_OSASCRIPT_KILLS
if [ "$gotmA" -eq 0 ] && [ -n "$(git -C "$mainCk" status --porcelain -- design/littlesprout.pen)" ]; then
  ok "mutation A：拿掉呼叫後 ⑲ 的綠樣本清場照樣成功但不再被還原（仍 dirty）——證明呼叫是這裡在還原"
else
  bad "mutation A 未如預期翻轉（實得 exit ${gotmA}）"; printf '%s\n' "$outmA" | sed 's/^/    /' >&2
fi
clear_fake_pen
mainCk_reset_clean

# ==== mutation B：拿掉「非主 checkout」排除判斷（改成恆假）→ ⑳ 的負樣本（linked worktree）必須被誤還原 ====
mk_mutant mutB-root 's/if \[ "\$gd" != "\$cgd" \]; then/if false; then/'
mutB="${work}/mutB-root/scripts/ops/pen-open.sh"
if grep -qF 'if false; then' "$mutB"; then
  ok "mutation B：確認已把「非主 checkout」判斷改成恆假"
else
  bad "mutation B：改判準失敗，負控本身無效"
fi
mainCkWt_dirty
reset_open_tracking; clear_fake_pen; clear_ps_pen_files
set_state "PATH:${wantMainWt}"
start_fake_pen
export PEN_STUB_OSASCRIPT_KILLS=1
outmB=$(bash "$mutB" "$mainCkWt" --kill 2>&1); gotmB=$?
unset PEN_STUB_OSASCRIPT_KILLS
if [ "$gotmB" -eq 0 ] && [ -z "$(git -C "$mainCkWt" status --porcelain -- design/littlesprout.pen)" ]; then
  ok "mutation B：拿掉排除判斷後，⑳ 的負樣本（linked worktree）被誤還原——證明該判斷是這裡在保護"
else
  bad "mutation B 未如預期翻轉（實得 exit ${gotmB}）"; printf '%s\n' "$outmB" | sed 's/^/    /' >&2
fi
clear_fake_pen
mainCkWt_reset_clean

# ---- ㉑（LS-236 R2，merge-review F2）：--restore 對 staged（`git add` 過但未 commit）的 .pen 污染也要
#        還原，不能只比對 index（裸 `git diff -- <path>`／`git checkout -- <path>` 都是跟 index 比、從
#        index 還原）——reviewer 重放：改掉 .pen 並 git add 之後，`patrol.sh` 那側（`git diff --name-only
#        HEAD` 看得到 staged 變更）會印「Pen 寫回」提示，但舊版 `--restore` 卻回報「已一致，無需還原」
#        且完全沒有動檔案，兩邊互相矛盾、無路可走。改用 HEAD 為基準後，staged 的污染內容也要被還原
#        （index 與 worktree 一起被 `git checkout HEAD --` 覆寫）----
mainCk_dirty
git -C "$mainCk" add design/littlesprout.pen
out21=$( cd "$mainCk" && bash "$script" --restore 2>&1 ); got21=$?
if [ "$got21" -eq 0 ] && printf '%s' "$out21" | grep -qF 'Pen 寫回 → 已還原' \
  && [ -z "$(git -C "$mainCk" status --porcelain -- design/littlesprout.pen)" ]; then
  ok '㉑ --restore：staged（git add 過）的污染 .pen 也會被還原，git status 乾淨'
else
  bad "㉑ 應 exit 0 且已還原（實得 ${got21}）"; printf '%s\n' "$out21" | sed 's/^/    /' >&2
fi
mainCk_reset_clean

# ---- ㉒（LS-236 R2，merge-review F3，PLAUSIBLE 重放）：還原後複驗——用一支「checkout 回報成功但其實
#        沒有真的動到檔案」的 mutant 模擬「還原之後內容又被寫回」的等價效果，驗證 restore_main_checkout()
#        會在複驗時發現「還原後仍與 HEAD 不同」，印 ⚠ 並回傳非 0（不是默默印「已還原」蓋過去）----
mut_noop_checkout="${work}/pen-open.checkout-noop.sh"
sed 's/env LS_ALLOW_MAIN_CHECKOUT_WRITE=1 git -C "\$root" checkout HEAD -- design\/littlesprout\.pen 2>\/dev\/null/true/' "$script" > "$mut_noop_checkout"
if grep -qF 'if ! true; then' "$mut_noop_checkout"; then
  ok '㉒ mutate：確認已把「還原」指令換成 no-op（模擬「回報成功但內容沒真的變」）'
else
  bad '㉒ mutate：替換失敗，負控本身無效'
fi
mainCk_dirty
out22=$( cd "$mainCk" && bash "$mut_noop_checkout" --restore 2>&1 ); got22=$?
if [ "$got22" -ne 0 ] && printf '%s' "$out22" | grep -qF '⚠ pen-open --restore：還原後複驗仍與 HEAD 不同' \
  && [ -n "$(git -C "$mainCk" status --porcelain -- design/littlesprout.pen)" ]; then
  ok '㉒ 還原後複驗發現仍不同 → 印 ⚠ 並回傳非 0，不假裝已還原（F3 PLAUSIBLE 重放）'
else
  bad "㉒ 應 exit 非 0 且印複驗失敗警告（實得 exit ${got22}）"; printf '%s\n' "$out22" | sed 's/^/    /' >&2
fi
mainCk_reset_clean

# ---- ㉓（LS-236 R2，merge-review F2 迴歸防線）：非 git 倉庫的 --kill 目標（既有 $wt 之類的純目錄
#        fixture）→ restore_main_checkout() 靜默跳過（return 0），不得讓整體 --kill 因此失敗
#        （回歸防線：R2 開發過程中曾經把「不是 git 倉庫」錯判成硬錯誤 return 2，導致 ⑮e 這類既有
#        非 git fixture 的 --kill 從 exit 0 退化成 exit 2）----
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_safe
set_state "PATH:${want}"
start_fake_pen
export PEN_STUB_OSASCRIPT_KILLS=1
out23=$(run "$wt" --kill 2>&1); got23=$?
unset PEN_STUB_OSASCRIPT_KILLS
if [ "$got23" -eq 0 ] && printf '%s' "$out23" | grep -qF '不是 git 倉庫，跳過'; then
  ok '㉓ --kill 目標不是 git 倉庫 → 靜默跳過還原比對，整體仍 exit 0'
else
  bad "㉓ 應 exit 0 且印跳過訊息（實得 exit ${got23}）"; printf '%s\n' "$out23" | sed 's/^/    /' >&2
fi
clear_fake_pen

if [ "$fail" -ne 0 ]; then
  echo "✗ pen-open-check 自測失敗" >&2
  exit 1
fi
echo "✓ pen-open 自測通過（${n} 組樣本）"
