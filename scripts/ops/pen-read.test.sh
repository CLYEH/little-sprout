#!/bin/bash
# pen-read.sh 的自測（LS-118）。pen-read.sh 本身只是 `pen-open.sh <root> --force-reload` 的薄封裝——完整的
# 清場矩陣（安全／不安全／殘留視窗／defect 1-3……）已在 pen-open.test.sh 驗過，這裡不重複，只驗證：
# (1) 用法錯誤照樣 exit 2；(2) 正確轉呼叫 pen-open.sh 並帶上 --force-reload（用「目前已一致但仍強制清場」
# 這個只有 --force-reload 才會走到的行為當作轉呼叫成功的證據）；(3) 目標自己有未落地變更時，如實回傳
# pen-open.sh 的拒絕（exit 1），不會為了讀稿而默默丟掉真實變更。
# 全程 stub `open`／`pen`／`pgrep`／`osascript`／`ps`，不碰真正的 Pen app 或 pen CLI session。
# LS-377 加：--help／位元組預算分段（超過預算的假節點夾具：直接分段、不先送整份、單段 interrupted 對半重切、重切上限）／
# 統計 log（前景／背景、interrupted 次數、票號推導）＋三支 mutation（拿掉預算判斷／拿掉重切上限／拿掉 interrupted 計數）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/pen-read.sh"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
# LS-377：pen-read.sh 會依 cwd 的 git toplevel 寫統計 log——自測一律在暫存目錄（非 git repo）跑，不污染真正 worktree 的 .claude/evidence
cd "$work" || exit 2
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
# LS-377：pen-read.sh 查前景 app（「… whose frontmost is true」）——印 $PEN_STUB_FRONTMOST（預設 Terminal），不觸發下面的 quit 模擬
case "$*" in *"frontmost is true"*) printf '%s\n' "${PEN_STUB_FRONTMOST:-Terminal}"; exit 0 ;; esac
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
    # LS-377：PEN_STUB_RANGE_MODE 設了就交給依 SCAN_HASH_ROOTS 算真 hash_part 的 python 假身（見下方夾具）
    if [ -n "${PEN_STUB_RANGE_MODE:-}" ]; then exec python3 "${PEN_STUB_RANGE_PY:?}" "$input"; fi
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

# LS-398：pen-read.sh 開頭會查 `patrol-linear.sh --inflight lane:design`——自測一律用假身（PEN_READ_PATROL_LINEAR_SH），
# 不碰真 Linear。假身依 $INFLIGHT_RC／$INFLIGHT_OUT 兩個檔回 exit code／stdout；預設「查過、無在飛設計票」
# （rc 0、空輸出），既有各案照舊走 pen-open.sh。
export INFLIGHT_RC="${work}/inflight.rc" INFLIGHT_OUT="${work}/inflight.out" INFLIGHT_LOG="${work}/inflight.log"
cat > "${work}/fake-patrol-linear.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${INFLIGHT_LOG:?}"
cat "${INFLIGHT_OUT:?}" 2>/dev/null
exit "$(cat "${INFLIGHT_RC:?}" 2>/dev/null || echo 0)"
STUB
export PEN_READ_PATROL_LINEAR_SH="${work}/fake-patrol-linear.sh"
set_inflight() { printf '%s' "$1" > "$INFLIGHT_RC"; printf '%s' "$2" > "$INFLIGHT_OUT"; }
set_inflight 0 ''

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
#      LS-180：殺了主行程必印「下一次 MCP 呼叫會自動重連」----
reset_open_tracking; clear_fake_pen; wt_backup_safe; set_hash 'HASH:ffffffffffffffff'
set_state "PATH:${want}"
start_fake_pen
export PEN_STUB_OSASCRIPT_KILLS=1
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF -- '--force-reload' \
  && printf '%s' "$out" | grep -qF 'tree_hash 不一致' \
  && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" \
  && printf '%s' "$out" | grep -qF 'Pencil MCP：下一次 MCP 呼叫會自動重連' \
  && ! fake_pen_alive && [ "$(open_calls)" -eq 2 ]; then
  ok 'pen-read.sh <root>：正確轉呼叫 pen-open.sh --force-reload，雜湊不符才強制清場重開並印「下一次 MCP 呼叫會自動重連」'
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
  && ! printf '%s' "$out" | grep -qF 'Pencil MCP：下一次 MCP 呼叫會自動重連' && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
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

# ---- LS-398：設計票在飛時拒跑（qa 在 qa-test 跑 pen-read ＝把 Pen active 載成 qa-test，LS-349 事故根因）----
# 設計票自己的 worktree 路徑形狀：<repo>/.claude/worktrees/LS-<n>
dwt="${work}/repo/.claude/worktrees/LS-403"; mkdir -p "${dwt}/design"
printf '%s' "$WT_SAFE" > "${dwt}/design/littlesprout.pen"
dwant="$(cd "${dwt}/design" && pwd -P)/littlesprout.pen"
DWT_HASH="$(python3 "${root}/scripts/gates/design_tree_hash.py" "$dwant")"

# (1) 在飛設計票 LS-403、呼叫端目標是別的 root（qa-test 之類）→ exit 2、印票文那句、不呼叫 pen-open（無 open／不殺行程）
reset_open_tracking; clear_fake_pen; wt_backup_safe; set_hash "HASH:${WT_HASH}"
set_state "PATH:${want}"; start_fake_pen
set_inflight 0 'LS-403'
: > "$INFLIGHT_LOG"
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '⚠ 設計票 LS-403 在飛，pen-read 會切走 Pen active 檔，拒跑；對稿改用 visual-reviewer 匯出的 PNG' \
  && grep -qF -- '--inflight lane:design' "$INFLIGHT_LOG" && [ "$(open_calls)" -eq 0 ] && fake_pen_alive; then
  ok 'pen-read.sh：設計票在飛且目標不是該票 worktree → exit 2 拒跑、不動 Pen（LS-398）'
else
  bad "在飛設計票應 exit 2 拒跑且不動 Pen（實得 ${got}，open 次數＝$(open_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# (2) 在飛設計票 LS-403、目標就是該票自己的 worktree → 照跑（VR／ui-designer 讀自己的稿；雜湊相符 exit 0）
reset_open_tracking; clear_fake_pen; wt_backup_safe; set_hash "HASH:${DWT_HASH}"
set_state "PATH:${dwant}"; start_fake_pen
set_inflight 0 'LS-403'
out="$(run "$dwt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "tree_hash=${DWT_HASH} 與磁碟一致" && ! printf '%s' "$out" | grep -qF '拒跑'; then
  ok 'pen-read.sh：設計票在飛但目標就是該票 worktree → 照跑 exit 0（LS-398）'
else
  bad "目標為在飛設計票自己的 worktree 應照跑 exit 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# (3) 多張在飛（LS-388、LS-403）、目標是其中之一（LS-403）→ 照跑
reset_open_tracking; clear_fake_pen; wt_backup_safe; set_hash "HASH:${DWT_HASH}"
set_state "PATH:${dwant}"; start_fake_pen
set_inflight 0 $'LS-388\nLS-403'
out="$(run "$dwt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! printf '%s' "$out" | grep -qF '拒跑'; then
  ok 'pen-read.sh：多張設計票在飛、目標是其中一張自己的 worktree → 照跑（LS-398）'
else
  bad "多張在飛且目標為其中一張應照跑 exit 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# (4) 票號前綴不算數：在飛 LS-40、目標是 .../LS-403 → 拒跑（不能因為字串前綴相同放行別票）
reset_open_tracking; clear_fake_pen; wt_backup_safe; set_hash "HASH:${DWT_HASH}"
set_state "PATH:${dwant}"; start_fake_pen
set_inflight 0 'LS-40'
out="$(run "$dwt" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '設計票 LS-40 在飛' && [ "$(open_calls)" -eq 0 ]; then
  ok 'pen-read.sh：在飛 LS-40、目標是 LS-403 worktree → 仍拒跑（票號需完整比對，LS-398）'
else
  bad "在飛 LS-40 不應放行 LS-403 目標（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# (5) 查不到（缺 key 的 exit 3）→ fail-open 照跑、stderr 有提示
reset_open_tracking; clear_fake_pen; wt_backup_safe; set_hash "HASH:${WT_HASH}"
set_state "PATH:${want}"; start_fake_pen
set_inflight 3 ''
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '查不到在飛設計票' && printf '%s' "$out" | grep -qF "tree_hash=${WT_HASH} 與磁碟一致"; then
  ok 'pen-read.sh：Linear 查不到（exit 3）→ fail-open 照跑並印提示（LS-398）'
else
  bad "查不到（exit 3）應照跑 exit 0 並印提示（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# (6) 查詢失敗（exit 1，即使 stdout 有東西也不採信）→ fail-open 照跑、有提示
reset_open_tracking; clear_fake_pen; wt_backup_safe; set_hash "HASH:${WT_HASH}"
set_state "PATH:${want}"; start_fake_pen
set_inflight 1 'LS-403'
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '查不到在飛設計票' && ! printf '%s' "$out" | grep -qF '拒跑'; then
  ok 'pen-read.sh：Linear 查詢失敗（exit 1）→ fail-open 照跑並印提示（LS-398）'
else
  bad "查詢失敗（exit 1）應照跑 exit 0 並印提示（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen
set_inflight 0 ''

# ==== LS-377：--help／位元組預算分段／統計 log ====
# --help：exit 0，說明含「open -a Pen」與 exit code 語意
out="$(run --help 2>&1)"; got=$?
if [ "$got" -eq 0 ] && grep -qF 'open -a Pen' <<<"$out" && grep -qF 'Exit code' <<<"$out" \
  && grep -qF '3  路徑一致但 Pencil 端雜湊讀不到' <<<"$out"; then
  ok 'pen-read.sh --help：exit 0，含「open -a Pen」前景提示與 exit code 語意（LS-377）'
else
  bad "--help 應 exit 0 並含前景提示與 exit code 語意（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi

# 夾具：8 個頂層節點、每個 ~1.1 KB（假節點：name 塞 1000 字元）＝磁碟頂層 JSON ~8.9 KB。
# pen 假身（range mode）：整份（無 SCAN_HASH_ROOTS）一律 interrupted、root 數量探測回 n=8、SCAN_HASH_ROOTS=[lo,hi) 且
# 跨度 ≤ $PEN_STUB_MAX_SPAN 才回「真」hash_part（用 design_tree_hash.py 的 node_line／fnv1a64 對磁碟檔算，各段相加＝磁碟 tree_hash），
# 跨度更大就 interrupted——模擬「大稿一次走訪太重」；每次呼叫把「whole」或「lo,hi」追加到 $PEN_STUB_RANGE_LOG。
wtBig="${work}/wt-big"; mkdir -p "${wtBig}/design"
python3 - "${wtBig}/design/littlesprout.pen" <<'PY'
import json, sys
kids = [{"id": "b%d" % i, "type": "frame", "name": ("節點%d-" % i) + "x" * 1000, "x": i, "children": [{"id": "b%dc" % i, "type": "text", "x": 1}]} for i in range(8)]
json.dump({"version": 1, "children": kids}, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PY
wantBig="$(cd "${wtBig}/design" && pwd -P)/littlesprout.pen"
BIG_HASH="$(python3 "${root}/scripts/gates/design_tree_hash.py" "$wantBig")"
export PEN_STUB_RANGE_PY="${work}/range_stub.py" PEN_STUB_RANGE_LOG="${work}/range.log" PEN_STUB_RANGE_FILE="$wantBig"
cat > "$PEN_STUB_RANGE_PY" <<PY
import json, os, re, sys
sys.path.insert(0, "${root}/scripts/gates")
import design_tree_hash as h
inp = sys.argv[1]
log = open(os.environ["PEN_STUB_RANGE_LOG"], "a")
doc = json.load(open(os.environ["PEN_STUB_RANGE_FILE"], encoding="utf-8"))
kids = doc["children"]
if "SCAN_HASH_ROOT_COUNT_ONLY = true" in inp:
    log.write("count\n")
    if os.environ.get("PEN_STUB_COUNT_FAIL"):
        print("Error: InternalError: interrupted"); sys.exit(0)
    print("ROOT-COUNT n=%d" % len(kids)); sys.exit(0)
m = re.search(r"SCAN_HASH_ROOTS = \[(\d+), (\d+)\]", inp)
if not m:
    log.write("whole\n"); print("Error: InternalError: interrupted"); sys.exit(0)
lo, hi = int(m.group(1)), int(m.group(2))
log.write("%d,%d\n" % (lo, hi))
if min(hi, len(kids)) - lo > int(os.environ.get("PEN_STUB_MAX_SPAN", "999")):
    print("Error: InternalError: interrupted"); sys.exit(0)
total = 0; count = 0
for i in range(lo, min(hi, len(kids))):
    stack = [(kids[i], "", i)]
    while stack:
        n, pid, idx = stack.pop()
        total = (total + h.fnv1a64(h.node_line(n, pid, idx).encode("utf-8"))) & h.MASK64
        count += 1
        for j, c in enumerate(n.get("children") or []):
            stack.append((c, n.get("id") or "", j))
print("SUMMARY-HASH-PART roots=[%d,%d) total_nodes=%d hash_part=%016x" % (lo, hi, count, total))
PY
export PEN_STUB_RANGE_MODE=1
range_log_reset() { : > "$PEN_STUB_RANGE_LOG"; }
big_case_setup() { reset_open_tracking; clear_fake_pen; wt_backup_safe; range_log_reset; set_state "PATH:${wantBig}"; start_fake_pen; }

# 統計 log 要落在「cwd 的 git toplevel」下：票 worktree 形狀的 cwd（LS-999，票號從目錄名推）＋一個非票目錄的 cwd（要 --ticket）
tix_repo="${work}/LS-999"; mkdir -p "$tix_repo"; ( cd "$tix_repo" && git init -q ) >/dev/null 2>&1
plain_repo="${work}/plainrepo"; mkdir -p "$plain_repo"; ( cd "$plain_repo" && git init -q ) >/dev/null 2>&1
stats_log() { cat "${1}/.claude/evidence/${2}/pen-read-stats.log" 2>/dev/null; }

# (1) 超過預算（--budget-bytes 3000，頂層總和 ~8.9 KB）→ 先問一次 Pen 端頂層節點數（count，R2 B1），相同才直接依預算分 4 段
#     （每段 2 節點，最後一段上界開放）、不先送整份；
#     合併後 tree_hash 與磁碟一致 → exit 0；統計 log（票號從 cwd 推）記 mode=planned segments=4 interrupted=0、Terminal 在前景
big_case_setup
out="$(cd "$tix_repo" && run --budget-bytes 3000 "$wtBig" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && grep -qF "tree_hash=${BIG_HASH} 與磁碟一致" <<<"$out" && grep -qF '分段成功（4 段' <<<"$out" \
  && [ "$(cat "$PEN_STUB_RANGE_LOG")" = $'count\n0,2\n2,4\n4,6\n6,2147483647' ] \
  && grep -qF 'rc=0 pen_frontmost=no frontmost=Terminal interrupted=0 mode=planned segments=4' <<<"$(stats_log "$tix_repo" LS-999)"; then
  ok 'pen-read.sh：頂層 JSON 超過位元組預算 → 先 count 再直接分 4 段（不先送整份、末段上界開放），合併後 exit 0；統計 log 記 planned／4 段／背景（LS-377）'
else
  bad "超過預算應直接分 4 段並 exit 0（實得 ${got}；execute 序＝$(tr '\n' ' ' < "$PEN_STUB_RANGE_LOG")；log＝$(stats_log "$tix_repo" LS-999 | tail -1)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# (2) 單段 interrupted（假身：跨度 >1 就 interrupted）→ 每個預算段對半重切成兩個單節點段各自成功；interrupted 共 4 次；
#     非票目錄 cwd 用 --ticket LS-998；Pen 在前景（PEN_STUB_FRONTMOST=Pen）→ pen_frontmost=yes、不印背景提示
big_case_setup
out="$(cd "$plain_repo" && PEN_STUB_MAX_SPAN=1 PEN_STUB_FRONTMOST=Pen run --ticket LS-998 --budget-bytes 3000 "$wtBig" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && grep -qF "tree_hash=${BIG_HASH} 與磁碟一致" <<<"$out" && grep -qF '分段成功（8 段' <<<"$out" \
  && ! grep -qF 'Pen 不在前景' <<<"$out" \
  && grep -qF 'pen_frontmost=yes frontmost=Pen interrupted=4 mode=planned segments=8' <<<"$(stats_log "$plain_repo" LS-998)"; then
  ok 'pen-read.sh：單段 interrupted 自動對半重切後合併成功；統計 log 記 interrupted=4／前景 Pen（LS-377）'
else
  bad "單段 interrupted 應對半重切成功（實得 ${got}；log＝$(stats_log "$plain_repo" LS-998 | tail -1)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# (3) 重切上限：所有段都 interrupted（MAX_SPAN=0）、PEN_OPEN_HASH_MAX_HALVINGS=1、預算 5000（2 段各 4 節點）→ 第一段對半一次
#     後仍失敗就放棄，exit 3 印期望值，不清場；統計 log 記 rc=3
big_case_setup
out="$(cd "$tix_repo" && PEN_STUB_MAX_SPAN=0 PEN_OPEN_HASH_MAX_HALVINGS=1 run --budget-bytes 5000 "$wtBig" 2>&1)"; got=$?
if [ "$got" -eq 3 ] && grep -qF "期望值 tree_hash=${BIG_HASH}" <<<"$out" && grep -qF '已對半重切 1 次仍失敗，放棄' <<<"$out" \
  && fake_pen_alive && grep -qF 'rc=3 ' <<<"$(stats_log "$tix_repo" LS-999 | tail -1)"; then
  ok 'pen-read.sh：對半重切達上限仍 interrupted → 放棄、exit 3 印期望值、不 kill，統計 log 記 rc=3（LS-377）'
else
  bad "重切達上限應 exit 3 放棄（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# (6) merge-review R1 B1：Pen 端比磁碟多一個尾端頂層節點（設計師在 Pen 新增板尚未落地／磁碟被回退而 renderer 停在舊快照）——
#     分段路徑必須判「不一致」走清場，不得因為前 N 個頂層節點相同而印「與磁碟一致」；舊路徑（--budget-bytes 0）同案也判不一致
rend="${work}/renderer.pen"
python3 - "$wantBig" "$rend" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
doc["children"].append({"id": "NEWBOARD", "type": "frame", "name": "renderer-only board", "x": 99, "children": []})
json.dump(doc, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PY
extra_case() {  # $1＝預算；結果放 $extra_out／$extra_rc
  big_case_setup
  export PEN_STUB_OSASCRIPT_KILLS=1
  extra_out="$(cd "$tix_repo" && PEN_STUB_RANGE_FILE="$rend" run --budget-bytes "$1" "$wtBig" 2>&1)"; extra_rc=$?
  unset PEN_STUB_OSASCRIPT_KILLS
}
extra_case 3000
if [ "$extra_rc" -eq 0 ] && grep -qF 'tree_hash 不一致' <<<"$extra_out" && grep -qF 'roots-mismatch(Pencil=9,disk=8)' <<<"$extra_out" \
  && ! grep -qF '與磁碟一致' <<<"$extra_out" && [ "$(cat "$PEN_STUB_RANGE_LOG")" = count ] && ! fake_pen_alive; then
  ok 'pen-read.sh：Pen 端多一個尾端頂層節點 → 分段路徑先 count 發現 9≠8、判不一致並走清場，不印「與磁碟一致」，不送任何分段回讀（LS-377 R2 B1）'
else
  bad "Pen 端多尾端節點應判不一致（實得 ${extra_rc}；execute 序＝$(tr '\n' ' ' < "$PEN_STUB_RANGE_LOG")）"; printf '%s\n' "$extra_out" | sed 's/^/    /' >&2
fi
clear_fake_pen
extra_case 0
if grep -qF 'tree_hash 不一致' <<<"$extra_out" && ! grep -qF '與磁碟一致' <<<"$extra_out"; then
  ok 'pen-read.sh：同案 --budget-bytes 0（LS-309 舊路徑）也判不一致——B1 修法沒有改變舊路徑語意（LS-377 R2）'
else
  bad "舊路徑同案應判不一致（實得 ${extra_rc}）"; printf '%s\n' "$extra_out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# (7) count 探測全數失敗（Pen 端 execute 不回）→ 無法驗證，不清場、exit 3 印期望值（不猜）
big_case_setup
out="$(cd "$tix_repo" && PEN_STUB_COUNT_FAIL=1 run --budget-bytes 3000 "$wtBig" 2>&1)"; got=$?
if [ "$got" -eq 3 ] && grep -qF '頂層節點數探測失敗' <<<"$out" && grep -qF "期望值 tree_hash=${BIG_HASH}" <<<"$out" && fake_pen_alive; then
  ok 'pen-read.sh：頂層節點數探測失敗 → 不分段、不清場、exit 3 印期望值（LS-377 R2 B1）'
else
  bad "探測失敗應 exit 3（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# (4) 預算停用（--budget-bytes 0）→ 維持舊路徑：先整份（interrupted）→ root 數量探測 → 對半兩段；不走預算分段
big_case_setup
out="$(cd "$tix_repo" && run --budget-bytes 0 "$wtBig" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && grep -qF '整份單次回讀失敗，改分段（LS-309）' <<<"$out" \
  && [ "$(cat "$PEN_STUB_RANGE_LOG")" = $'whole\ncount\n0,4\n4,8' ] && grep -qF 'mode=halved segments=2' <<<"$(stats_log "$tix_repo" LS-999 | tail -1)"; then
  ok 'pen-read.sh：--budget-bytes 0 → 舊路徑（整份→探測→對半，LS-309）不受影響（LS-377）'
else
  bad "預算 0 應走舊路徑（實得 ${got}；execute 序＝$(tr '\n' ' ' < "$PEN_STUB_RANGE_LOG")）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# (5) 推不出票號（cwd 是非票 git 目錄、沒給 --ticket）→ 不寫 log、stderr 說明，但照跑 exit 0
big_case_setup
rm -rf "${plain_repo}/.claude"
out="$(cd "$plain_repo" && run --budget-bytes 3000 "$wtBig" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && grep -qF '推不出票號' <<<"$out" && [ ! -d "${plain_repo}/.claude/evidence" ]; then
  ok 'pen-read.sh：推不出票號又沒 --ticket → 不寫統計 log、stderr 說明、照跑（LS-377）'
else
  bad "推不出票號應略過 log 並照跑（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
clear_fake_pen

# ---- mutation（LS-377）：改 pen-open.sh 的副本，用同一組夾具重跑，確認上面的斷言真的在保護該邏輯 ----
mk_mutant() {
  local mut_root="${work}/$1" sed_expr=$2
  mkdir -p "${mut_root}/scripts/ops/lib" "${mut_root}/scripts/gates" "${mut_root}/scripts/design"
  sed "$sed_expr" "${root}/scripts/ops/pen-open.sh" > "${mut_root}/scripts/ops/pen-open.sh"
  cp "${root}/scripts/ops/pen-read.sh" "${root}/scripts/ops/pen-land.sh" "${mut_root}/scripts/ops/"
  cp "${root}/scripts/ops/lib/pencil-mcp.sh" "${mut_root}/scripts/ops/lib/"
  cp "${root}/scripts/gates/design_tree_hash.py" "${mut_root}/scripts/gates/"
  cp "${root}/scripts/design/overflow-scan.js" "${mut_root}/scripts/design/"
}

# mutation A：拿掉預算判斷（plan_hash_segments 一律回空＝永遠走舊路徑先送整份）→ 情境 (1) 的「不先送整份」斷言必須紅
mk_mutant mutA-root 's/^  \[ "\$HASH_SEGMENT_BYTES" -gt 0 \] || return 0$/  return 0/'
if [ "$(diff <(cat "${root}/scripts/ops/pen-open.sh") "${work}/mutA-root/scripts/ops/pen-open.sh" | grep -c '^>')" -eq 1 ]; then
  ok 'mutation A：確認已拿掉 plan_hash_segments 的預算判斷（恰改一行）'
else
  bad 'mutation A：替換失敗，負控本身無效'
fi
big_case_setup
outA="$(cd "$tix_repo" && bash "${work}/mutA-root/scripts/ops/pen-read.sh" --budget-bytes 3000 "$wtBig" 2>&1)"; gotA=$?
if [ "$(head -1 "$PEN_STUB_RANGE_LOG")" = whole ]; then
  ok "mutation A：拿掉預算判斷後仍先送整份（execute 序＝$(tr '\n' ' ' < "$PEN_STUB_RANGE_LOG")），情境 (1) 的分段斷言轉紅——證明預算判斷在保護「不先送整份」"
else
  bad "mutation A 未如預期翻轉（execute 序＝$(tr '\n' ' ' < "$PEN_STUB_RANGE_LOG")，exit ${gotA}）"; printf '%s\n' "$outA" | sed 's/^/    /' >&2
fi
clear_fake_pen

# mutation B：拿掉重切上限（planned 模式的 depth 判斷改恆假）→ 情境 (3) 應變成「重切到單節點才放棄」而非「對半重切 1 次仍失敗」
mk_mutant mutB-root 's/if \[ "\$depth" -ge "\$HASH_MAX_HALVINGS" \]; then/if false; then/'
if grep -qF 'if false; then' "${work}/mutB-root/scripts/ops/pen-open.sh"; then
  ok 'mutation B：確認已把重切上限判斷改成恆假'
else
  bad 'mutation B：替換失敗，負控本身無效'
fi
big_case_setup
outB="$(cd "$tix_repo" && PEN_STUB_MAX_SPAN=0 PEN_OPEN_HASH_MAX_HALVINGS=1 bash "${work}/mutB-root/scripts/ops/pen-read.sh" --budget-bytes 5000 "$wtBig" 2>&1)"; gotB=$?
if ! grep -qF '已對半重切 1 次仍失敗，放棄' <<<"$outB" && grep -qF '已無法再分段仍失敗，放棄' <<<"$outB"; then
  ok 'mutation B：拿掉重切上限後不再於第 1 次重切後放棄（改成重切到單節點才放棄），情境 (3) 轉紅——證明上限判斷在這裡'
else
  bad "mutation B 未如預期翻轉（exit ${gotB}）"; printf '%s\n' "$outB" | sed 's/^/    /' >&2
fi
clear_fake_pen

# mutation C：拿掉 interrupted 統計事件（pen_stat "interrupted" 那行）→ 情境 (2) 的 interrupted=4 斷言必須紅（會記成 0）
mk_mutant mutC-root '/^    pen_stat "interrupted"$/d'
if [ "$(grep -cF 'pen_stat "interrupted"' "${work}/mutC-root/scripts/ops/pen-open.sh")" -lt "$(grep -cF 'pen_stat "interrupted"' "${root}/scripts/ops/pen-open.sh")" ]; then
  ok 'mutation C：確認已拿掉 interrupted 統計事件'
else
  bad 'mutation C：替換失敗，負控本身無效'
fi
big_case_setup
outC="$(cd "$plain_repo" && PEN_STUB_MAX_SPAN=1 PEN_STUB_FRONTMOST=Pen bash "${work}/mutC-root/scripts/ops/pen-read.sh" --ticket LS-997 --budget-bytes 3000 "$wtBig" 2>&1)"; gotC=$?
if [ "$gotC" -eq 0 ] && ! grep -qF 'interrupted=4' <<<"$(stats_log "$plain_repo" LS-997)" && grep -qF 'interrupted=0' <<<"$(stats_log "$plain_repo" LS-997)"; then
  ok 'mutation C：拿掉 interrupted 事件後統計 log 記成 interrupted=0（不再是 4），情境 (2) 的計數斷言轉紅——證明計數在這裡'
else
  bad "mutation C 未如預期翻轉（exit ${gotC}，log＝$(stats_log "$plain_repo" LS-997 | tail -1)）"; printf '%s\n' "$outC" | sed 's/^/    /' >&2
fi
clear_fake_pen

# mutation D（B1）：拿掉 count 比對（`if [ "$pen_roots" != "$disk_roots" ]` 改恆假）→ 情境 (6) 的「count 判不一致、不送分段」斷言必須紅
#   （此時只剩末段開放上界的雙保險擋下，仍會走 hash 不符，但已經送了分段回讀、沒有 roots-mismatch 訊息）
mk_mutant mutD-root 's/if \[ "\$pen_roots" != "\$disk_roots" \]; then/if false; then/'
if grep -qF 'if false; then' "${work}/mutD-root/scripts/ops/pen-open.sh"; then ok 'mutation D：確認已拿掉 count 比對'; else bad 'mutation D：替換失敗，負控本身無效'; fi
big_case_setup
export PEN_STUB_OSASCRIPT_KILLS=1
outD="$(cd "$tix_repo" && PEN_STUB_RANGE_FILE="$rend" bash "${work}/mutD-root/scripts/ops/pen-read.sh" --budget-bytes 3000 "$wtBig" 2>&1)"; gotD=$?
unset PEN_STUB_OSASCRIPT_KILLS
if ! grep -qF 'roots-mismatch(Pencil=9,disk=8)' <<<"$outD" && ! [ "$(cat "$PEN_STUB_RANGE_LOG")" = count ]; then
  ok "mutation D：拿掉 count 比對後不再有 roots-mismatch、改送了分段回讀（execute 序＝$(tr '\n' ' ' < "$PEN_STUB_RANGE_LOG")），情境 (6) 轉紅——證明 count 比對在這裡"
else
  bad "mutation D 未如預期翻轉（exit ${gotD}）"; printf '%s\n' "$outD" | sed 's/^/    /' >&2
fi
clear_fake_pen

# mutation E（B1 原始缺陷重現）：count 比對與末段開放上界兩道都拿掉（＝R1 版行為）→ 假陽性「與磁碟一致」，情境 (6) 必須紅
mk_mutant mutE-root 's/if \[ "\$pen_roots" != "\$disk_roots" \]; then/if false; then/; s/if \[ -n "\$lo" \] \&\& \[ -n "\${HASH_OPEN_HI:-}" \] \&\& \[ "\$hi" -ge "\$HASH_OPEN_HI" \]; then hi_send=2147483647; fi/:/'
if ! grep -qF 'hi_send=2147483647; fi' "${work}/mutE-root/scripts/ops/pen-open.sh" && grep -qF 'if false; then' "${work}/mutE-root/scripts/ops/pen-open.sh"; then ok 'mutation E：確認兩道防線都已拿掉'; else bad 'mutation E：替換失敗，負控本身無效'; fi
big_case_setup
export PEN_STUB_OSASCRIPT_KILLS=1
outE="$(cd "$tix_repo" && PEN_STUB_RANGE_FILE="$rend" bash "${work}/mutE-root/scripts/ops/pen-read.sh" --budget-bytes 3000 "$wtBig" 2>&1)"; gotE=$?
unset PEN_STUB_OSASCRIPT_KILLS
if [ "$gotE" -eq 0 ] && grep -qF "tree_hash=${BIG_HASH} 與磁碟一致" <<<"$outE"; then
  ok 'mutation E：兩道防線都拿掉後 Pen 端多尾端節點被誤判「與磁碟一致」（R1 B1 假陽性重現），情境 (6) 轉紅——證明修法擋的就是這個'
else
  bad "mutation E 未重現假陽性（exit ${gotE}）"; printf '%s\n' "$outE" | sed 's/^/    /' >&2
fi
clear_fake_pen
unset PEN_STUB_RANGE_MODE

if [ "$fail" -ne 0 ]; then
  echo "✗ pen-read-check 自測失敗" >&2
  exit 1
fi
echo "✓ pen-read 自測通過（${n} 組樣本）"
