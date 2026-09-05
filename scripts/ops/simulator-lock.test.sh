#!/bin/bash
# simulator-lock.sh 的自測（LS-83；LS-207 c18ef27f 補 --udid 字級／外觀自動調整）。CI Ops 腳本自測 step 跑它。
# 互斥／逾時／死鎖回收／signal 處理的核心邏輯已透過 push-gate.test.sh 把真正的 simulator-lock.sh 複製進合成 repo
# 反覆驗證（該檔案是 push-gate.sh 唯一的呼叫端）；這裡只補 LS-207 新增的 --udid 行為——push-gate.sh 目前不傳
# --udid，所以這支腳本的既有呼叫端完全不受影響（udid 變數預設空、下面的邏輯全部門檻在 `[ -n "$udid" ]`）。
# 「前饋必有反饋」：若 --udid 給了卻不調整字級／外觀、SIMLOCK_KEEP_UI=1 沒有真的跳過、查詢失敗仍硬設、或釋放時
# 沒有復原原值，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lock_sh="${root}/scripts/ops/simulator-lock.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export SIMULATOR_LOCK_POLL=0.2

has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（輸出應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✗ ${1}（輸出不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else echo "✓ $1"; fi; }
rc_is() { if [ "$3" -eq "$2" ]; then echo "✓ $1"; else echo "✗ ${1}（期望 exit ${2}，實得 ${3}）" >&2; printf '%s\n' "$4" | sed 's/^/    /' >&2; fail=1; fi; }

# ---- 假 xcrun：只認 `xcrun simctl ui <udid> <key> [<value>]`；把每次呼叫記一行到 $XCRUN_LOG（含 query／set 區分）；
#      query（無 value）依 XCRUN_MODE 決定回什麼、是否失敗；set（有 value）依 XCRUN_MODE 決定成功與否。
bin="$work/bin"; mkdir -p "$bin"
cat > "$bin/xcrun" <<'EOS'
#!/bin/bash
log="${XCRUN_LOG:?}"
mode="${XCRUN_MODE:-ok}"
if [ "$1" = simctl ] && [ "$2" = ui ]; then
  udid=$3; key=$4; val=${5:-}
  if [ -n "$val" ]; then
    printf 'set %s %s %s\n' "$udid" "$key" "$val" >> "$log"
    [ "$mode" = setfail ] && exit 1
    exit 0
  else
    printf 'query %s %s\n' "$udid" "$key" >> "$log"
    case "$mode" in
      queryfail) exit 1 ;;
    esac
    case "$key" in
      content_size) echo "large" ;;
      appearance) echo "dark" ;;
    esac
    exit 0
  fi
fi
echo "stub xcrun：不認得的呼叫 $*" >&2
exit 1
EOS
chmod +x "$bin/xcrun"
export PATH="$bin:$PATH"
export XCRUN_LOG="$work/xcrun.log"

run() {   # run <lock dir> <XCRUN_MODE> <額外參數…> -- <命令…>
  local dir=$1 mode=$2; shift 2
  : > "$XCRUN_LOG"
  XCRUN_MODE="$mode" bash "$lock_sh" --dir "$dir" "$@" 2>&1
}

# ---- ① --udid 給了、查詢與設定都成功 → 取鎖後查原值、設 medium/light、跑命令、釋放前復原原值 ----
out1="$(run "$work/l1" ok --udid UDID-1 -- echo ran)"; rc=$?
rc_is '① exit 0' 0 "$rc" "$out1"
has   '① 命令有執行' "$out1" 'ran'
has   '① 印已調整（含原值與 UDID）' "$out1" '已將 UDID-1 字級／外觀改為 content_size=medium appearance=light（原值 content_size=large appearance=dark，釋放時復原）'
has   '① 印已復原（含原值）' "$out1" '已復原 UDID-1 字級／外觀（content_size=large appearance=dark）'
log1="$(cat "$XCRUN_LOG")"
want1=$'query UDID-1 content_size\nquery UDID-1 appearance\nset UDID-1 content_size medium\nset UDID-1 appearance light\nset UDID-1 content_size large\nset UDID-1 appearance dark'
if [ "$log1" = "$want1" ]; then echo "✓ ① xcrun 呼叫順序：查詢兩次→設 medium/light→（命令）→復原原值兩次"; else echo "✗ ① xcrun 呼叫順序不對" >&2; echo "    實得：" >&2; printf '%s\n' "$log1" | sed 's/^/      /' >&2; fail=1; fi

# ---- ② 沒有 --udid（既有呼叫端 push-gate.sh 現況）→ 完全不呼叫 xcrun ui、行為不變 ----
out2="$(run "$work/l2" ok -- echo ran2)"; rc=$?
rc_is '② 無 --udid → exit 0' 0 "$rc" "$out2"
has   '② 命令有執行' "$out2" 'ran2'
if [ -s "$XCRUN_LOG" ]; then echo "✗ ② 無 --udid 不應呼叫 xcrun" >&2; cat "$XCRUN_LOG" >&2; fail=1; else echo "✓ ② 無 --udid 不呼叫 xcrun（既有呼叫端零影響）"; fi

# ---- ③ SIMLOCK_KEEP_UI=1 → 即使給了 --udid 也整段跳過（含查詢） ----
: > "$XCRUN_LOG"
out3="$(SIMLOCK_KEEP_UI=1 XCRUN_MODE=ok bash "$lock_sh" --dir "$work/l3" --udid UDID-3 -- echo ran3 2>&1)"; rc=$?
rc_is '③ SIMLOCK_KEEP_UI=1 → exit 0' 0 "$rc" "$out3"
has   '③ 命令有執行' "$out3" 'ran3'
hasnt '③ 不印已調整' "$out3" '已將'
if [ -s "$XCRUN_LOG" ]; then echo "✗ ③ SIMLOCK_KEEP_UI=1 不應呼叫 xcrun（連查詢都不該）" >&2; cat "$XCRUN_LOG" >&2; fail=1; else echo "✓ ③ SIMLOCK_KEEP_UI=1 整段跳過、不呼叫 xcrun"; fi

# ---- ④ 查詢失敗（xcrun 查不到目前值）→ 不設定、不復原、印警告、命令照跑（不擋鎖） ----
out4="$(run "$work/l4" queryfail --udid UDID-4 -- echo ran4)"; rc=$?
rc_is '④ 查詢失敗仍 exit 0（不擋命令）' 0 "$rc" "$out4"
has   '④ 命令有執行' "$out4" 'ran4'
has   '④ 印讀不到目前值的警告' "$out4" '讀不到目前字級／外觀'
hasnt '④ 不印已調整' "$out4" '已將'
hasnt '④ 不印已復原' "$out4" '已復原'
log4="$(cat "$XCRUN_LOG")"
if printf '%s' "$log4" | grep -qF 'set UDID-4'; then echo "✗ ④ 查詢失敗卻仍呼叫了 set（應該完全不設定）" >&2; printf '%s\n' "$log4" >&2; fail=1; else echo "✓ ④ 查詢失敗不呼叫任何 set"; fi

# ---- ⑤ 設定失敗（xcrun set 失敗）→ 印警告、命令照跑、不呼叫復原（沒有真的改過） ----
out5="$(run "$work/l5" setfail --udid UDID-5 -- echo ran5)"; rc=$?
rc_is '⑤ 設定失敗仍 exit 0（不擋命令）' 0 "$rc" "$out5"
has   '⑤ 命令有執行' "$out5" 'ran5'
has   '⑤ 印設定失敗警告' "$out5" '設定字級／外觀失敗'
hasnt '⑤ 不印已復原（沒有真的改過，沒有東西要復原）' "$out5" '已復原'
log5="$(cat "$XCRUN_LOG")"
if [ "$(printf '%s\n' "$log5" | grep -cF 'set UDID-5')" -eq 1 ]; then echo "✓ ⑤ 只嘗試設定一次（appearance 那個 set 因 && 短路沒被呼叫），沒有復原呼叫"; else echo "✗ ⑤ set 呼叫次數不對" >&2; printf '%s\n' "$log5" >&2; fail=1; fi

# ---- ⑥ 命令本身失敗（exit 非 0）→ 仍要復原（EXIT trap 涵蓋非 0 退出） ----
out6="$(run "$work/l6" ok --udid UDID-6 -- sh -c 'exit 7')"; rc=$?
rc_is '⑥ 命令 exit 7 → 包裝也 exit 7' 7 "$rc" "$out6"
has   '⑥ 命令失敗仍印已復原' "$out6" '已復原 UDID-6 字級／外觀'

# ---- 命令型負控：拿掉 apply_sim_ui／restore_sim_ui 呼叫點 → ① 的 xcrun 呼叫應歸零 ----
mut="$work/simulator-lock.no-ui.sh"
awk '!/^apply_sim_ui$/ && !/^release\(\) \{ restore_sim_ui;/ { print; next } /^release\(\) \{ restore_sim_ui;/ { print "release() { if read_holder && [ \"$h_pid\" = \"$$\" ]; then rm -rf \"$lock\"; fi; }" }' "$lock_sh" > "$mut"
if grep -q '^apply_sim_ui$' "$mut" || grep -q 'restore_sim_ui;' "$mut"; then
  echo "✗ mutant 仍含 apply_sim_ui／restore_sim_ui 呼叫（awk 拿掉失敗，負控本身無效）" >&2; fail=1
else
  echo "✓ mutant 已拿掉 apply_sim_ui／restore_sim_ui 呼叫點"
fi
: > "$XCRUN_LOG"
outm="$(XCRUN_MODE=ok bash "$mut" --dir "$work/lm" --udid UDID-M -- echo ranm 2>&1)"; rcm=$?
if [ "$rcm" -eq 0 ] && [ ! -s "$XCRUN_LOG" ]; then
  echo "✓ mutant：拿掉呼叫點後給 --udid 也不再碰 xcrun（證明 ① 的行為確實來自 apply_sim_ui／restore_sim_ui）"
else
  echo "✗ mutant 應 exit 0 且不呼叫 xcrun（實得 exit ${rcm}）" >&2; cat "$XCRUN_LOG" >&2; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ simulator-lock 自測通過"
fi
exit "$fail"
