#!/bin/bash
# pen-read.sh 的自測（LS-118）。pen-read.sh 本身只是 `pen-open.sh <root> --force-reload` 的薄封裝——完整的
# 清場矩陣（安全／不安全／殘留視窗／defect 1-3……）已在 pen-open.test.sh 驗過，這裡不重複，只驗證：
# (1) 用法錯誤照樣 exit 2；(2) 正確轉呼叫 pen-open.sh 並帶上 --force-reload（用「目前已一致但仍強制清場」
# 這個只有 --force-reload 才會走到的行為當作轉呼叫成功的證據）；(3) 目標自己有未落地變更時，如實回傳
# pen-open.sh 的拒絕（exit 1），不會為了讀稿而默默丟掉真實變更。
# 全程 stub `open`／`pen`／`pgrep`／`osascript`／`ps`，不碰真正的 Pen app 或 pen CLI session。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/pen-read.sh"
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
WT_SAFE='{"version":1,"children":[]}'
printf '%s' "$WT_SAFE" > "${wt}/design/littlesprout.pen"
want="$(cd "${wt}/design" && pwd -P)/littlesprout.pen"

export PEN_STUB_STATE="${work}/state"
export PEN_STUB_OPEN_LOG="${work}/open.log"
export PEN_STUB_OPEN_COUNT="${work}/open.count"
export PEN_STUB_PID_FILE="${work}/fake_pen.pid"
: > "$PEN_STUB_OPEN_LOG"

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

cat > "${bin}/pgrep" <<'STUB'
#!/bin/bash
[ -s "${PEN_STUB_PID_FILE:?}" ] && cat "${PEN_STUB_PID_FILE}"
exit 0
STUB
chmod +x "${bin}/pgrep"

cat > "${bin}/osascript" <<'STUB'
#!/bin/bash
if [ "${PEN_STUB_OSASCRIPT_KILLS:-0}" = 1 ] && [ -s "${PEN_STUB_PID_FILE:?}" ]; then
  kill -TERM "$(cat "${PEN_STUB_PID_FILE}")" 2>/dev/null
fi
exit 0
STUB
chmod +x "${bin}/osascript"

export PEN_STUB_PS_OUTPUT="${work}/ps_output"
: > "$PEN_STUB_PS_OUTPUT"
cat > "${bin}/ps" <<'STUB'
#!/bin/bash
[ -f "${PEN_STUB_PS_OUTPUT:?}" ] && cat "${PEN_STUB_PS_OUTPUT}"
exit 0
STUB
chmod +x "${bin}/ps"

# stub `pen`（同 pen-open.test.sh）：stdin 含 `execute(` 是 LS-180 的 tree_hash 回讀，依 $PEN_STUB_HASH（HASH:<hex>／其他＝
# 模擬 interrupted）；否則是 get_app_state，依 $PEN_STUB_STATE。
export PEN_STUB_HASH="${work}/hash"
cat > "${bin}/pen" <<'STUB'
#!/bin/bash
if [ "$1" != interactive ]; then exit 1; fi
input="$(cat)"
case "$input" in
  *execute\(*)
    hc="$(cat "${PEN_STUB_HASH:?}" 2>/dev/null || true)"
    case "$hc" in
      HASH:*) printf 'SUMMARY-HASH total_nodes=1 tree_hash=%s\n' "${hc#HASH:}" ;;
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
reset_open_tracking() { : > "$PEN_STUB_OPEN_LOG"; rm -f "$PEN_STUB_OPEN_COUNT"; unset PEN_STUB_OPEN_SUCCEED_AT; }
WT_HASH="$(python3 "${root}/scripts/gates/design_tree_hash.py" "$want")"
# 預設讓雜湊回讀「不相符」——既有案例驗的是清場路徑；LS-180 相符／讀不到兩案各自覆寫。
set_hash 'HASH:ffffffffffffffff'
start_fake_pen() { sleep 100 & echo $! > "$PEN_STUB_PID_FILE"; disown; }
fake_pen_alive() { kill -0 "$(cat "$PEN_STUB_PID_FILE" 2>/dev/null)" 2>/dev/null; }
clear_fake_pen() {
  [ -s "$PEN_STUB_PID_FILE" ] && kill -9 "$(cat "$PEN_STUB_PID_FILE")" 2>/dev/null
  rm -f "$PEN_STUB_PID_FILE"
}
wt_backup_safe() { printf '%s' "$WT_SAFE" > "${PEN_BACKUP_DIR}/$(printf '%s' "file://${want}" | shasum | awk '{print $1}')"; }
wt_backup_unsafe() { printf '%s' '{"version":1,"children":[{"id":"newnode","x":1,"children":[]}]}' > "${PEN_BACKUP_DIR}/$(printf '%s' "file://${want}" | shasum | awk '{print $1}')"; }

run() { bash "$script" "$@"; }

# ---- 用法錯誤 ----
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '用法'; then ok '無參數 → exit 2'; else bad "無參數應 exit 2（實得 ${got}）"; fi
out="$(run "$wt" extra 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '用法'; then ok '多參數 → exit 2'; else bad "多參數應 exit 2（實得 ${got}）"; fi

# ---- 正確轉呼叫 pen-open.sh --force-reload：目前已一致但 Pencil 端雜湊不符 → 強制清場重開（只有 --force-reload
#      才會回讀雜湊並走到這個行為，pen-open.sh 預設模式一致就早退——這就是「有沒有正確帶上 --force-reload」的證據）；
#      LS-180：殺了主行程必印「需重連」----
reset_open_tracking; clear_fake_pen; wt_backup_safe; set_hash 'HASH:ffffffffffffffff'
set_state "PATH:${want}"
start_fake_pen
export PEN_STUB_OSASCRIPT_KILLS=1
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF -- '--force-reload' \
  && printf '%s' "$out" | grep -qF 'tree_hash 不一致' \
  && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" \
  && printf '%s' "$out" | grep -qF 'Pencil MCP 需重連：請在 Claude Code 執行 /mcp 重連 pencil' \
  && ! fake_pen_alive && [ "$(open_calls)" -eq 2 ]; then
  ok 'pen-read.sh <root>：正確轉呼叫 pen-open.sh --force-reload，雜湊不符才強制清場重開並印「需重連」'
else
  bad "應 exit 0 且真的清場重開（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)，open 呼叫次數＝$(open_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OSASCRIPT_KILLS
clear_fake_pen

# ---- LS-180 正案例：已一致且 Pencil 端 tree_hash＝磁碟 → exit 0、不 kill、Pencil MCP 連線保留（VR／QA 讀稿的主路徑）----
reset_open_tracking; clear_fake_pen; wt_backup_safe; set_hash "HASH:${WT_HASH}"
set_state "PATH:${want}"
start_fake_pen
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "tree_hash=${WT_HASH} 與磁碟一致" \
  && ! printf '%s' "$out" | grep -qF 'Pencil MCP 需重連' && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok 'pen-read.sh <root>：已一致且雜湊相符 → exit 0 不 kill（LS-180）'
else
  bad "應 exit 0 且不 kill（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)，open 呼叫次數＝$(open_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ---- LS-180：Pencil 端雜湊讀不到 → 不 kill、exit 3、印期望值交 agent 複算 ----
reset_open_tracking; clear_fake_pen; wt_backup_safe; set_hash 'ERROR'
set_state "PATH:${want}"
start_fake_pen
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 3 ] && printf '%s' "$out" | grep -qF "期望值 tree_hash=${WT_HASH}" && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok 'pen-read.sh <root>：雜湊讀不到 → exit 3 不 kill、印期望值（LS-180）'
else
  bad "應 exit 3 且不 kill（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ---- 目標自己有未落地變更（雜湊也不符）：如實回傳 pen-open.sh 的拒絕（exit 1），不會為了讀稿丟真實變更 ----
reset_open_tracking; clear_fake_pen; wt_backup_unsafe; set_hash 'HASH:ffffffffffffffff'
set_state "PATH:${want}"
start_fake_pen
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '不自動 quit' && fake_pen_alive; then
  ok 'pen-read.sh <root>：目標有未落地變更時如實回傳拒絕，不清場'
else
  bad "應 exit 1 且不清場（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ---- LS-118 R1（merge-review F1）：pgrep 找不到 Pen 主行程時不能假裝清場過，exit 2 ----
reset_open_tracking; clear_fake_pen; wt_backup_safe; set_hash 'HASH:ffffffffffffffff'
set_state "PATH:${want}"
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '但找不到 Pen 主行程'; then
  ok 'pen-read.sh <root>：雜湊不符且 pgrep 找不到主行程 → fail closed exit 2（LS-118 R1 F1）'
else
  bad "應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# ---- LS-118 R1（merge-review F2）：backup 是陳舊快取（mtime 早於落地檔）且落地檔 git-clean → 視為安全，
#      強制清場重開成功，訊息絕不指示 pen-land.sh（會用舊快照覆蓋較新的落地檔）----
wtQ="${work}/wtQ"
mkdir -p "${wtQ}/design"
printf '%s' '{"version":1,"fileToken":"tokQ","variables":{},"themes":{},"children":[{"id":"q1","x":1,"children":[]},{"id":"q2","x":2,"children":[]}]}' > "${wtQ}/design/littlesprout.pen"
( cd "$wtQ" && git init -q && git add -A && git -c user.email=test@example.com -c user.name=test commit -q -m init ) >/dev/null 2>&1
wantQ="$(cd "${wtQ}/design" && pwd -P)/littlesprout.pen"
shaQ="$(printf '%s' "file://${wantQ}" | shasum | awk '{print $1}')"
printf '%s' '{"version":1,"fileToken":"tokQ","variables":{},"themes":{},"children":[{"id":"q1","x":1,"children":[]}]}' > "${PEN_BACKUP_DIR}/${shaQ}"
touch -t 202501010000 "${PEN_BACKUP_DIR}/${shaQ}"
touch "${wtQ}/design/littlesprout.pen"

reset_open_tracking; clear_fake_pen; wt_backup_safe
set_state "PATH:${wantQ}"
start_fake_pen
export PEN_STUB_OPEN_SUCCEED_AT=2 PEN_STUB_OSASCRIPT_KILLS=1
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF 'backup mtime 早於落地檔' \
  && printf '%s' "$out" | grep -qF '不要跑 pen-land.sh' \
  && ! printf '%s' "$out" | grep -qF '先跑：bash scripts/ops/pen-land.sh' \
  && ! fake_pen_alive; then
  ok 'pen-read.sh <root>：陳舊快取＋git-clean → 視為安全，強制清場重開，不指示 pen-land（LS-118 R1 F2）'
else
  bad "應 exit 0 且不指示 pen-land（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT PEN_STUB_OSASCRIPT_KILLS
clear_fake_pen

# ---- LS-176（LS-96 池項 56eeaee0）：Pen 目前是已被 cleanup-merged.sh 移除的 worktree 路徑（磁碟上沒有那個檔）
#      → pen-read.sh 視為已捨棄、清場後成功切到目標（LS-176 之前回「不存在→無法確認安全」拒絕，QA／VR 讀稿
#      的新鮮度保證失效）----
gone="${work}/wt-gone/design/littlesprout.pen"
reset_open_tracking; clear_fake_pen; wt_backup_safe
set_state "PATH:${gone}"
start_fake_pen
export PEN_STUB_OPEN_SUCCEED_AT=2 PEN_STUB_OSASCRIPT_KILLS=1
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "舊路徑不存在，視為已捨棄：${gone}" \
  && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" && ! fake_pen_alive; then
  ok 'pen-read.sh <root>：Pen 記得的舊 worktree 路徑已不存在 → 視為已捨棄，清場切檔成功（LS-176）'
else
  bad "應 exit 0 且清場切檔成功（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT PEN_STUB_OSASCRIPT_KILLS
clear_fake_pen

# ---- LS-176 對照：Pen 目前是「存在且有未落地變更」的別的 worktree（wt2 backup 多一個節點）→ 仍如實拒絕清場、
#      不印「視為已捨棄」----
wt2="${work}/wt2"; mkdir -p "${wt2}/design"
printf '%s' '{"version":1,"fileToken":"tok2","variables":{},"themes":{},"children":[{"id":"m1","x":1,"children":[]}]}' > "${wt2}/design/littlesprout.pen"
want2="$(cd "${wt2}/design" && pwd -P)/littlesprout.pen"
printf '%s' '{"version":1,"fileToken":"tok2","variables":{},"themes":{},"children":[{"id":"m1","x":1,"children":[{"id":"m2","y":9,"children":[]}]}]}' > "${PEN_BACKUP_DIR}/$(printf '%s' "file://${want2}" | shasum | awk '{print $1}')"
reset_open_tracking; clear_fake_pen; wt_backup_safe
set_state "PATH:${want2}"
start_fake_pen
export PEN_STUB_OPEN_SUCCEED_AT=2
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF '不自動 quit' && ! printf '%s' "$out" | grep -qF '視為已捨棄' && fake_pen_alive; then
  ok 'pen-read.sh <root>：舊路徑存在且有未落地變更 → 仍如實拒絕清場（LS-176 對照）'
else
  bad "應 exit 1 且不清場（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OPEN_SUCCEED_AT
clear_fake_pen

if [ "$fail" -ne 0 ]; then
  echo "✗ pen-read-check 自測失敗" >&2
  exit 1
fi
echo "✓ pen-read 自測通過（${n} 組樣本）"
