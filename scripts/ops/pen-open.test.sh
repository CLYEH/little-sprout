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

# wt3：只透過 ps 枚舉才會被看見的「隱藏」第三個視窗（LAST_SEEN／want 都不指向它）——驗證 R3 F1 完整修法：
# 沒有它，get_app_state 只回得出一個 active，這份不安全的視窗永遠不會被檢查到。
wt3="${work}/wt3"
mkdir -p "${wt3}/design"
WT3_SAFE='{"version":1,"fileToken":"tok1","variables":{},"themes":{},"children":[{"id":"z1","x":1,"children":[]}]}'
printf '%s' "$WT3_SAFE" > "${wt3}/design/littlesprout.pen"
want3="$(cd "${wt3}/design" && pwd -P)/littlesprout.pen"
wt3_backup_unsafe() { printf '%s' '{"version":1,"fileToken":"tok1","variables":{},"themes":{},"children":[{"id":"z1","x":1,"children":[{"id":"z2","y":2,"children":[]}]}]}' > "${PEN_BACKUP_DIR}/$(printf '%s' "file://${want3}" | shasum | awk '{print $1}')"; }

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

# ---- 不一致（殘留路徑推出的 worktree 根不存在——R3 起 $want 自己也在候選清單裡，先給它安全 backup，
#      讓失敗原因單純歸給不存在的 other，不被 $want 缺 backup 混淆）----
other="${work}/wt-other/design/littlesprout.pen"
wt_backup_safe
set_state "PATH:${other}"
out="$(run "$wt" 2>&1)"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF "${want}" && printf '%s' "$out" | grep -qF "${other}" \
  && printf '%s' "$out" | grep -qF "${work}/wt-other」不存在" && printf '%s' "$out" | grep -qF '不自動 quit'; then
  ok '不一致：Pen 目前是別的檔（推出的 worktree 根不存在）→ exit 1，訊息含兩邊路徑，不清場'
else
  bad "不一致案例應 exit 1 且印兩邊路徑（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
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
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF "先跑：bash scripts/ops/pen-land.sh ${wt2_resolved}" \
  && fake_pen_alive && [ "$(open_calls)" -eq 1 ]; then
  ok '⑪c 殘留＋有未落地變更：不 quit、不重開，exit 1，假行程仍活著'
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

if [ "$fail" -ne 0 ]; then
  echo "✗ pen-open-check 自測失敗" >&2
  exit 1
fi
echo "✓ pen-open 自測通過（${n} 組樣本）"
