#!/bin/bash
# Supabase 本機容器序列化 lock（LS-70）：把任意命令包在一把跨 worktree 的 lock 內執行，讓 `supabase db reset`
# 與 `supabase/tests/run.sh` 不再互踩。來源：2026-08-25 LS-57／LS-66 兩個 ios-dev 在各自 worktree 同時 reset
# 同一個本機容器（同 project_id／同 port）→ rc=137、"container is not running"、migration 忽有忽無。
#
# 用法：
#   supabase-lock.sh [--timeout <秒>] -- <命令…>   取得 lock 後在前景執行命令，回傳命令的 exit code
#   supabase-lock.sh --status                      印持有者一行（free／held pid=… ⚠ stale）＋殘留 tomb 每個一行（⚠ tomb …），exit 0
#   supabase-lock.sh --held                        本程序是否已在 lock 內（holder pid 為本程序祖先）：exit 0＝是、1＝否
#   supabase-lock.sh --path                        印 lock 目錄路徑
# 環境變數：SUPABASE_LOCK_TIMEOUT 等待逾時秒（預設 900＝15 分鐘）；SUPABASE_LOCK_POLL 輪詢秒（預設 1，可小數，下限 0.2）；
#   SUPABASE_LOCK_DIR lock 目錄（預設 /tmp/supabase-lock-<project_id>；自測用）。
#
# 機制（macOS 沒有 flock、內建 bash 3.2；macOS／Linux 皆可跑）：
#   - lock＝一個目錄：`mkdir` 在兩平台都是原子的，成功＝取得。目錄內 holder 檔記 pid／started／host／worktree／
#     branch／cmd（key=value 一行一項），等待訊息與巡檢（scripts/ops/patrol.sh）讀它顯示持有者。
#     holder 的內容（worktree／branch／cmd）在等待迴圈**之前**算好，mkdir 成功後只剩一次 printf＋mv（毫秒級空窗）；
#     暫存檔 `holder.<pid>.tmp` 以 pid 唯一化——兩個都以為自己取得的程序不會互相認領對方的暫存檔（PR #122 R2 F1）；
#     holder 寫不進去就把自己剛建的空目錄 rmdir、exit 2——不帶匿名鎖執行（R1 m1）。
#   - 路徑以 supabase/config.toml 的 project_id 為鍵、放 /tmp：所有 worktree 共用同一個容器就共用同一把鎖
#     （不用 git-common-dir——兩個 clone 也是同一個容器）。
#   - 等待：每 POLL 秒重試 mkdir；第一次與之後每 30 秒印一次「等待中＋持有者」；超過 TIMEOUT 秒 fail loud（exit 124）。
#   - 死鎖回收：holder 的 pid 不存在（`ps -p`；不比 host——/tmp 本來就不跨主機，macOS hostname 又會飄，PR #122 R1 m4），
#     或目錄建立 30 秒後仍沒有 holder 檔（持有者在寫檔前就死了）→ 先 `mv` 到唯一的 tomb 名再處理（mv 目錄是原子的，
#     多個等待者只有一個成功）。mv 後核對 tomb：holder 與剛才看到的死鎖不符（別人已回收並重新取得），或 tomb 沒有
#     holder 且建立未滿 30 秒（＝別人剛 mkdir、holder 還沒落地的活鎖，PR #122 R1 M1），都搬回原位、不刪；
#     只有「同一把死鎖」或「無 holder 且已逾 30 秒」才 rm。
#   - 重入：holder pid 是本程序的祖先（`ps -o ppid=` 往上走）→ 直接 exec 命令，不等自己；兩條路徑（取得／重入）都
#     export SUPABASE_LOCK_HELD=<lock 路徑>（PR #122 R1 m2）。判定只看祖先關係、不信環境變數——殘留或假造的
#     `SUPABASE_LOCK_HELD` 繞不過鎖；run.sh 也以 `--held` 問本腳本、不自己讀變數（R1 m3）。
#   - 命令在前景執行（Ctrl-C 走 process group 自然到命令）；本腳本收到 INT／TERM／HUP 時等命令結束才釋放；
#     只在 holder pid＝自己時才刪 lock（不刪別人的）。
# 已知限制：
#   - 持有者被 SIGKILL 而其子命令仍在跑（孤兒 `supabase db reset`）時，等待者會把鎖當死鎖回收——pid 是
#     「有人在用」唯一的代理；SIGKILL 不常見，出事看 docker 狀態。
#   - pid 重用（死鎖的 pid 被新程序拿走）會讓死鎖看起來活著，等待者等到逾時；逾時訊息印持有者資訊，
#     確認後人工 `rm -rf <lock 目錄>`。
#   - 搬回誤搬的活鎖用 rename(2)（perl；`mv(1) 目錄 既有目錄` 會塞進去並回 0，先 test 再 mv 又不是原子的——R2 F3）：
#     目標不存在→成功；目標是第三者剛 mkdir 且已寫 holder 的非空目錄→ENOTEMPTY 失敗，tomb 保留在原地供查證並大聲印，
#     `--status`／巡檢列出殘留 tomb（R2 F2），被搬走的持有者接著 holder 寫入失敗、走 m1 的 exit 2；目標是第三者剛
#     mkdir、holder 尚未落地的**空**目錄→POSIX 允許 rename 取代空目錄，第三者的 holder 會寫進搬回的目錄——需要三個
#     程序在同一毫秒內交錯，機率極低；屆時後 mv 的 holder 生效、另一個 release 時 pid 不符不會誤刪，但兩者可能同時執行。
# exit：命令的 exit code；124＝等待逾時；2＝參數／環境／holder 寫入錯誤。
set -uo pipefail

usage() {
  echo "用法：supabase-lock.sh [--timeout <秒>] -- <命令…>｜--status｜--held｜--path（說明見檔頭註解）"
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
timeout=${SUPABASE_LOCK_TIMEOUT:-900}
poll=${SUPABASE_LOCK_POLL:-1}
mode=run
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)
      [ -n "${2:-}" ] || { echo "✗ supabase-lock：--timeout 缺值" >&2; exit 2; }
      timeout=$2; shift 2 ;;
    --status) mode=status; shift ;;
    --held) mode=held; shift ;;
    --path) mode=path; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "✗ supabase-lock：未知參數 $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done
case "$timeout" in ''|*[!0-9]*) echo "✗ supabase-lock：timeout 須為整數秒（得到「${timeout}」）" >&2; exit 2 ;; esac
case "$poll" in ''|.|*[!0-9.]*|*.*.*) echo "✗ supabase-lock：SUPABASE_LOCK_POLL 須為數字秒（得到「${poll}」）" >&2; exit 2 ;; esac
# PR #122 R1 i4：0 會變 busy-spin 最長 15 分鐘——下限 0.2 秒
awk -v p="$poll" 'BEGIN { exit !(p + 0 >= 0.2) }' || { echo "✗ supabase-lock：SUPABASE_LOCK_POLL 下限 0.2 秒（得到「${poll}」）" >&2; exit 2; }

if [ -n "${SUPABASE_LOCK_DIR:-}" ]; then
  lock=$SUPABASE_LOCK_DIR
else
  proj=$(sed -nE 's/^project_id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$root/supabase/config.toml" 2>/dev/null | head -1)
  if [ -z "$proj" ]; then
    echo "✗ supabase-lock：讀不到 ${root}/supabase/config.toml 的 project_id（lock 以它為鍵；自測請設 SUPABASE_LOCK_DIR）" >&2
    exit 2
  fi
  lock="/tmp/supabase-lock-${proj}"
fi

alive() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; ps -p "$1" -o pid= >/dev/null 2>&1; }
is_ancestor() {   # $1 是否為本程序的祖先（含自己）；ps -o ppid= 在 macOS／Linux 都有
  local p=$$ n=0
  while [ "$n" -lt 64 ]; do
    [ "$p" = "$1" ] && return 0
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    case "$p" in ''|*[!0-9]*|0|1) return 1 ;; esac
    n=$((n + 1))
  done
  return 1
}
read_holder() {   # 設定 h_pid h_started h_host h_worktree h_branch h_cmd；沒有 holder 檔回 1
  h_pid=; h_started=; h_host=; h_worktree=; h_branch=; h_cmd=
  [ -f "$lock/holder" ] || return 1
  local k v
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      pid) h_pid=$v ;; started) h_started=$v ;; host) h_host=$v ;;
      worktree) h_worktree=$v ;; branch) h_branch=$v ;; cmd) h_cmd=$v ;;
    esac
  done < "$lock/holder"
  return 0
}
age_of() { local t; t=$(date -r "$1" +%s 2>/dev/null) || t=$(date +%s); echo $(( $(date +%s) - t )); }   # 目錄 mtime 距今秒數
holder_line() {   # 一行人類可讀的持有者描述（--status／等待訊息／巡檢共用）
  local s age=
  if read_holder; then
    case "$h_started" in ''|*[!0-9]*) ;; *) age="$(( ($(date +%s) - h_started) / 60 ))m" ;; esac
    s="held pid=${h_pid:-?}${age:+ since=${age}} worktree=${h_worktree:-?} branch=${h_branch:-?} cmd=${h_cmd:-?}"
    alive "$h_pid" || s="${s} ⚠ stale：持有者 pid 不存在（下次取鎖時自動回收）"
    printf '%s' "$s"
  elif [ -d "$lock" ]; then
    printf 'held（holder 尚未寫入，lock 建立於 %ss 前）' "$(age_of "$lock")"
  else
    printf 'free'
  fi
}

tomb_lines() {   # 殘留 tomb（搬回失敗留下的）每個一行，沒有就不印（R2 F2）——是「上次回收異常」唯一的持久證據
  local t tp
  for t in "${lock}".stale.*; do
    [ -d "$t" ] || continue
    tp=$(sed -n 's/^pid=//p' "$t/holder" 2>/dev/null)
    printf '⚠ tomb %s age=%ss holder_pid=%s（上次回收異常的殘留：確認 docker 無重疊執行後 rm -rf）\n' "$(basename "$t")" "$(age_of "$t")" "${tp:-none}"
  done
}

case "$mode" in
  path) printf '%s\n' "$lock"; exit 0 ;;
  status) printf '%s\n' "$(holder_line)"; tomb_lines; exit 0 ;;
  held) if read_holder && is_ancestor "$h_pid"; then exit 0; else exit 1; fi ;;
esac
[ $# -gt 0 ] || { echo "✗ supabase-lock：缺命令" >&2; usage >&2; exit 2; }

# 重入：持有者是本程序的祖先 → 直接執行（run.sh 經 lock 重跑自己時、或使用者已手動包了一層）。
# 這條也要 export：否則子程序看不到變數、run.sh 一類的包裝又會 exec 回來（PR #122 R1 m2 實測無窮迴圈）。
if read_holder && is_ancestor "$h_pid"; then
  export SUPABASE_LOCK_HELD=$lock
  echo "→ supabase-lock：已在 lock 內（持有者 pid ${h_pid}），直接執行" >&2
  exec "$@"
fi

is_stale() {   # 0＝這把鎖是死的（pid 不存在、或建好 30s 仍沒 holder）
  if read_holder; then
    alive "$h_pid" && return 1
    return 0
  fi
  [ -d "$lock" ] || return 1
  [ "$(age_of "$lock")" -gt 30 ]
}
restore() {   # 以 rename(2) 原子搬回誤搬的活鎖（R2 F3）：目標已是非空目錄就失敗——tomb 留在原地並大聲說；mv(1) 會塞進去、不能用
  if command -v perl >/dev/null 2>&1 && perl -e 'rename $ARGV[0], $ARGV[1] or exit 1' "$1" "$lock" 2>/dev/null; then return 0; fi
  echo "⚠ supabase-lock：搬回誤搬的活鎖失敗（${lock} 已被另一程序建立，或無 perl）——${1} 內的持有者與新持有者可能同時執行；tomb 保留供查證（--status／巡檢會列出），請檢查 docker 狀態" >&2
  return 1
}
reclaim() {   # 0＝已回收／已讓出（呼叫端立刻重試 mkdir）；1＝回收不了（lock 仍在但搬不動）
  local dead_pid=$h_pid dead_started=$h_started dead_wt=$h_worktree dead_cmd=$h_cmd
  local tomb="${lock}.stale.$$.$RANDOM" p= s=
  if ! mv "$lock" "$tomb" 2>/dev/null; then
    [ -d "$lock" ] && return 1
    return 0
  fi
  # 搬到的是不是剛才判定的那把死鎖？（PR #122 R1 M1：mv 之前別人可能已回收並重新 mkdir）
  if [ -f "$tomb/holder" ]; then
    p=$(sed -n 's/^pid=//p' "$tomb/holder"); s=$(sed -n 's/^started=//p' "$tomb/holder")
    if [ "$p" != "$dead_pid" ] || [ "$s" != "$dead_started" ]; then restore "$tomb"; return 0; fi
  elif [ "$(age_of "$tomb")" -le 30 ]; then
    # 沒有 holder 但很新＝別人剛取得、holder 還沒落地的活鎖——不是死鎖，搬回去
    restore "$tomb"; return 0
  fi
  rm -rf "$tomb"
  echo "⚠ supabase-lock：回收死鎖（持有者 pid ${dead_pid:-?} 已不存在；worktree ${dead_wt:-?}，cmd ${dead_cmd:-?}）" >&2
  return 0
}

# holder 內容先算好（PR #122 R1 M1：git 兩次 fork 約 60–130ms，不能落在 mkdir 之後）
host=$(hostname 2>/dev/null || echo unknown)
wt=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
br=$(git symbolic-ref --short -q HEAD 2>/dev/null || echo '-')
cmd_str=$(printf '%s' "$*" | tr '\n' ' ')

started=$(date +%s); announced=0; last_msg=0
while ! mkdir "$lock" 2>/dev/null; do
  waited=$(( $(date +%s) - started ))
  if [ "$waited" -ge "$timeout" ]; then
    echo "✗ supabase-lock：等待 ${timeout}s 逾時，放棄。持有者：$(holder_line)" >&2
    echo "  持有者若真的卡死（pid 仍在但沒在動），確認後 rm -rf ${lock} 再重跑。" >&2
    exit 124
  fi
  if is_stale; then
    reclaim && continue
  fi
  if [ "$announced" -eq 0 ] || [ $((waited - last_msg)) -ge 30 ]; then
    echo "→ supabase-lock：等待中（${waited}s／上限 ${timeout}s）——持有者：$(holder_line)" >&2
    announced=1; last_msg=$waited
  fi
  sleep "$poll"
done

# 取得了：一次 printf＋一次 mv 寫 holder；暫存檔名帶 pid（R2 F1：固定名會讓兩個寫入者互相認領對方的暫存檔）；失敗就
# 不帶匿名鎖執行（R1 m1）。只 rmdir（非遞迴）：自己剛 mkdir 的空目錄才刪得掉，若目錄已被搬走、$lock 現在是別人的
# （裡面有東西），rmdir 失敗、不動它。
if ! printf 'pid=%s\nstarted=%s\nhost=%s\nworktree=%s\nbranch=%s\ncmd=%s\n' "$$" "$(date +%s)" "$host" "$wt" "$br" "$cmd_str" > "$lock/holder.$$.tmp" 2>/dev/null \
   || ! mv "$lock/holder.$$.tmp" "$lock/holder" 2>/dev/null; then
  echo "✗ supabase-lock：holder 寫入失敗（${lock}/holder：被其他等待者誤搬——重試即可；或目錄被搬走／磁碟滿）——不帶匿名鎖執行，放棄。" >&2
  rm -f "$lock/holder.$$.tmp" 2>/dev/null; rmdir "$lock" 2>/dev/null
  exit 2
fi

release() { if read_holder && [ "$h_pid" = "$$" ]; then rm -rf "$lock"; fi; }
trap release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
export SUPABASE_LOCK_HELD=$lock
[ "$announced" -eq 1 ] && echo "→ supabase-lock：取得 lock（等了 $(( $(date +%s) - started ))s）" >&2

"$@"
rc=$?
exit "$rc"
