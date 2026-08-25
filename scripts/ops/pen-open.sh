#!/bin/bash
# LS-91：Pen app 開檔路徑機械對帳。
#
# 背景（LS-81／LS-91 comment A 實測，pen CLI 0.3.4）：Pencil MCP 的 execute `filePath` 參數無效，所有編輯落在
# Pen app 目前的 active document；pen CLI 連線模式的 `--in <file>` 在「不帶 --in 的後續呼叫」上不生效——本票
# 復驗：`pen interactive --app desktop --in <file>` 確實會讓**那一次**呼叫的 get_app_state 回報 `<file>`，但這只是
# 該次 CLI 連線的 session-local 覆寫，不影響 app 真正的 active document／不影響其後不帶 --in 的呼叫（含 Pencil
# MCP）——不是真正的切檔手段。唯一機械可行的切檔方法仍是 `open -a Pen <path>`。本腳本：`open -a Pen` 切檔 →
# 輪詢（總預算 ≤15s）用 `pen interactive --app desktop` 跑 `get_app_state()` 讀目前 active canvas editor 路徑 →
# 與目標路徑比對；不一致時嘗試自動清場後重試一次（R2，見下）。
#
# 用法：
#   pen-open.sh <worktree-or-repo-root> [--no-quit]   把 Pen 切到 <root>/design/littlesprout.pen 並輪詢對帳；
#                                                       不一致時預設嘗試自動清場重試，`--no-quit` 關掉這步
#                                                       （只對帳、不清場，等同 R2 之前的行為）
#   pen-open.sh --status                               不 open，只輪詢一次目前路徑並印到 stdout（供巡檢／派工前
#                                                       對帳用；不比對，比對交給呼叫端——見 §4-b）
#
# Exit code：
#   0＝（open 模式）路徑已一致（含自動清場重試後一致）；（--status）成功讀到路徑並印出
#   1＝（open 模式限定）輪詢逾時仍與目標路徑不一致（含清場後仍不一致，或判定不安全而未清場）
#   2＝Pen 沒開／pen CLI 未登入／連線失敗／用法錯誤／清場失敗需人工介入（fail closed；--status 讀不到路徑也是這個）
#
# R2（自動清場，使用者核可 2026-08-25）：目標路徑已在背景視窗開著時，`open -a Pen` 不會奪回 active（見下方
# 「已知坑」）。輪詢逾時仍不一致 → 從目前 active 路徑（last_seen）推回它的 worktree 根 → 對該根跑
# `pen-land.sh <that-root> --dry-run`（不帶 --allow-unchanged，藉此把它預設的「結構無差異」拒絕當成「沒有
# 未落地變更」的安全信號來解讀：dry-run 印出真的有差異＝不安全，不動；只有 exit 1 且訊息明確是「本輪零變更或
# autosave 還沒追上」才視為安全）→ 安全才嘗試 `osascript -e 'tell application "Pen" to quit'`（優雅退出，給
# 4 秒）→ 還在就 `kill -TERM`（不用 SIGKILL）→ 總計等程序消失 ≤10 秒 → 重新 `open -a Pen` 並再跑一輪輪詢。
# 不安全（有未落地變更／無法確認）就不清場，印出提示「先 pen-land <that-root>」，exit 1。`--no-quit` 關掉整段
# 自動清場，只做原本的對帳。
#
# macOS 沒有 coreutils timeout：每次 pen interactive 呼叫用背景程序＋背景 sleep 到期就 kill 的看門狗模式
# （同 scripts/ops/patrol.sh 的 fetch_with_timeout；此處用 stdin/stdout 重導向而非管線，$! 才是 pen 程序本身的
# PID，kill 不會留下管線另一端的孤兒程序）。
#
# 自測：scripts/ops/pen-open.test.sh（stub `open`／`pen`／`pgrep`／`osascript`／`kill`；掛 CI `rules` job）。
#
# 已知坑（R1 I6）：本腳本與真實 pen CLI 唯一的耦合點是 poll_once() 那行 grep 樣式——
# 「Currently active canvas editor: `…`」，這是 pen CLI **0.3.4** 的輸出格式，沒有更穩定的結構化介面
# 可查（get_app_state() 回的是給人看的一段 message 文字，不是 JSON）。CLI 若改了這行的措辭，自測仍會綠
# （stub 複製的是同一個假設），但實跑會讀不到路徑、fail closed 成 exit 2——方向安全，不會誤放行，只是要
# 靠實機才驗得出來（見 handoff／本檔 git log 的實機復驗紀錄）。升級 pen CLI 後應重新用 `pen interactive
# --app desktop` 手動跑一次 `get_app_state()` 確認這行格式沒變。
#
# 已知坑（本票實測）：這台機器的 bash 3.2 在 LC_CTYPE=UTF-8 下，裸 `$var` 緊接全形標點（如「」／：）會把該標點的
# UTF-8 位元組也吃進變數名稱，觸發 `set -u` 的 unbound variable（例："$want」" 炸成「want�: unbound variable」）。
# 一律用 `${var}` 明確收尾；本檔與訊息字串中所有變數皆已改寫，新增訊息比照。
#
# 已知坑（本票實測，重要；R2 起由自動清場處理）：`open -a Pen <path>` 只在該路徑**尚未在別的背景視窗開著**時
# 可靠——這台機器累積了 5 個過去票留下的背景 renderer（LS-17-impl／LS-72／LS-81／LS-91／主 checkout 各一），
# 對其中任一已開著的路徑重新 `open -a Pen` 並輪詢 30 秒（遠超本腳本預設的 15s）仍讀不到切換；get_app_state
# 回報的是「上次真正被切到的那個」，不會因為再 open 同一路徑而重新奪回 active。**唯一驗證有效的復原手段**：
# 確認目前 active 文件沒有未落地變更後 `kill -TERM <Pen 主行程 pid>` 乾淨結束，再 `open -a Pen <目標路徑>`
# 重開——全新行程對「當下沒有背景視窗」的路徑立即可切（本票 R1 階段實測：`osascript ... to quit` 在這個 session
# 的沙盒環境裡對 Pen 沒有效果，行程仍在——研判是 Automation 權限被擋，同一 session 內 `tell application
# "System Events"` 也讀不到 Pen 的視窗清單，同一種症狀；`kill -TERM <pid>` 由 PID 直接送訊號則確實有效、乾淨
# 結束後全部視窗的 backup 皆完整無損。R2 因此兩者都做：先試 osascript（環境允許時是更禮貌的退出方式），
# 短暫等待後一律補 `kill -TERM` 兜底，不依賴 osascript 一定成功）。
set -uo pipefail

usage() {
  echo "用法：pen-open.sh <worktree-or-repo-root> [--no-quit]｜pen-open.sh --status" >&2
}

PEN_BIN=${PEN_BIN:-pen}
POLL_TIMEOUT=${PEN_OPEN_TIMEOUT:-15}
ATTEMPT_TIMEOUT=${PEN_OPEN_ATTEMPT_TIMEOUT:-8}
POLL_INTERVAL=${PEN_OPEN_POLL_INTERVAL:-2}
QUIT_TIMEOUT=${PEN_OPEN_QUIT_TIMEOUT:-10}
QUIT_GRACE=${PEN_OPEN_QUIT_GRACE:-4}
for v in "$POLL_TIMEOUT" "$ATTEMPT_TIMEOUT" "$POLL_INTERVAL" "$QUIT_TIMEOUT" "$QUIT_GRACE"; do
  case "$v" in
    ''|*[!0-9]*) echo "✗ pen-open：PEN_OPEN_TIMEOUT／PEN_OPEN_ATTEMPT_TIMEOUT／PEN_OPEN_POLL_INTERVAL／PEN_OPEN_QUIT_TIMEOUT／PEN_OPEN_QUIT_GRACE 須為整數秒（得到「${v}」）" >&2; exit 2 ;;
  esac
done

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  usage
  exit 2
fi

mode=open
target=$1
no_quit=0
if [ "$1" = "--status" ]; then
  if [ $# -ne 1 ]; then
    usage
    exit 2
  fi
  mode=status
  target=""
elif [ $# -eq 2 ]; then
  if [ "$2" = "--no-quit" ]; then
    no_quit=1
  else
    usage
    exit 2
  fi
fi

command -v "$PEN_BIN" >/dev/null 2>&1 || {
  echo "✗ pen-open：找不到 pen CLI（PATH 上沒有「${PEN_BIN}」）" >&2
  exit 2
}

# 單次嘗試：跑 `pen interactive --app desktop` 餵 get_app_state()，印出擷取到的 active canvas editor 路徑
# （擷取不到印空字串）。用暫存檔而非 $(...) 直接包住整個背景管線，避免管線孤兒程序（見檔頭）。
poll_once() {
  local tmp in
  tmp=$(mktemp "${TMPDIR:-/tmp}/pen-open-out.XXXXXX") || return 1
  in=$(mktemp "${TMPDIR:-/tmp}/pen-open-in.XXXXXX") || { rm -f "$tmp"; return 1; }
  printf 'get_app_state()\nexit()\n' > "$in"
  "$PEN_BIN" interactive --app desktop < "$in" > "$tmp" 2>&1 &
  local ppid=$!
  ( sleep "$ATTEMPT_TIMEOUT"; kill "$ppid" 2>/dev/null ) >/dev/null 2>&1 &
  local wpid=$!
  wait "$ppid" 2>/dev/null
  kill "$wpid" 2>/dev/null
  rm -f "$in"
  grep -o 'Currently active canvas editor: `[^`]*`' "$tmp" 2>/dev/null \
    | sed -E 's/^Currently active canvas editor: `//; s/`$//' | head -1
  rm -f "$tmp"
}

if [ "$mode" = status ]; then
  path=$(poll_once)
  if [ -z "$path" ]; then
    echo "✗ pen-open --status：讀不到 Pen 目前文件路徑（app 沒開／pen CLI 未登入／連線失敗，fail closed）" >&2
    exit 2
  fi
  echo "$path"
  exit 0
fi

root=$(cd "$target" 2>/dev/null && pwd -P) || {
  echo "✗ pen-open：找不到目錄「${target}」" >&2
  exit 2
}
want="${root}/design/littlesprout.pen"
[ -f "$want" ] || {
  echo "✗ pen-open：找不到「${want}」" >&2
  exit 2
}

# 輪詢到 $want 一致就 echo 訊息並回傳 0；逾時回傳 1（不一致，$LAST_SEEN 非空）或 2（讀不到路徑，$LAST_SEEN 空）。
# 用全域變數 LAST_SEEN 而非 local 回傳值，好讓呼叫端（清場後重試）也讀得到最後看到的路徑。
poll_until_match() {
  local deadline
  deadline=$((SECONDS + POLL_TIMEOUT))
  LAST_SEEN=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    path=$(poll_once)
    if [ -n "$path" ]; then
      LAST_SEEN=$path
      if [ "$path" = "$want" ]; then
        return 0
      fi
    fi
    [ "$SECONDS" -lt "$deadline" ] && sleep "$POLL_INTERVAL"
  done
  [ -n "$LAST_SEEN" ] && return 1
  return 2
}

open -a Pen "$want" >/dev/null 2>&1
poll_until_match
poll_rc=$?
if [ "$poll_rc" -eq 0 ]; then
  echo "✓ pen-open：Pen 目前文件＝${want}"
  exit 0
fi
if [ "$poll_rc" -eq 2 ]; then
  echo "✗ pen-open：${POLL_TIMEOUT}s 內讀不到 Pen 文件路徑（app 沒開／pen CLI 未登入／連線失敗，fail closed）" >&2
  exit 2
fi

echo "✗ pen-open：路徑不一致——目標「${want}」，Pen 目前「${LAST_SEEN}」" >&2

if [ "$no_quit" -eq 1 ]; then
  echo "  （--no-quit：不嘗試清場，僅回報）" >&2
  exit 1
fi

# ---- R2 自動清場：先驗證安全，安全才 quit＋重開＋重試一輪 ----
suffix="/design/littlesprout.pen"
that_root=""
case "$LAST_SEEN" in
  */design/littlesprout.pen) that_root=${LAST_SEEN%$suffix} ;;
esac
if [ -z "$that_root" ] || [ ! -d "$that_root" ]; then
  echo "  無法從「${LAST_SEEN}」推出 worktree 根目錄，或該目錄已不存在——不嘗試自動清場，回報人工處理" >&2
  exit 1
fi

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
land_out=$(bash "${script_root}/scripts/ops/pen-land.sh" "$that_root" --dry-run 2>&1)
land_rc=$?
if [ "$land_rc" -ne 1 ] || ! printf '%s' "$land_out" | grep -qF '本輪零變更或 autosave 還沒追上'; then
  echo "  「${LAST_SEEN}」可能有尚未落地的變更（pen-land.sh --dry-run 顯示有差異，或無法確認）——不自動 quit。先跑：bash scripts/ops/pen-land.sh ${that_root}" >&2
  printf '%s\n' "$land_out" | sed 's/^/    /' >&2
  exit 1
fi
echo "  已確認「${that_root}」沒有未落地變更，嘗試安全結束 Pen 並重開……" >&2

pen_pid=$(pgrep -f 'Pen\.app/Contents/MacOS/Pen$' 2>/dev/null | head -1)
if [ -n "$pen_pid" ]; then
  osascript -e 'tell application "Pen" to quit' >/dev/null 2>&1
  quit_start=$SECONDS
  quit_deadline=$((quit_start + QUIT_TIMEOUT))
  term_sent=0
  while [ "$SECONDS" -lt "$quit_deadline" ] && kill -0 "$pen_pid" 2>/dev/null; do
    if [ "$term_sent" -eq 0 ] && [ "$SECONDS" -ge $((quit_start + QUIT_GRACE)) ]; then
      kill -TERM "$pen_pid" 2>/dev/null
      term_sent=1
    fi
    sleep 1
  done
  if kill -0 "$pen_pid" 2>/dev/null; then
    echo "✗ pen-open：Pen（pid ${pen_pid}）在 ${QUIT_TIMEOUT}s 內無法安全結束——需人工介入，不強殺（SIGKILL）" >&2
    exit 2
  fi
fi

open -a Pen "$want" >/dev/null 2>&1
poll_until_match
poll_rc=$?
if [ "$poll_rc" -eq 0 ]; then
  echo "✓ pen-open：清場後 Pen 目前文件＝${want}"
  exit 0
elif [ "$poll_rc" -eq 1 ]; then
  echo "✗ pen-open：清場後仍路徑不一致——目標「${want}」，Pen 目前「${LAST_SEEN}」" >&2
  exit 1
else
  echo "✗ pen-open：清場後 ${POLL_TIMEOUT}s 內讀不到 Pen 文件路徑" >&2
  exit 2
fi
