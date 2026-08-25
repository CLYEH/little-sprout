#!/bin/bash
# LS-91：Pen app 開檔路徑機械對帳。
#
# 背景（LS-81／LS-91 comment A 實測，pen CLI 0.3.4）：Pencil MCP 的 execute `filePath` 參數無效，所有編輯落在
# Pen app 目前的 active document；pen CLI 連線模式（`pen interactive --app desktop --in <file>`）的 `--in` 同樣無效
# （get_app_state 仍回舊路徑）。唯一機械可行的切檔方法是 `open -a Pen <path>`——app 立即把該路徑設為 active
# document（A 段實測確認）。本腳本：`open -a Pen` 切檔 → 輪詢（總預算 ≤15s）用
# `pen interactive --app desktop` 跑 `get_app_state()` 讀目前 active canvas editor 路徑 → 與目標路徑比對。
#
# 用法：
#   pen-open.sh <worktree-or-repo-root>   把 Pen 切到 <root>/design/littlesprout.pen 並輪詢對帳
#   pen-open.sh --status                  不 open，只輪詢一次目前路徑並印到 stdout（供巡檢／派工前對帳用；
#                                          不比對，比對交給呼叫端——見 docs/COLLABORATION.md §4-b）
#
# Exit code：
#   0＝（open 模式）路徑已一致；（--status）成功讀到路徑並印出
#   1＝（open 模式限定）輪詢逾時仍與目標路徑不一致，印兩邊路徑
#   2＝Pen 沒開／pen CLI 未登入／連線失敗／用法錯誤（fail closed；--status 讀不到路徑也是這個）
#
# macOS 沒有 coreutils timeout：每次 pen interactive 呼叫用背景程序＋背景 sleep 到期就 kill 的看門狗模式
# （同 scripts/ops/patrol.sh 的 fetch_with_timeout；此處用 stdin/stdout 重導向而非管線，$! 才是 pen 程序本身的
# PID，kill 不會留下管線另一端的孤兒程序）。
#
# 自測：scripts/ops/pen-open.test.sh（stub `open` 與 `pen`；掛 CI `rules` job）。
#
# 已知坑（本票實測）：這台機器的 bash 3.2 在 LC_CTYPE=UTF-8 下，裸 `$var` 緊接全形標點（如「」／：）會把該標點的
# UTF-8 位元組也吃進變數名稱，觸發 `set -u` 的 unbound variable（例："$want」" 炸成「want�: unbound variable」）。
# 一律用 `${var}` 明確收尾；本檔與訊息字串中所有變數皆已改寫，新增訊息比照。
set -uo pipefail

usage() {
  echo "用法：pen-open.sh <worktree-or-repo-root>｜pen-open.sh --status" >&2
}

PEN_BIN=${PEN_BIN:-pen}
POLL_TIMEOUT=${PEN_OPEN_TIMEOUT:-15}
ATTEMPT_TIMEOUT=${PEN_OPEN_ATTEMPT_TIMEOUT:-8}
POLL_INTERVAL=${PEN_OPEN_POLL_INTERVAL:-2}
for v in "$POLL_TIMEOUT" "$ATTEMPT_TIMEOUT" "$POLL_INTERVAL"; do
  case "$v" in
    ''|*[!0-9]*) echo "✗ pen-open：PEN_OPEN_TIMEOUT／PEN_OPEN_ATTEMPT_TIMEOUT／PEN_OPEN_POLL_INTERVAL 須為整數秒（得到「${v}」）" >&2; exit 2 ;;
  esac
done

if [ $# -ne 1 ]; then
  usage
  exit 2
fi

mode=open
target=$1
if [ "$1" = "--status" ]; then
  mode=status
  target=""
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

open -a Pen "$want" >/dev/null 2>&1

deadline=$((SECONDS + POLL_TIMEOUT))
last_seen=""
while [ "$SECONDS" -lt "$deadline" ]; do
  path=$(poll_once)
  if [ -n "$path" ]; then
    last_seen=$path
    if [ "$path" = "$want" ]; then
      echo "✓ pen-open：Pen 目前文件＝${want}"
      exit 0
    fi
  fi
  [ "$SECONDS" -lt "$deadline" ] && sleep "$POLL_INTERVAL"
done

if [ -n "$last_seen" ]; then
  echo "✗ pen-open：路徑不一致——目標「${want}」，Pen 目前「${last_seen}」" >&2
  exit 1
else
  echo "✗ pen-open：${POLL_TIMEOUT}s 內讀不到 Pen 文件路徑（app 沒開／pen CLI 未登入／連線失敗，fail closed）" >&2
  exit 2
fi
