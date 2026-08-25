#!/bin/bash
# Supabase 本機容器序列化 lock（LS-70）：把任意命令包在一把跨 worktree 的 lock 內執行，讓 `supabase db reset`
# 與 `supabase/tests/run.sh` 不再互踩。來源：2026-08-25 LS-57／LS-66 兩個 ios-dev 在各自 worktree 同時 reset
# 同一個本機容器（同 project_id／同 port）→ rc=137、"container is not running"、migration 忽有忽無。
#
# 用法：
#   supabase-lock.sh [--timeout <秒>] -- <命令…>   取得 lock 後在前景執行命令，回傳命令的 exit code
#   supabase-lock.sh --status                      印持有者一行（巡檢用：free／held pid=… ⚠ stale），exit 0
#   supabase-lock.sh --path                        印 lock 目錄路徑
# 環境變數：SUPABASE_LOCK_TIMEOUT 等待逾時秒（預設 900＝15 分鐘）；SUPABASE_LOCK_POLL 輪詢秒（預設 1，可小數）；
#   SUPABASE_LOCK_DIR lock 目錄（預設 /tmp/supabase-lock-<project_id>；自測用）。
#
# 機制（macOS 沒有 flock、內建 bash 3.2；macOS／Linux 皆可跑）：
#   - lock＝一個目錄：`mkdir` 在兩平台都是原子的，成功＝取得。目錄內 holder 檔記 pid／started／host／worktree／
#     branch／cmd（key=value 一行一項），等待訊息與巡檢（scripts/ops/patrol.sh）讀它顯示持有者。
#   - 路徑以 supabase/config.toml 的 project_id 為鍵、放 /tmp：所有 worktree 共用同一個容器就共用同一把鎖
#     （不用 git-common-dir——兩個 clone 也是同一個容器）。
#   - 等待：每 POLL 秒重試 mkdir；第一次與之後每 30 秒印一次「等待中＋持有者」；超過 TIMEOUT 秒 fail loud（exit 124）。
#   - 死鎖回收：holder 的 pid 不存在（`ps -p`），或目錄建立 30 秒後仍沒有 holder 檔（持有者在寫檔前就死了）→
#     先 `mv` 到唯一的 tomb 名再刪（mv 目錄是原子的，多個等待者只有一個成功）；mv 後核對 tomb 內的 holder 就是
#     剛才看到的那把死鎖，不是就搬回去——避免「別人已回收並重新取得」之後誤殺新鎖。
#   - 重入：取得後 export SUPABASE_LOCK_HELD=<lock 路徑>（run.sh 靠它決定要不要自己再包一層）；本腳本自己判斷
#     重入不信環境變數，而是看 holder pid 是不是本程序的祖先（`ps -o ppid=` 往上走）——殘留的環境變數繞不過鎖。
#   - 命令在前景執行（Ctrl-C 走 process group 自然到命令）；本腳本收到 INT／TERM／HUP 時等命令結束才釋放；
#     只在 holder pid＝自己時才刪 lock（不刪別人的）。
# 已知限制：
#   - 持有者被 SIGKILL 而其子命令仍在跑（孤兒 `supabase db reset`）時，等待者會把鎖當死鎖回收——pid 是
#     「有人在用」唯一的代理；SIGKILL 不常見，出事看 docker 狀態。
#   - pid 重用（死鎖的 pid 被新程序拿走）會讓死鎖看起來活著，等待者等到逾時；逾時訊息印持有者資訊，
#     確認後人工 `rm -rf <lock 目錄>`。
#   - 回收的競態縮到「tomb 核對不符、搬回去也失敗（第三者在同一瞬間 mkdir）」那一層——屆時兩個程序都以為
#     自己持有；巡檢／逾時訊息會露餡。
# exit：命令的 exit code；124＝等待逾時；2＝參數／環境錯誤。
set -uo pipefail

usage() {
  echo "用法：supabase-lock.sh [--timeout <秒>] -- <命令…>｜--status｜--path（說明見檔頭註解）"
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
    --path) mode=path; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "✗ supabase-lock：未知參數 $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done
case "$timeout" in ''|*[!0-9]*) echo "✗ supabase-lock：timeout 須為整數秒（得到「${timeout}」）" >&2; exit 2 ;; esac
case "$poll" in ''|.|*[!0-9.]*|*.*.*) echo "✗ supabase-lock：SUPABASE_LOCK_POLL 須為數字秒（得到「${poll}」）" >&2; exit 2 ;; esac

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

host=$(hostname 2>/dev/null || echo unknown)
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
dir_age() { local t; t=$(date -r "$lock" +%s 2>/dev/null) || t=$(date +%s); echo $(( $(date +%s) - t )); }
holder_line() {   # 一行人類可讀的持有者描述（--status／等待訊息／巡檢共用）
  local s age=
  if read_holder; then
    case "$h_started" in ''|*[!0-9]*) ;; *) age="$(( ($(date +%s) - h_started) / 60 ))m" ;; esac
    s="held pid=${h_pid:-?}${age:+ since=${age}} worktree=${h_worktree:-?} branch=${h_branch:-?} cmd=${h_cmd:-?}"
    if [ "$h_host" = "$host" ] && ! alive "$h_pid"; then s="${s} ⚠ stale：持有者 pid 不存在（下次取鎖時自動回收）"; fi
    printf '%s' "$s"
  elif [ -d "$lock" ]; then
    printf 'held（holder 尚未寫入，lock 建立於 %ss 前）' "$(dir_age)"
  else
    printf 'free'
  fi
}

case "$mode" in
  path) printf '%s\n' "$lock"; exit 0 ;;
  status) printf '%s\n' "$(holder_line)"; exit 0 ;;
esac
[ $# -gt 0 ] || { echo "✗ supabase-lock：缺命令" >&2; usage >&2; exit 2; }

# 重入：持有者是本程序的祖先 → 直接執行（run.sh 經 lock 重跑自己時、或使用者已手動包了一層）
if read_holder && is_ancestor "$h_pid"; then
  echo "→ supabase-lock：已在 lock 內（持有者 pid ${h_pid}），直接執行" >&2
  exec "$@"
fi

is_stale() {   # 0＝這把鎖是死的（pid 不存在、或建好 30s 仍沒 holder）
  if read_holder; then
    [ "$h_host" = "$host" ] || return 1
    alive "$h_pid" && return 1
    return 0
  fi
  [ -d "$lock" ] || return 1
  [ "$(dir_age)" -gt 30 ]
}
reclaim() {   # 0＝已回收（或別人回收了）→ 立刻重試 mkdir；1＝回收不了（lock 仍在）
  local dead_pid=$h_pid dead_started=$h_started dead_wt=$h_worktree dead_cmd=$h_cmd
  local tomb="${lock}.stale.$$.$RANDOM" p= s=
  if ! mv "$lock" "$tomb" 2>/dev/null; then
    [ -d "$lock" ] && return 1
    return 0
  fi
  if [ -f "$tomb/holder" ]; then
    p=$(sed -n 's/^pid=//p' "$tomb/holder"); s=$(sed -n 's/^started=//p' "$tomb/holder")
    if [ "$p" != "$dead_pid" ] || [ "$s" != "$dead_started" ]; then
      # 搬走的不是剛才那把死鎖（別人已回收並重新取得）——搬回去
      mv "$tomb" "$lock" 2>/dev/null || rm -rf "$tomb"
      return 0
    fi
  fi
  rm -rf "$tomb"
  echo "⚠ supabase-lock：回收死鎖（持有者 pid ${dead_pid:-?} 已不存在；worktree ${dead_wt:-?}，cmd ${dead_cmd:-?}）" >&2
  return 0
}

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

wt=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
br=$(git symbolic-ref --short -q HEAD 2>/dev/null || echo '-')
{
  echo "pid=$$"
  echo "started=$(date +%s)"
  echo "started_at=$(date '+%Y-%m-%d %H:%M:%S')"
  echo "host=${host}"
  echo "worktree=${wt}"
  echo "branch=${br}"
  echo "cmd=$(printf '%s' "$*" | tr '\n' ' ')"
} > "$lock/holder.tmp" && mv "$lock/holder.tmp" "$lock/holder"

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
