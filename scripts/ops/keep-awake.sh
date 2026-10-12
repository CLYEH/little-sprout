#!/bin/bash
# Mac 防鎖定（LS-512）：租約制 keep-awake——巡檢每輪續租、巡檢停了租約到期自動復原。
#
# 背景：Mac 閒置 300s 進保護程式＋300s 要密碼 → `IOConsoleLocked=true`；Pen（Electron，1.2.16 起）鎖定即停排版，
# 收據掃描／`pen-bounds-probe.sh` 出假陽性或 exit 3（LS-471 r1／LS-511 r1 卡了 4h40m）。`caffeinate -u` 實測不重置
# HIDIdleTime、擋不住保護程式；有效組合＝`defaults -currentHost write com.apple.screensaver idleTime -int 0`＋
# `caffeinate -d -i -s`。使用者 2026-10-13 裁：「防鎖定跟著巡檢程式，由程式控制，關掉時就復原」。
#
# 用法：keep-awake.sh start [--lease <秒>] | status | restore | hold
#   start    冪等。第一次：記原 idleTime 到 ~/.little-sprout/keep-awake.json（讀不到當 300；json 已存在且目前已是 0
#            就不覆寫原值；沒有 json 卻已是 0＝別人手動設的，原值記 300，不把 0 當原值）、寫 idleTime 0、
#            寫租約檔 keep-awake.lease（內容＝租約秒數，mtime＝最後續租時間）、沒有 holder 就背景起一支 `hold`
#            （nohup，pid 記進 json）、沒有 `caffeinate -d -i -s` 就起一支 `-w <hold pid>`（已有人手動起的 caffeinate 直接接手）。
#            之後每次呼叫（patrol 每輪）只 touch 租約。--lease 預設 3600。
#   hold     holder 常駐迴圈：每 KEEP_AWAKE_POLL_SEC（預設 60）秒確保 caffeinate 在、檢查租約檔，超過租約秒數沒被續租
#            （或租約檔消失）就執行 restore 後退出。巡檢 cron 被刪／session 結束後，最多「租約＋一個輪詢週期」內自動復原。
#   status   印一行：idleTime、caffeinate pid、locked（ioreg IOConsoleLocked）、HIDIdleTime 秒、hold pid、租約剩餘秒。
#            idleTime≠0、無 caffeinate、locked=true 任一成立 → exit 2，否則 0。
#   restore  idleTime 還原為 json 記的原值（沒有 json 且目前為 0 → 還原 300）、kill hold 與 caffeinate、刪 json／租約檔。
#            冪等。SessionEnd hook（.claude/settings.json）呼叫它做立即復原。
# 不碰 sysadminctl／密碼設定；`defaults` 只寫 com.apple.screensaver 的 idleTime。非 macOS（無 defaults）→ 印一行略過、exit 0。
#
# 環境變數（自測／覆寫）：KEEP_AWAKE_STATE_DIR（預設 ~/.little-sprout）、KEEP_AWAKE_LEASE_FILE、
#   KEEP_AWAKE_DEFAULTS_DOMAIN（預設 com.apple.screensaver，並加 -currentHost；覆寫成路徑時不加）、
#   KEEP_AWAKE_CAFFEINATE_BIN（預設 caffeinate）、KEEP_AWAKE_CAFFEINATE_PATTERN（pgrep -f 樣式，預設
#   '^(/usr/bin/)?caffeinate -d -i -s'——錨在行首，不會誤中把這串字面放在命令列中間的 shell 包裝行程）、
#   KEEP_AWAKE_IOREG_BIN、KEEP_AWAKE_POLL_SEC、KEEP_AWAKE_LEASE_DEFAULT（預設 3600）。
# 自測：scripts/ops/keep-awake.test.sh；patrol 每輪呼叫 start（scripts/ops/patrol.sh「keep-awake」段）。
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STATE_DIR="${KEEP_AWAKE_STATE_DIR:-$HOME/.little-sprout}"
STATE_FILE="${STATE_DIR}/keep-awake.json"
LEASE_FILE="${KEEP_AWAKE_LEASE_FILE:-${STATE_DIR}/keep-awake.lease}"
DOMAIN="${KEEP_AWAKE_DEFAULTS_DOMAIN:-com.apple.screensaver}"
CAFF_BIN="${KEEP_AWAKE_CAFFEINATE_BIN:-caffeinate}"
CAFF_PATTERN="${KEEP_AWAKE_CAFFEINATE_PATTERN:-^(/usr/bin/)?caffeinate -d -i -s}"
IOREG_BIN="${KEEP_AWAKE_IOREG_BIN:-ioreg}"
POLL="${KEEP_AWAKE_POLL_SEC:-60}"
LEASE_DEFAULT="${KEEP_AWAKE_LEASE_DEFAULT:-3600}"
DEFAULT_IDLE=300

usage() { echo "用法：keep-awake.sh start [--lease <秒>] | status | restore | hold" >&2; }

if ! command -v defaults >/dev/null 2>&1; then
  echo "keep-awake：非 macOS（無 defaults），略過"; exit 0
fi

dflt() {  # dflt read|write …：預設 domain 走 -currentHost；自測覆寫成路徑時不加
  if [ -z "${KEEP_AWAKE_DEFAULTS_DOMAIN:-}" ]; then defaults -currentHost "$1" "$DOMAIN" idleTime "${@:2}"
  else defaults "$1" "$DOMAIN" idleTime "${@:2}"; fi
}
read_idle() { dflt read 2>/dev/null | tr -d '[:space:]'; }
caff_pids() { pgrep -f -- "$CAFF_PATTERN" 2>/dev/null; }
first_caff() { caff_pids | head -1; }
state_get() { sed -n "s/.*\"$1\":[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$STATE_FILE" 2>/dev/null | head -1; }
write_state() {  # write_state <原 idleTime> <hold pid>
  mkdir -p "$STATE_DIR"
  printf '{"original_idle_time":%s,"hold_pid":%s,"started_at":"%s"}\n' "$1" "${2:-0}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_FILE"
}
is_hold() {  # pid 還活著且命令列真的是 keep-awake.sh hold（防 pid 重用誤殺）
  local p=${1:-}
  case "$p" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null || return 1
  ps -p "$p" -o command= 2>/dev/null | grep -q 'keep-awake.sh hold'
}
file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
lease_remaining() {  # 剩餘秒（負數＝已過期）；租約檔不在 → 空
  [ -f "$LEASE_FILE" ] || return 0
  local sec mt; sec=$(tr -d '[:space:]' < "$LEASE_FILE"); mt=$(file_mtime "$LEASE_FILE")
  case "$sec$mt" in ''|*[!0-9]*) return 0 ;; esac
  echo $(( mt + sec - $(date +%s) ))
}
ensure_caffeinate() {  # ensure_caffeinate <-w 的 pid>
  [ -n "$(first_caff)" ] && return 0
  nohup "$CAFF_BIN" -d -i -s -w "$1" </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

cmd_start() {
  local lease=$LEASE_DEFAULT
  while [ $# -gt 0 ]; do
    case "$1" in
      --lease) [ $# -ge 2 ] || { usage; exit 2; }; lease=$2; shift 2 ;;
      *) usage; exit 2 ;;
    esac
  done
  case "$lease" in ''|*[!0-9]*|0) echo "✗ keep-awake：--lease 須為正整數秒（得到「${lease}」）" >&2; exit 2 ;; esac
  mkdir -p "$STATE_DIR" || { echo "✗ keep-awake：無法建立 ${STATE_DIR}" >&2; exit 1; }
  local cur orig hpid
  cur=$(read_idle); case "$cur" in ''|*[!0-9]*) cur= ;; esac
  orig=$(state_get original_idle_time); case "$orig" in ''|*[!0-9]*) orig= ;; esac
  # 原值：json 已有且目前已是 0 → 沿用；否則目前值（非 0）；讀不到／沒 json 卻已是 0（別人手動設的）→ 300
  if [ -n "$orig" ] && [ "${cur:-x}" = 0 ]; then :
  elif [ -n "$cur" ] && [ "$cur" != 0 ]; then orig=$cur
  elif [ -z "$orig" ]; then orig=$DEFAULT_IDLE; fi
  hpid=$(state_get hold_pid)
  if [ "${cur:-x}" != 0 ]; then
    dflt write -int 0 || { echo "✗ keep-awake：寫 idleTime 0 失敗" >&2; exit 1; }
  fi
  printf '%s\n' "$lease" > "$LEASE_FILE" || { echo "✗ keep-awake：寫租約檔失敗（${LEASE_FILE}）" >&2; exit 1; }
  local fresh=0
  if ! is_hold "$hpid"; then
    nohup bash "$SELF" hold </dev/null >/dev/null 2>&1 &
    hpid=$!
    disown 2>/dev/null || true
    fresh=1
  fi
  write_state "$orig" "$hpid"
  if [ "$fresh" -eq 1 ]; then
    # 新起的 hold 第一圈自己會補 caffeinate；這裡再起會兩邊同時看到「沒有」而各起一支。只等它出現（最多 3 秒）
    local w=30; while [ -z "$(first_caff)" ] && [ "$w" -gt 0 ]; do sleep 0.1; w=$((w - 1)); done
  else
    ensure_caffeinate "$hpid"; sleep 0.3   # 讓剛起的 caffeinate 進得了 pgrep
  fi
  echo "keep-awake：start ok（原 idleTime=${orig}，lease=${lease}s，hold pid=${hpid}，caffeinate pid=$(first_caff || true)）"
}

cmd_hold() {
  trap 'exit 0' TERM INT
  while :; do
    ensure_caffeinate "$$"
    local rem; rem=$(lease_remaining)
    if [ -z "$rem" ] || [ "$rem" -lt 0 ]; then
      echo "keep-awake：租約過期（剩餘 ${rem:-無檔}），hold 自動 restore" >&2
      cmd_restore
      exit 0
    fi
    sleep "$POLL" & wait $!
  done
}

cmd_status() {
  local idle caff locked hid hpid rem lines
  idle=$(read_idle); caff=$(first_caff)
  lines=$("$IOREG_BIN" -n Root -d1 -a 2>/dev/null | grep -A1 'IOConsoleLocked' | tail -1)
  case "$lines" in *'<true/>'*) locked=true ;; *) locked=false ;; esac
  hid=$("$IOREG_BIN" -c IOHIDSystem 2>/dev/null | awk '/"HIDIdleTime"/ { printf "%d", $NF / 1000000000; exit }')
  hpid=$(state_get hold_pid); is_hold "$hpid" || hpid=
  rem=$(lease_remaining)
  echo "keep-awake：idleTime=${idle:-?} caffeinate=${caff:-無} locked=${locked} HIDIdleTime=${hid:-?}s hold=${hpid:-無} lease剩餘=${rem:-無}${rem:+s}"
  if [ "${idle:-x}" != 0 ] || [ -z "$caff" ] || [ "$locked" = true ]; then exit 2; fi
  exit 0
}

cmd_restore() {
  local cur orig hpid p
  cur=$(read_idle); orig=$(state_get original_idle_time); hpid=$(state_get hold_pid)
  case "$orig" in ''|*[!0-9]*) orig= ;; esac
  if [ -z "$orig" ] && [ "${cur:-x}" = 0 ]; then orig=$DEFAULT_IDLE; fi   # 沒 json 卻是 0＝手動設的，還原成系統預設
  if [ -n "$orig" ]; then dflt write -int "$orig" || echo "✗ keep-awake：還原 idleTime 失敗" >&2; fi
  if [ "$hpid" != "$$" ] && is_hold "$hpid"; then kill "$hpid" 2>/dev/null; fi
  for p in $(caff_pids); do kill "$p" 2>/dev/null; done
  rm -f "$STATE_FILE" "$LEASE_FILE"
  echo "keep-awake：restore ok（idleTime=${orig:-未動}，hold／caffeinate 已結束，json／租約已刪）"
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  start) cmd_start "$@" ;;
  hold) cmd_hold ;;
  status) cmd_status ;;
  restore) cmd_restore ;;
  *) usage; exit 2 ;;
esac
