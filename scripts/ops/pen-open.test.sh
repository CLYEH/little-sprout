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
# 模擬「找不到殘留行程」）。
cat > "${bin}/pgrep" <<'STUB'
#!/bin/bash
[ -s "${PEN_STUB_PID_FILE:?}" ] && cat "${PEN_STUB_PID_FILE}"
exit 0
STUB
chmod +x "${bin}/pgrep"

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
# 只印 $PEN_STUB_PS_OUTPUT 檔案內容（沒有該檔就印空，等同「ps 沒撈到任何額外視窗」）。
export PEN_STUB_PS_OUTPUT="${work}/ps_output"
: > "$PEN_STUB_PS_OUTPUT"
cat > "${bin}/ps" <<'STUB'
#!/bin/bash
[ -f "${PEN_STUB_PS_OUTPUT:?}" ] && cat "${PEN_STUB_PS_OUTPUT}"
exit 0
STUB
chmod +x "${bin}/ps"
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

# stub `pen`：只認 `interactive --app desktop`（忽略餵進去的 stdin 內容），依 $PEN_STUB_STATE 決定輸出——
#   PATH:<path> → 印 get_app_state 格式的那一行；HANG → sleep 5（測 ATTEMPT_TIMEOUT 看門狗）；其他 → 模擬讀不到
cat > "${bin}/pen" <<'STUB'
#!/bin/bash
if [ "$1" != interactive ]; then exit 1; fi
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
export PEN_BACKUP_DIR="${work}/backup"
mkdir -p "$PEN_BACKUP_DIR"

set_state() { printf '%s' "$1" > "$PEN_STUB_STATE"; }
open_calls() { wc -l < "$PEN_STUB_OPEN_LOG" | tr -d ' '; }
reset_open_tracking() { : > "$PEN_STUB_OPEN_LOG"; rm -f "$PEN_STUB_OPEN_COUNT"; unset PEN_STUB_OPEN_SUCCEED_AT; }

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
  && printf '%s' "$out" | grep -qF '已確認' && ! fake_pen_alive; then
  ok '⑪a 殘留＋安全：osascript 優雅退出成功 → 重開切換成功，假行程真的結束'
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

# ⑬a 目前已一致＋安全，仍強制清場重開（不信任舊 renderer 可能停在磁碟更新前的舊快照）——驗證新增的
#     「不因已一致就早退」邏輯，且清場前後仍照既有安全判定把關、重開後才真正算成功。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_safe
set_state "PATH:${want}"
start_fake_pen
export PEN_STUB_OSASCRIPT_KILLS=1
out="$(run "$wt" --force-reload 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF -- '--force-reload' \
  && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}" \
  && ! fake_pen_alive && [ "$(open_calls)" -eq 2 ]; then
  ok '⑬a --force-reload：目前已一致仍強制清場重開，假行程真的被換掉（LS-118）'
else
  bad "⑬a 應 exit 0 且真的清場重開（實得 ${got}，行程存活＝$(fake_pen_alive && echo yes || echo no)，open 呼叫次數＝$(open_calls)）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
unset PEN_STUB_OSASCRIPT_KILLS
clear_fake_pen

# ⑬b 目前已一致，但目標自己的 renderer 有未落地變更——即使已經 active，--force-reload 仍不能為了保
#     新鮮度而默默丟掉真實變更，fail closed 拒絕清場。
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_unsafe
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
reset_open_tracking; clear_fake_pen; clear_ps_pen_files; wt_backup_safe
set_state "PATH:${want}"
out="$(run "$wt" --force-reload 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF -- '--force-reload 但找不到 Pen 主行程'; then
  ok '⑬c --force-reload：pgrep 找不到主行程 → fail closed exit 2，不假裝清場過（LS-118 R1 F1）'
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
  && printf '%s' "$out" | grep -qF "清場後 Pen 目前文件＝${want}"; then
  ok '⑬d 預設模式 pgrep 找不到主行程：跳過清場、直接重開，不受 --force-reload 新規則影響（LS-118 R1 F1 對照）'
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

if [ "$fail" -ne 0 ]; then
  echo "✗ pen-open-check 自測失敗" >&2
  exit 1
fi
echo "✓ pen-open 自測通過（${n} 組樣本）"
