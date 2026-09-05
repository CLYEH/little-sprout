#!/bin/bash
# 通用 mkdir 原子 lock（LS-83）：把任意命令包在一把 lock 內執行。detect-simulator.sh 退回共用第一台模擬器時
# 用它序列化（鍵＝UDID）。演算法最小複製自 scripts/ops/supabase-lock.sh（LS-70：mkdir 原子性、holder 檔記
# pid、死鎖以 mv 先搬走再核對避免誤殺剛重新取得的活鎖、signal 處理）——沒有改成兩者共用同一支腳本，是因為
# supabase-lock.sh 綁 supabase/config.toml 的 project_id 且已有完整測試覆蓋，直接動它風險與本票 size 不成比例；
# 這裡把「鎖目錄」改成明講的 --dir、拿掉 --status／--held／--path／reentrant（呼叫端固定只包一次、不會巢狀呼叫
# 自己），其餘沿用同一套邏輯。已知限制同 supabase-lock.sh 檔頭注解（pid 重用、持有者被 SIGKILL 而子命令仍在跑），
# 不重複贅述。
#
# 用法：simulator-lock.sh --dir <路徑> [--timeout <秒>] [--udid <udid>] -- <命令…>
# 環境變數：SIMULATOR_LOCK_POLL 輪詢秒（預設 1，下限 0.2，同 supabase-lock.sh 理由：0 會 busy-spin）；
#   SIMLOCK_KEEP_UI=1 跳過下方 --udid 的字級／外觀調整（見下）
# exit：命令的 exit code；124＝等待逾時；2＝參數／holder 寫入錯誤
#
# LS-207（c18ef27f）：`--udid <udid>`（選填，呼叫端明確傳入，不從 --dir 路徑猜——自測與非標準 --dir 覆寫
# 不會被誤觸）：取得鎖、跑命令前用 `xcrun simctl ui <udid> content_size` / `appearance`（無參數＝查詢）先讀出
# 目前值存起來，再設成 `content_size medium`／`appearance light`（QA／merge-reviewer 多步驟操作要看得清楚且
# 一致的畫面，不受呼叫端當下字級／外觀影響）；命令結束、釋放鎖之前用存起來的原值復原（查詢失敗就不設也不
# 復原，印警告，不擋鎖本身——這是體驗改善，不是硬 gate）。`SIMLOCK_KEEP_UI=1` 整段跳過（含查詢），給不希望
# 動到模擬器 UI 狀態的呼叫端。
set -uo pipefail

usage() { echo "用法：simulator-lock.sh --dir <路徑> [--timeout <秒>] [--udid <udid>] -- <命令…>" >&2; }

timeout=900
poll=${SIMULATOR_LOCK_POLL:-1}
lock=
udid=
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      [ -n "${2:-}" ] || { echo "✗ simulator-lock：--dir 缺值" >&2; exit 2; }
      lock=$2; shift 2 ;;
    --timeout)
      [ -n "${2:-}" ] || { echo "✗ simulator-lock：--timeout 缺值" >&2; exit 2; }
      timeout=$2; shift 2 ;;
    --udid)
      [ -n "${2:-}" ] || { echo "✗ simulator-lock：--udid 缺值" >&2; exit 2; }
      udid=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "✗ simulator-lock：未知參數 $1" >&2; usage; exit 2 ;;
    *) break ;;
  esac
done
[ -n "$lock" ] || { echo "✗ simulator-lock：缺 --dir" >&2; usage; exit 2; }
case "$timeout" in ''|*[!0-9]*) echo "✗ simulator-lock：timeout 須為整數秒（得到「${timeout}」）" >&2; exit 2 ;; esac
case "$poll" in ''|.|*[!0-9.]*|*.*.*) echo "✗ simulator-lock：SIMULATOR_LOCK_POLL 須為數字秒（得到「${poll}」）" >&2; exit 2 ;; esac
awk -v p="$poll" 'BEGIN { exit !(p + 0 >= 0.2) }' || { echo "✗ simulator-lock：SIMULATOR_LOCK_POLL 下限 0.2 秒（得到「${poll}」）" >&2; exit 2; }
[ $# -gt 0 ] || { echo "✗ simulator-lock：缺命令" >&2; usage; exit 2; }

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
  echo "⚠ simulator-lock：搬回誤搬的活鎖失敗（${lock} 已被另一程序建立，或無 perl）" >&2
  return 1
}
reclaim() {   # 0＝已回收／已讓出（呼叫端立刻重試 mkdir）；1＝回收不了（lock 仍在但搬不動）
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
  rm -rf "$tomb"
  echo "⚠ simulator-lock：回收死鎖（持有者 pid ${dead_pid:-?} 已不存在）" >&2
  return 0
}

started=$(date +%s); announced=0; last_msg=0
while ! mkdir "$lock" 2>/dev/null; do
  waited=$(( $(date +%s) - started ))
  if [ "$waited" -ge "$timeout" ]; then
    echo "✗ simulator-lock：等待 ${timeout}s 逾時，放棄。持有者：$(holder_line)" >&2
    exit 124
  fi
  if is_stale; then
    reclaim && continue
  fi
  if [ "$announced" -eq 0 ] || [ $((waited - last_msg)) -ge 30 ]; then
    echo "→ simulator-lock：等待中（${waited}s／上限 ${timeout}s）——持有者：$(holder_line)" >&2
    announced=1; last_msg=$waited
  fi
  sleep "$poll"
done

if ! printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" > "$lock/holder.$$.tmp" 2>/dev/null \
   || ! mv "$lock/holder.$$.tmp" "$lock/holder" 2>/dev/null; then
  echo "✗ simulator-lock：holder 寫入失敗（被其他等待者誤搬／目錄被搬走／磁碟滿）——不帶匿名鎖執行，放棄。" >&2
  rm -f "$lock/holder.$$.tmp" 2>/dev/null; rmdir "$lock" 2>/dev/null
  exit 2
fi

# LS-207（c18ef27f）：--udid 給了才動；SIMLOCK_KEEP_UI=1 整段跳過。查不到目前值就不設也不復原（寧可不動，
# 不留下復原不了的殘留）；設定失敗只印警告、不擋命令執行——這是體驗改善，不是硬 gate。
ui_changed=0; ui_orig_content_size=; ui_orig_appearance=
apply_sim_ui() {
  [ -n "$udid" ] || return 0
  [ "${SIMLOCK_KEEP_UI:-}" = 1 ] && return 0
  ui_orig_content_size=$(xcrun simctl ui "$udid" content_size 2>/dev/null) || ui_orig_content_size=
  ui_orig_appearance=$(xcrun simctl ui "$udid" appearance 2>/dev/null) || ui_orig_appearance=
  if [ -z "$ui_orig_content_size" ] || [ -z "$ui_orig_appearance" ]; then
    echo "⚠ simulator-lock：讀不到目前字級／外觀（xcrun simctl ui ${udid} content_size／appearance 查詢失敗）——不調整、不復原" >&2
    return 0
  fi
  if xcrun simctl ui "$udid" content_size medium >/dev/null 2>&1 && xcrun simctl ui "$udid" appearance light >/dev/null 2>&1; then
    ui_changed=1
    echo "→ simulator-lock：已將 ${udid} 字級／外觀改為 content_size=medium appearance=light（原值 content_size=${ui_orig_content_size} appearance=${ui_orig_appearance}，釋放時復原）" >&2
  else
    echo "⚠ simulator-lock：設定字級／外觀失敗（xcrun simctl ui ${udid} …）——不擋鎖，照跑命令" >&2
  fi
}
restore_sim_ui() {
  [ "$ui_changed" -eq 1 ] || return 0
  xcrun simctl ui "$udid" content_size "$ui_orig_content_size" >/dev/null 2>&1
  xcrun simctl ui "$udid" appearance "$ui_orig_appearance" >/dev/null 2>&1
  echo "→ simulator-lock：已復原 ${udid} 字級／外觀（content_size=${ui_orig_content_size} appearance=${ui_orig_appearance}）" >&2
}

release() { restore_sim_ui; if read_holder && [ "$h_pid" = "$$" ]; then rm -rf "$lock"; fi; }
trap release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
[ "$announced" -eq 1 ] && echo "→ simulator-lock：取得 lock（等了 $(( $(date +%s) - started ))s）" >&2
apply_sim_ui

"$@"
rc=$?
exit "$rc"
