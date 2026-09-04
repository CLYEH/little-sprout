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
#   supabase-lock.sh --hold <label> [--max-minutes N]   QA 持有（LS-159）：取得 lock 後不執行命令，fork 守門子程序在背景持有
#                                                  N 分鐘（預設 30、上限 60），主程序印 `held pid=<守門 pid> label=… expires=hh:mm log=…` 後 exit 0
#   supabase-lock.sh --release                     釋放自己的 hold（持有者判定見下）：kill 守門＋刪 lock，印持有時長；非持有者 exit 2
# 環境變數：SUPABASE_LOCK_TIMEOUT 等待逾時秒（預設 900＝15 分鐘）；SUPABASE_LOCK_POLL 輪詢秒（預設 1，可小數，下限 0.2）；
#   SUPABASE_LOCK_DIR lock 目錄（預設 /tmp/supabase-lock-<project_id>；自測用）；
#   SUPABASE_LOCK_HOLD_TICK 守門心跳秒（預設 5，下限 0.2；自測用）；SUPABASE_LOCK_HOLD_SECONDS 覆寫 hold 到期秒數（自測用，取代 --max-minutes）。
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
#   - hold（LS-159；UI 驗收是分鐘級人機操作，包不進一條命令）：`--hold` 走同一條取得路徑（等待、死鎖回收都一樣），
#     mkdir 成功後 fork 守門子程序 `bash <本腳本> --hold-guard …`（內部模式；獨立程序才有自己的 pid——bash 3.2 沒有
#     BASHPID）。守門自己寫 holder（pid＝守門 pid，多 `cmd=hold:<label>`／`owner=<呼叫 --hold 的父 shell pid>`／
#     `expires_at`／`heartbeat`），主程序等 holder 落地即印一行 exit 0。守門 stdin／stdout 接 /dev/null、stderr 接
#     `<lock>.hold.log`——不繼承呼叫者的管線（否則 agent 的 Bash 工具會等到 hold 結束才返回）；nohup＋disown（macOS 沒有
#     setsid），HUP 忽略。守門每 TICK 秒把 heartbeat 重寫進 holder（先確認 holder pid 仍是自己）、到 `expires_at` 自動
#     `rm -rf`（仍只在 holder pid＝自己時）並印一行到 log。
#   - hold 的持有者判定 `hold_owner_ok`（--release／--held／`-- <命令>` 重入三處共用）：holder 的 `owner` pid 是本程序祖先
#     （同一個 shell session）**或** holder 的 `worktree` 與本程序 cwd 的 worktree 相同。守門 pid 本身不可能是任何呼叫者的
#     祖先（主程序退出後守門已被 reparent），所以不能只沿用 `--held` 的祖先判定；agent 的 Bash 工具每次呼叫都是新 shell、
#     owner 早已退出，實務上靠 worktree 那一條——QA 只在自己的 worktree 操作。
#   - hold 期間持有者自己的 `-- supabase db reset`／`run.sh` 走重入直接執行（PreToolUse H3 只認 wrapper 字面或 holder pid
#     是祖先，裸跑仍被擋、包了 wrapper 就要能直接過——否則 QA 會卡在自己的 hold 上）；其他 worktree 照常排隊、沿用
#     SUPABASE_LOCK_TIMEOUT（15 分鐘）——hold 上限 30 分鐘大於等待逾時是刻意的：等待者逾時 fail loud 印出持有者 label，
#     QA 該在 15 分鐘內完成互動段，否則拆段。
#   - `--release`：kill -TERM 守門並等它自己釋放（≤3s），沒退就 -KILL（被 SIGSTOP 的守門若日後恢復、會把 heartbeat 重寫進
#     別人的新 lock——先殺掉再刪）、holder pid 仍是那個守門才 rm -rf。守門被 -9：pid 不存在→既有死鎖回收涵蓋。
# 已知限制：
#   - hold 到期釋放不會中斷持有者正在跑的命令（例如 QA 的 reset 剛開始就到期）——之後別人的 reset 可能與之重疊；
#     hold_owner_ok 的 worktree 那一條讓「任何在同一 worktree 內跑的程序」都算持有者（QA worktree 只有 QA 在用時成立）。
#   - 持有者被 SIGKILL 而其子命令仍在跑（孤兒 `supabase db reset`）時，等待者會把鎖當死鎖回收——pid 是
#     「有人在用」唯一的代理；SIGKILL 不常見，出事看 docker 狀態。
#   - pid 重用（死鎖的 pid 被新程序拿走）會讓死鎖看起來活著，等待者等到逾時；逾時訊息印持有者資訊，
#     確認後人工 `rm -rf <lock 目錄>`。
#   - 搬回誤搬的活鎖用 rename(2)（perl；`mv(1) 目錄 既有目錄` 會塞進去並回 0，先 test 再 mv 又不是原子的——R2 F3）：
#     目標不存在→成功；目標是第三者剛 mkdir 且已寫 holder 的非空目錄→ENOTEMPTY 失敗，tomb 保留在原地供查證並大聲印，
#     `--status`／巡檢列出殘留 tomb（R2 F2），被搬走的持有者接著 holder 寫入失敗、走 m1 的 exit 2；目標是第三者剛
#     mkdir、holder 尚未落地的**空**目錄→POSIX 允許 rename 取代空目錄，第三者的 holder 會寫進搬回的目錄——需要三個
#     程序在同一毫秒內交錯，機率極低；屆時後 mv 的 holder 生效、另一個 release 時 pid 不符不會誤刪，但兩者可能同時執行。
# exit：命令的 exit code；124＝等待逾時；2＝參數／環境／holder 寫入錯誤／--release 非持有者；--release 時 1＝沒有 hold 可釋放（可能已到期）。
set -uo pipefail

usage() {
  echo "用法：supabase-lock.sh [--timeout <秒>] -- <命令…>｜--hold <label> [--max-minutes N]｜--release｜--status｜--held｜--path（說明見檔頭註解）"
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
timeout=${SUPABASE_LOCK_TIMEOUT:-900}
poll=${SUPABASE_LOCK_POLL:-1}
hold_tick=${SUPABASE_LOCK_HOLD_TICK:-5}
mode=run; hold_label=; max_minutes=30
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)
      [ -n "${2:-}" ] || { echo "✗ supabase-lock：--timeout 缺值" >&2; exit 2; }
      timeout=$2; shift 2 ;;
    --hold)
      [ -n "${2:-}" ] || { echo "✗ supabase-lock：--hold 缺 label" >&2; exit 2; }
      mode=hold; hold_label=$2; shift 2 ;;
    --max-minutes)
      [ -n "${2:-}" ] || { echo "✗ supabase-lock：--max-minutes 缺值" >&2; exit 2; }
      max_minutes=$2; shift 2 ;;
    --release) mode=release; shift ;;
    --hold-guard) mode=guard; shift; break ;;   # 內部：由 --hold fork，參數見 guard_main
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
if [ "$mode" = hold ] || [ "$mode" = guard ]; then
  case "$hold_tick" in ''|.|*[!0-9.]*|*.*.*) echo "✗ supabase-lock：SUPABASE_LOCK_HOLD_TICK 須為數字秒（得到「${hold_tick}」）" >&2; exit 2 ;; esac
  awk -v p="$hold_tick" 'BEGIN { exit !(p + 0 >= 0.2) }' || { echo "✗ supabase-lock：SUPABASE_LOCK_HOLD_TICK 下限 0.2 秒（得到「${hold_tick}」）" >&2; exit 2; }
fi
if [ "$mode" = hold ]; then
  [ $# -eq 0 ] || { echo "✗ supabase-lock：--hold 不接命令（多了「$*」）；hold 期間的命令另外用 -- <命令> 執行（會直接過）" >&2; exit 2; }
  case "$max_minutes" in ''|*[!0-9]*|0) echo "✗ supabase-lock：--max-minutes 須為 1–60 的整數（得到「${max_minutes}」）" >&2; exit 2 ;; esac
  [ "$max_minutes" -le 60 ] || { echo "✗ supabase-lock：--max-minutes 上限 60（得到 ${max_minutes}）；更久請拆段" >&2; exit 2; }
  hold_secs=$(( max_minutes * 60 ))
  if [ -n "${SUPABASE_LOCK_HOLD_SECONDS:-}" ]; then
    case "$SUPABASE_LOCK_HOLD_SECONDS" in ''|*[!0-9]*|0) echo "✗ supabase-lock：SUPABASE_LOCK_HOLD_SECONDS 須為正整數秒（得到「${SUPABASE_LOCK_HOLD_SECONDS}」）" >&2; exit 2 ;; esac
    hold_secs=$SUPABASE_LOCK_HOLD_SECONDS
  fi
fi

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
read_holder() {   # 設定 h_pid h_started h_host h_worktree h_branch h_cmd（hold 另有 h_owner h_expires h_heartbeat）；沒有 holder 檔回 1
  h_pid=; h_started=; h_host=; h_worktree=; h_branch=; h_cmd=; h_owner=; h_expires=; h_heartbeat=
  [ -f "$lock/holder" ] || return 1
  local k v
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      pid) h_pid=$v ;; started) h_started=$v ;; host) h_host=$v ;;
      worktree) h_worktree=$v ;; branch) h_branch=$v ;; cmd) h_cmd=$v ;;
      owner) h_owner=$v ;; expires_at) h_expires=$v ;; heartbeat) h_heartbeat=$v ;;
    esac
  done < "$lock/holder"
  return 0
}
age_of() { local t; t=$(date -r "$1" +%s 2>/dev/null) || t=$(date +%s); echo $(( $(date +%s) - t )); }   # 目錄 mtime 距今秒數
mins_left() { case "$1" in ''|*[!0-9]*) printf '?'; return ;; esac; local r=$(( $1 - $(date +%s) )); [ "$r" -gt 0 ] || r=0; printf '%s' $(( (r + 59) / 60 )); }   # 到期前剩幾分（無條件進位、不低於 0）
fmt_hm() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null || printf '%s' "$1"; }   # epoch→hh:mm（macOS -r 吃 epoch、GNU 走 -d）
holder_line() {   # 一行人類可讀的持有者描述（--status／等待訊息／巡檢共用）；hold 多印「QA 持有中（label，剩餘 n 分）」
  local s age=
  if read_holder; then
    case "$h_started" in ''|*[!0-9]*) ;; *) age="$(( ($(date +%s) - h_started) / 60 ))m" ;; esac
    s="held pid=${h_pid:-?}${age:+ since=${age}} worktree=${h_worktree:-?} branch=${h_branch:-?} cmd=${h_cmd:-?}"
    case "$h_cmd" in hold:*) s="${s} — QA 持有中（${h_cmd#hold:}，剩餘 $(mins_left "$h_expires") 分）" ;; esac
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

# holder 內容先算好（PR #122 R1 M1：git 兩次 fork 約 60–130ms，不能落在 mkdir 之後）；wt 也是 hold_owner_ok 的比對鍵
host=$(hostname 2>/dev/null || echo unknown)
wt=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
br=$(git symbolic-ref --short -q HEAD 2>/dev/null || echo '-')

hold_owner_ok() {   # 0＝本程序可代表目前的 hold（--release／--held／重入三處共用；LS-159）：owner pid 是本程序祖先，或 worktree 相同
  case "$h_cmd" in hold:*) ;; *) return 1 ;; esac
  if [ -n "$h_owner" ] && is_ancestor "$h_owner"; then return 0; fi
  [ -n "$h_worktree" ] && [ "$h_worktree" = "$wt" ]
}

guard_main() {   # 內部模式 --hold-guard <label> <started> <expires_at> <owner> <host> <worktree> <branch>：寫 holder、心跳、到期釋放（LS-159）
  [ $# -eq 7 ] || { echo "✗ supabase-lock：--hold-guard 是內部模式（由 --hold fork），參數數量錯" >&2; exit 2; }
  local g_label=$1 g_started=$2 g_expires=$3 g_owner=$4 g_host=$5 g_wt=$6 g_br=$7 sleeper= now
  write_hold_holder() {   # $1＝heartbeat epoch；printf 暫存＋mv（與取得路徑同一套：原子、暫存檔以 pid 唯一化）
    printf 'pid=%s\nstarted=%s\nhost=%s\nworktree=%s\nbranch=%s\ncmd=hold:%s\nowner=%s\nexpires_at=%s\nheartbeat=%s\n' \
      "$$" "$g_started" "$g_host" "$g_wt" "$g_br" "$g_label" "$g_owner" "$g_expires" "$1" > "$lock/holder.$$.tmp" 2>/dev/null \
      && mv "$lock/holder.$$.tmp" "$lock/holder" 2>/dev/null
  }
  release_mine() { if read_holder && [ "$h_pid" = "$$" ]; then rm -rf "$lock"; fi; }
  on_term() { [ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null; release_mine; exit 143; }
  trap on_term TERM INT
  trap '' HUP
  if ! write_hold_holder "$g_started"; then
    echo "✗ supabase-lock：hold holder 寫入失敗（${lock}/holder）——放棄 hold" >&2
    rm -f "$lock/holder.$$.tmp" 2>/dev/null; rmdir "$lock" 2>/dev/null
    exit 2
  fi
  while :; do
    sleep "$hold_tick" & sleeper=$!      # 背景 sleep＋wait：TERM 一到 wait 就返回、trap 立刻跑，不必等完整個 tick
    wait "$sleeper"; sleeper=
    read_holder || exit 0                # 已被 --release／回收
    [ "$h_pid" = "$$" ] || exit 0        # lock 已是別人的，不碰
    now=$(date +%s)
    if [ "$now" -ge "$g_expires" ]; then
      release_mine
      echo "⚠ supabase-lock：hold「${g_label}」到期（持有 $(( (now - g_started) / 60 )) 分）自動釋放（守門 pid $$，$(date '+%H:%M:%S')）" >&2
      exit 0
    fi
    write_hold_holder "$now" || exit 0   # 目錄已不在＝已被釋放
  done
}

release_hold() {   # --release（LS-159）：只釋放 hold、只給持有者；kill 守門並等它自己刪，沒刪才代刪
  if ! read_holder; then
    echo "→ supabase-lock：lock 未持有（free）——沒有 hold 可釋放（若你之前 --hold 過，可能已到期自動釋放：期間其他 worktree 的 reset 可能已跑過，見 ${lock}.hold.log）" >&2
    exit 1
  fi
  case "$h_cmd" in hold:*) ;; *) echo "✗ supabase-lock：目前的持有者不是 hold（$(holder_line)）——--release 只釋放 --hold 建立的持有，命令型持有由該程序結束時自行釋放" >&2; exit 2 ;; esac
  if ! hold_owner_ok; then
    echo "✗ supabase-lock：你不是這個 hold 的持有者（owner pid ${h_owner:-?} 不是本程序祖先、worktree ${h_worktree:-?} ≠ ${wt}）——不釋放。持有者：$(holder_line)" >&2
    exit 2
  fi
  local gpid=$h_pid label=${h_cmd#hold:} t0=$h_started n=0 dur
  if alive "$gpid"; then
    kill -TERM "$gpid" 2>/dev/null
    while alive "$gpid" && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
    if alive "$gpid"; then
      kill -KILL "$gpid" 2>/dev/null   # 被 SIGSTOP 的守門若日後恢復會把 heartbeat 重寫進別人的新 lock——先殺再刪
      echo "⚠ supabase-lock：守門 pid ${gpid} 3s 內未結束，已 -KILL" >&2
    fi
  fi
  if read_holder && [ "$h_pid" = "$gpid" ]; then rm -rf "$lock"; fi   # 守門正常路徑自己刪；被 -9／剛 -KILL 才由這裡刪
  case "$t0" in ''|*[!0-9]*) dur='?' ;; *) dur=$(( $(date +%s) - t0 )); dur="$(( dur / 60 )) 分 $(( dur % 60 )) 秒" ;; esac
  echo "→ supabase-lock：已釋放 hold「${label}」（持有 ${dur}；守門 pid ${gpid}）" >&2
  exit 0
}

case "$mode" in
  path) printf '%s\n' "$lock"; exit 0 ;;
  status) printf '%s\n' "$(holder_line)"; tomb_lines; exit 0 ;;
  held) if read_holder && { is_ancestor "$h_pid" || { hold_owner_ok && alive "$h_pid"; }; }; then exit 0; else exit 1; fi ;;
  release) release_hold ;;
  guard) guard_main "$@" ;;
esac

if [ "$mode" = run ]; then
  [ $# -gt 0 ] || { echo "✗ supabase-lock：缺命令" >&2; usage >&2; exit 2; }
  # 重入：持有者是本程序的祖先 → 直接執行（run.sh 經 lock 重跑自己時、或使用者已手動包了一層）；持有者是自己的 hold
  # （守門仍活著）也直接執行——QA 在 hold 內的 reset／run.sh 仍要包 wrapper（PreToolUse H3 只認 wrapper 字面）。
  # 兩條都要 export：否則子程序看不到變數、run.sh 一類的包裝又會 exec 回來（PR #122 R1 m2 實測無窮迴圈）。
  if read_holder; then
    if is_ancestor "$h_pid"; then
      export SUPABASE_LOCK_HELD=$lock
      echo "→ supabase-lock：已在 lock 內（持有者 pid ${h_pid}），直接執行" >&2
      exec "$@"
    elif hold_owner_ok && alive "$h_pid"; then
      export SUPABASE_LOCK_HELD=$lock
      echo "→ supabase-lock：已在自己的 hold 內（${h_cmd#hold:}，剩餘 $(mins_left "$h_expires") 分；守門 pid ${h_pid}），直接執行" >&2
      exec "$@"
    fi
  fi
elif read_holder; then   # hold：已在 lock／活著的 hold 內就不再 hold（守門死了就往下走既有回收路徑重新取得）
  if is_ancestor "$h_pid"; then echo "✗ supabase-lock：已在 lock 內（持有者 pid ${h_pid} 是本程序祖先），不需 --hold" >&2; exit 2; fi
  if hold_owner_ok && alive "$h_pid"; then echo "✗ supabase-lock：已持有 hold「${h_cmd#hold:}」（剩餘 $(mins_left "$h_expires") 分，守門 pid ${h_pid}）——先 --release 再 --hold" >&2; exit 2; fi
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

cmd_str=$(printf '%s' "$*" | tr '\n' ' ')   # host／wt／br 已在上面算好（M1：不能落在 mkdir 之後）

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

if [ "$mode" = hold ]; then
  # 取得了：fork 守門子程序持有（獨立程序才有自己的 pid；stdio 不繼承呼叫者的管線，否則 agent 的 Bash 工具會等到 hold 結束；
  # nohup＋disown——macOS 沒有 setsid）。lock 路徑明傳給守門、不再由 config.toml 推；holder 由守門寫，主程序等它落地。
  hold_log="${lock}.hold.log"
  now=$(date +%s); expires_at=$(( now + hold_secs ))
  if command -v nohup >/dev/null 2>&1; then
    SUPABASE_LOCK_DIR=$lock nohup bash "${BASH_SOURCE[0]}" --hold-guard "$hold_label" "$now" "$expires_at" "$PPID" "$host" "$wt" "$br" </dev/null >/dev/null 2>>"$hold_log" &
  else
    SUPABASE_LOCK_DIR=$lock bash "${BASH_SOURCE[0]}" --hold-guard "$hold_label" "$now" "$expires_at" "$PPID" "$host" "$wt" "$br" </dev/null >/dev/null 2>>"$hold_log" &
  fi
  gpid=$!
  disown "$gpid" 2>/dev/null || true
  i=0
  until read_holder && [ "$h_pid" = "$gpid" ]; do
    if ! alive "$gpid"; then
      echo "✗ supabase-lock：守門程序（pid ${gpid}）沒寫入 holder 就結束——見 ${hold_log}" >&2
      rmdir "$lock" 2>/dev/null   # 只 rmdir：自己剛 mkdir 的空目錄才刪得掉（守門寫入失敗時已自行 rmdir）
      exit 2
    fi
    i=$((i + 1))
    if [ "$i" -ge 100 ]; then
      kill "$gpid" 2>/dev/null
      echo "✗ supabase-lock：守門程序（pid ${gpid}）10s 內沒寫 holder，已 kill；${lock} 若殘留無 holder，30s 後自動回收" >&2
      exit 2
    fi
    sleep 0.1
  done
  [ "$announced" -eq 1 ] && echo "→ supabase-lock：取得 lock（等了 $(( $(date +%s) - started ))s）" >&2
  echo "held pid=${gpid} label=${hold_label} expires=$(fmt_hm "$expires_at") log=${hold_log}"
  exit 0
fi

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
