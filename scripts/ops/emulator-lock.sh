#!/bin/bash
# emulator-lock.sh — 以 adb serial 為鍵的 mkdir 原子鎖（LS-477，Android 前置 A3；iOS 對應物＝simulator-lock.sh，鍵＝UDID）。
#
# 把任意命令包在一把鎖內執行：兩個 agent／worktree 同時對同一台 emulator 跑 connected test 或 UI 操作會互踩
# （LS-83 在 iOS 上的同型事故），所以操作某台 emulator 的整段指令都應該包進來。演算法最小複製自
# simulator-lock.sh／supabase-lock.sh（mkdir 原子性、holder 檔記 pid、死鎖以 mv 先搬走再核對避免誤殺剛重新取得的活鎖、
# INT／TERM／HUP 顯式 trap 成 exit 才會觸發 EXIT 釋放）；拿掉的部分：simctl ui 字級調整（Android 無對應）、
# `--dir` 任意路徑（見下「鎖目錄」）。
#
# 用法：
#   emulator-lock.sh --serial <serial> [--timeout <秒>] -- <命令…>   取鎖 → 跑命令 → 釋放；exit＝命令的 exit code
#   emulator-lock.sh --status --serial <serial>                       只印狀態，不取鎖，exit 0
# `<serial>` 是 adb serial（`emulator-5554`）；也可用任意鍵名（detect-emulator.sh 用 `alloc` 序列化「挑 port＋起機」）。
# 只允許 [A-Za-z0-9._:-]（鎖目錄名的一部分，不能夾路徑分隔符）。
#
# 鎖目錄：`${EMULATOR_LOCK_ROOT:-/tmp}/emulator-lock-<serial>`。刻意不提供 --dir：simulator-lock.sh 的 LS-443 事故
# （釋放段 `rm -rf "$lock"`，--dir 被指到 worktree，連刪兩次）的教訓——這裡鎖目錄只能由「根目錄＋serial」組出，
# 每處 `rm -rf` 前再驗一次 basename 以 `emulator-lock-` 開頭、直屬 EMULATOR_LOCK_ROOT、且不含 `.git`（TOCTOU：呼叫中途被換成 symlink）。
# EMULATOR_LOCK_ROOT 只給自測指到 mktemp -d；它自己也必須是已存在的絕對路徑目錄。
#
# 狀態（--status 與等待逾時訊息共用）：`free`｜`held pid=<pid> since=<秒>s`｜`held pid=<pid> since=<秒>s ⚠ stale：持有者 pid 不存在
# （下次取鎖時自動回收）`｜`held（holder 尚未寫入…）`。patrol.sh 的「Booted emulator」段用 `--status` 判「鎖中——勿關」。
# 環境變數：EMULATOR_LOCK_POLL 輪詢秒（預設 1，下限 0.2）。
# exit：命令的 exit code；124＝等待逾時（預設 900 秒，印持有者）；2＝參數／holder 寫入錯誤；--status 恆 0。
# 已知限制同 simulator-lock.sh：pid 重用、持有者被 SIGKILL 而子命令仍在跑。
# 自測：scripts/ops/emulator-lock.test.sh
set -uo pipefail

usage() { echo "用法：emulator-lock.sh --serial <serial> [--timeout <秒>] -- <命令…>｜emulator-lock.sh --status --serial <serial>" >&2; }

timeout=900
poll=${EMULATOR_LOCK_POLL:-1}
serial=
status_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --serial) [ -n "${2:-}" ] || { echo "✗ emulator-lock：--serial 缺值" >&2; exit 2; }; serial=$2; shift 2 ;;
    --timeout) [ -n "${2:-}" ] || { echo "✗ emulator-lock：--timeout 缺值" >&2; exit 2; }; timeout=$2; shift 2 ;;
    --status) status_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "✗ emulator-lock：未知參數 $1" >&2; usage; exit 2 ;;
  esac
done
[ -n "$serial" ] || { echo "✗ emulator-lock：缺 --serial" >&2; usage; exit 2; }
case "$serial" in *[!A-Za-z0-9._:-]*) echo "✗ emulator-lock：--serial 只允許 [A-Za-z0-9._:-]（得到「${serial}」）" >&2; exit 2 ;; esac
case "$timeout" in ''|*[!0-9]*) echo "✗ emulator-lock：timeout 須為整數秒（得到「${timeout}」）" >&2; exit 2 ;; esac
case "$poll" in ''|.|*[!0-9.]*|*.*.*) echo "✗ emulator-lock：EMULATOR_LOCK_POLL 須為數字秒（得到「${poll}」）" >&2; exit 2 ;; esac
awk -v p="$poll" 'BEGIN { exit !(p + 0 >= 0.2) }' || { echo "✗ emulator-lock：EMULATOR_LOCK_POLL 下限 0.2 秒（得到「${poll}」）" >&2; exit 2; }

lock_root=${EMULATOR_LOCK_ROOT:-/tmp}
case "$lock_root" in /*) ;; *) echo "✗ emulator-lock：EMULATOR_LOCK_ROOT 須為絕對路徑（得到「${lock_root}」）" >&2; exit 2 ;; esac
[ -d "$lock_root" ] || { echo "✗ emulator-lock：EMULATOR_LOCK_ROOT 不是目錄（${lock_root}）" >&2; exit 2; }
lock_root=${lock_root%/}
lock="${lock_root}/emulator-lock-${serial}"

alive() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; ps -p "$1" -o pid= >/dev/null 2>&1; }
age_of() { local t; t=$(date -r "$1" +%s 2>/dev/null) || t=$(date +%s); echo $(( $(date +%s) - t )); }
read_holder() {   # 設定 h_pid h_started；沒有 holder 檔回 1
  h_pid=; h_started=
  [ -f "$lock/holder" ] || return 1
  local k v
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in pid) h_pid=$v ;; started) h_started=$v ;; esac
  done < "$lock/holder"
  return 0
}
holder_line() {
  local s age=
  if read_holder; then
    case "$h_started" in ''|*[!0-9]*) ;; *) age="$(( $(date +%s) - h_started ))s" ;; esac
    s="held pid=${h_pid:-?}${age:+ since=${age}}"
    alive "$h_pid" || s="${s} ⚠ stale：持有者 pid 不存在（下次取鎖時自動回收）"
    printf '%s' "$s"
  elif [ -d "$lock" ]; then
    printf 'held（holder 尚未寫入，lock 建立於 %ss 前）' "$(age_of "$lock")"
  else
    printf 'free'
  fi
}

if [ "$status_only" -eq 1 ]; then holder_line; echo; exit 0; fi

[ $# -gt 0 ] || { echo "✗ emulator-lock：缺命令" >&2; usage; exit 2; }

# rm -rf 前的最後一道護欄：basename 以 emulator-lock- 開頭、直屬 lock_root、不含 .git、不是 symlink
safe_to_remove() {
  local d=$1
  [ -d "$d" ] && [ ! -L "$d" ] || return 1
  [ "${d%/*}" = "$lock_root" ] || return 1
  case "${d##*/}" in emulator-lock-*) ;; *) return 1 ;; esac
  [ ! -e "$d/.git" ] || return 1
  return 0
}

is_stale() {   # 0＝這把鎖是死的（pid 不存在、或建好 30s 仍沒 holder）
  if read_holder; then
    alive "$h_pid" && return 1
    return 0
  fi
  [ -d "$lock" ] || return 1
  [ "$(age_of "$lock")" -gt 30 ]
}
restore() {   # 以 rename(2) 原子搬回誤搬的活鎖（同 supabase-lock.sh PR #122 R2 F3）
  if command -v perl >/dev/null 2>&1 && perl -e 'rename $ARGV[0], $ARGV[1] or exit 1' "$1" "$lock" 2>/dev/null; then return 0; fi
  echo "⚠ emulator-lock：搬回誤搬的活鎖失敗（${lock} 已被另一程序建立，或無 perl）" >&2
  return 1
}
reclaim() {   # 0＝已回收／已讓出（呼叫端立刻重試 mkdir）；1＝回收不了
  local dead_pid=$h_pid dead_started=$h_started
  local tomb="${lock}.stale.$$.$RANDOM" p= s=
  if ! mv "$lock" "$tomb" 2>/dev/null; then
    [ -d "$lock" ] && return 1
    return 0
  fi
  if [ -f "$tomb/holder" ]; then
    p=$(sed -n 's/^pid=//p' "$tomb/holder"); s=$(sed -n 's/^started=//p' "$tomb/holder")
    if [ "$p" != "$dead_pid" ] || [ "$s" != "$dead_started" ]; then restore "$tomb"; return 0; fi
  elif [ "$(age_of "$tomb")" -le 30 ]; then
    restore "$tomb"; return 0
  fi
  # tomb 的 basename 是 emulator-lock-<serial>.stale.*，同樣以 emulator-lock- 開頭、直屬 lock_root
  if safe_to_remove "$tomb"; then rm -rf "$tomb"; else echo "⚠ emulator-lock：${tomb} 未通過刪除護欄，未刪除（請人工檢查）" >&2; return 1; fi
  echo "⚠ emulator-lock：回收死鎖（持有者 pid ${dead_pid:-?} 已不存在）" >&2
  return 0
}

started=$(date +%s); announced=0; last_msg=0
while ! mkdir "$lock" 2>/dev/null; do
  waited=$(( $(date +%s) - started ))
  if [ "$waited" -ge "$timeout" ]; then
    echo "✗ emulator-lock：等待 ${timeout}s 逾時，放棄。持有者：$(holder_line)" >&2
    exit 124
  fi
  if is_stale; then
    reclaim && continue
  fi
  if [ "$announced" -eq 0 ] || [ $((waited - last_msg)) -ge 30 ]; then
    echo "→ emulator-lock：等待中（${waited}s／上限 ${timeout}s）——持有者：$(holder_line)" >&2
    announced=1; last_msg=$waited
  fi
  sleep "$poll"
done

if ! printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" > "$lock/holder.$$.tmp" 2>/dev/null \
   || ! mv "$lock/holder.$$.tmp" "$lock/holder" 2>/dev/null; then
  echo "✗ emulator-lock：holder 寫入失敗（被其他等待者誤搬／目錄被搬走／磁碟滿）——不帶匿名鎖執行，放棄。" >&2
  rm -f "$lock/holder.$$.tmp" 2>/dev/null; rmdir "$lock" 2>/dev/null
  exit 2
fi

release() {
  if read_holder && [ "$h_pid" = "$$" ]; then
    if safe_to_remove "$lock"; then rm -rf "$lock"; else echo "⚠ emulator-lock：${lock} 未通過刪除護欄，未刪除（鎖目錄殘留，請人工檢查）" >&2; fi
  fi
}
trap release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
[ "$announced" -eq 1 ] && echo "→ emulator-lock：取得 lock（等了 $(( $(date +%s) - started ))s）" >&2

"$@"
rc=$?
exit "$rc"
