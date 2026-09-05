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
# 目前值存起來，再設成 `content_size large`／`appearance light`（QA／merge-reviewer 多步驟操作要看得清楚且
# 一致的畫面，不受呼叫端當下字級／外觀影響——`large` 是 iOS 系統預設字級，同時對齊 scripts/gates/tap-target-check.sh
# 訊息宣稱的「一般字級 content_size large 量測」，R1 誤設成 medium：該 gate 目前用 launch environment
# `UIPreferredContentSizeCategoryName` 覆寫、不吃系統設定，今天零影響，但字面上「large」與這裡的「medium」
# 互相矛盾，日後若量測改吃系統設定會靜默偏移，LS-167／LS-205 那類事故的同型風險，故統一成同一個值——動這兩支
# 檔任一邊的字級常數前，先看對方註解，見 merge-review R1 fd783f6c F5）；命令結束、釋放鎖之前用存起來的原值
# 復原。**LS-207 R2（fd783f6c F4）**：content_size／appearance 兩個 key 各自獨立記「有沒有改成功、原值是什麼」，
# 只要有一個設定成功就要負責復原那一個（不是全有全無——原本用 `&&` 短路，appearance 設定失敗會讓已經成功的
# content_size 永遠復原不到）；查詢結果若是 `unknown`／`unsupported`（`simctl ui` 合法回應，非查詢失敗）視同查
# 不到，不當「原值」存起來（否則復原時對模擬器下 `content_size unsupported` 這種不存在的值，安靜失敗）；復原
# 呼叫的 exit code 一定檢查，失敗大聲印 ⚠ 並點名 UDID，不再吞掉。查詢或設定失敗只印警告、不擋命令執行（體驗
# 改善不是硬 gate）。`SIMLOCK_KEEP_UI=1` 整段跳過（含查詢），給不希望動到模擬器 UI 狀態的呼叫端。
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

# LS-207（c18ef27f；R2 修 fd783f6c F4）：--udid 給了才動；SIMLOCK_KEEP_UI=1 整段跳過。content_size／appearance
# 兩個 key 各自獨立記「有沒有改成功、原值是什麼」——只要有一個設定成功就負責復原那一個，不是全有全無（R1 用
# `&&` 短路：appearance 設定失敗會讓已經成功套用的 content_size 永遠復原不到，模擬器卡在改過的狀態且沒有任何
# 輸出）。查詢結果是 `unknown`／`unsupported`（`simctl ui` 合法回應，不是查詢失敗）視同查不到、不當原值存起來
# （否則復原時對模擬器下 `content_size unsupported` 這種不存在的值，安靜失敗）。復原呼叫的 exit code 一定檢查，
# 失敗大聲印 ⚠ 並點名 UDID——原本用 `>/dev/null 2>&1` 吞掉，復原失敗跟復原成功長得一模一樣。
ui_content_changed=0; ui_appearance_changed=0; ui_orig_content_size=; ui_orig_appearance=
# 查詢＋設定＋記錄一個 key：$1=key（content_size｜appearance） $2=要設的值（large｜light）；
# 成功就把原值存進對應的全域變數、把對應的 *_changed 設成 1；查不到／unknown／unsupported／設定失敗都各自
# 印警告、那個 key 保持未變動——兩個 key 完全獨立，不因為另一個失敗就放棄這一個（F4：R1 用 && 短路兩者綁死）。
apply_one_ui_key() {
  local key=$1 want=$2 orig
  orig=$(xcrun simctl ui "$udid" "$key" 2>/dev/null) || orig=
  case "$orig" in
    ''|unknown|unsupported)
      echo "⚠ simulator-lock：讀不到 ${udid} 目前 ${key}（查詢失敗或回應 unknown／unsupported）——不調整、不復原" >&2
      return 0 ;;
  esac
  if xcrun simctl ui "$udid" "$key" "$want" >/dev/null 2>&1; then
    case "$key" in
      content_size) ui_orig_content_size=$orig; ui_content_changed=1 ;;
      appearance) ui_orig_appearance=$orig; ui_appearance_changed=1 ;;
    esac
  else
    echo "⚠ simulator-lock：設定 ${udid} ${key}=${want} 失敗（xcrun simctl ui …）——不擋鎖，照跑命令" >&2
  fi
}
apply_sim_ui() {
  [ -n "$udid" ] || return 0
  [ "${SIMLOCK_KEEP_UI:-}" = 1 ] && return 0
  apply_one_ui_key content_size large
  apply_one_ui_key appearance light
  if [ "$ui_content_changed" -eq 1 ] || [ "$ui_appearance_changed" -eq 1 ]; then
    echo "→ simulator-lock：已將 ${udid} 字級／外觀改為$([ "$ui_content_changed" -eq 1 ] && printf ' content_size=large')$([ "$ui_appearance_changed" -eq 1 ] && printf ' appearance=light')（釋放時復原）" >&2
  fi
}
restore_sim_ui() {
  if [ "$ui_content_changed" -eq 1 ]; then
    if xcrun simctl ui "$udid" content_size "$ui_orig_content_size" >/dev/null 2>&1; then
      echo "→ simulator-lock：已復原 ${udid} content_size=${ui_orig_content_size}" >&2
    else
      echo "⚠ simulator-lock：復原 ${udid} content_size=${ui_orig_content_size} 失敗——模擬器可能停留在 large，請手動檢查（xcrun simctl ui ${udid} content_size ${ui_orig_content_size}）" >&2
    fi
  fi
  if [ "$ui_appearance_changed" -eq 1 ]; then
    if xcrun simctl ui "$udid" appearance "$ui_orig_appearance" >/dev/null 2>&1; then
      echo "→ simulator-lock：已復原 ${udid} appearance=${ui_orig_appearance}" >&2
    else
      echo "⚠ simulator-lock：復原 ${udid} appearance=${ui_orig_appearance} 失敗——模擬器可能停留在 light，請手動檢查（xcrun simctl ui ${udid} appearance ${ui_orig_appearance}）" >&2
    fi
  fi
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
