#!/bin/bash
# 跟隨 promote 鏈（LS-257，來源 LS-96 池項 6049fddb）：把先前只存在 orchestrator 記憶（scratch-0913/
# dev-promote-follow-tip.sh）裡的「跟 <from> tip 的 push run」動作正式入 repo，並補一個新行為——
# 今日三次 dev／main／test push run 的 `ci` job 撞 `.github/workflows/ci.yml` `timeout-minutes` 被標
# `cancelled`（純逾時假紅，與 diff 無關），過去只能人工 `gh run rerun --failed` 一次。這裡機械化：
# run `conclusion=cancelled` 且該 run**沒有任何** `failure`／`timed_out` 步驟時，視為這種假紅，自動
# rerun 一次再跟；有任何真的失敗步驟才不 rerun，直接印失敗摘要退出。
#
# R1 merge-review M1 訂正（原檔頭與 §7 誤寫「步驟全 success」；實測三次事故：`gh api
# repos/CLYEH/little-sprout/actions/runs/<id>/attempts/1/jobs` 對 dev `34754691944`／main
# `34755219511`／test `34757987069` 取 attempt 1 的 `ci` job steps，三次裡有兩次（main／test）撞
# timeout 那一刻「點擊目標 gate」正在跑、被記成 `cancelled`，不是 `success`——若只放行「全
# success／skipped」，這兩次仍會被誤判成「真紅」而不自動 rerun，票要解決的主場景反而漏了 2/3）。
# 現在的判準是「沒有任何 failure／timed_out 步驟」——`cancelled`／`null`（未完成）都視為可 rerun：
# 它們都不是測試紅，而下面呼叫的 promote.sh 仍會對 rerun 後的新 SHA／run 重新驗 required checks，
# 誤觸 rerun 的代價只是多跑一輪 CI，不會誤晉升。
#
# 用法：promote-follow.sh <from> <to>（development test ／ test main，同 promote.sh；在 repo 內任一目錄執行）
# 步驟：(a) git fetch origin，取 origin/<from> tip
#       (b) 找 tip 的 push run（gh run list --branch <from> --commit <tip> --json databaseId,event,createdAt，
#           篩 event=="push"、取最新一筆）；找不到最多等 5 分鐘（10 次 × 30s）
#       (c) 等 run 跑完（最多 60 次 × 60s）；等待中 origin/<from> 前進就改跟新 tip（整個 (a)-(c) 重來，
#           上限 6 輪，見 (f)）
#       (d) run 完成後看 conclusion：
#           - success → 進 (e)
#           - cancelled 且沒有任何 failure／timed_out 步驟 → gh run rerun <run> --failed 一次；R1
#             merge-review M2：rerun 送出後 GitHub 端翻成新 attempt 有短暫延遲，先等 `attempt` 欄位
#             真的前進**且** status≠completed（最多 10 次 × 30s）才進入下一輪完成輪詢，避免在這個窗口
#             讀到舊 attempt 的 completed／cancelled 就誤判「rerun 後仍未綠」；等到新 attempt 或逾時都
#             會照常往下走完成輪詢（最多 60 次 × 60s），再看一次 conclusion；仍非 success 就印失敗
#             摘要、exit 3
#           - 其他（真的有步驟紅）→ 不 rerun，印失敗摘要、exit 3
#       (e) 呼叫 promote.sh <from> <to>（路徑見 promote_sh()）；失敗且期間 tip 前進就改跟新 tip
#           （上限 6 次），否則 exit 4
#       (f) tip 連續前進 6 次（(c) 或 (e) 期間）仍未 promote 成功 → exit 5，放棄
# exit：0＝已 promote（或呼叫 promote.sh 本身回報「已等於，無需動作」也算 0，promote.sh 自己印）；
#       2＝參數／環境錯誤（gh／git 缺、不在 git repo、fetch 失敗、找不到 push run）；
#       3＝run 未綠（含 rerun 一次後仍未綠，或本來就不符合 rerun 資格）；
#       4＝promote.sh 本身失敗（check／status 未綠或推送被拒）；5＝tip 連續前進 6 次，放棄
# 自測：scripts/ops/promote-follow.test.sh（PATH 前置假 gh／git／sleep，PROMOTE_SH 指向假
#       promote.sh，掛 CI rules job）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() { echo "用法：promote-follow.sh <from> <to>（development test ／ test main）" >&2; exit 2; }
[ $# -eq 2 ] || usage
from=$1; to=$2

command -v gh >/dev/null 2>&1 || { echo "✗ promote-follow：需要 gh（brew install gh）。" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "✗ promote-follow：需要 jq。" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ promote-follow：目前目錄不在 git repo 內。" >&2; exit 2; }

log() { echo "[$(date +%H:%M:%S)] $*"; }

# R1 merge-review m3：不再用 `command -v promote.sh`（PATH 上只要存在任何一支叫 promote.sh 的可執行檔
# ——別的 repo、~/bin——就會劫持這個會 push 到 test／main 的動作）。改用明確的環境變數 seam：一般
# 執行沒人會設 PROMOTE_SH，落回本檔旁邊的真正 promote.sh；自測顯式設定該變數指向假腳本。
promote_sh() {
  bash "${PROMOTE_SH:-${root}/scripts/ops/promote.sh}" "$@"
}

# find_push_run <sha> → 印該 sha 在 <from> 分支上最新一筆 push 事件的 run id；找不到印空字串
find_push_run() {
  local sha=$1
  gh run list --branch "${from}" --commit "${sha}" --json databaseId,event,createdAt \
    --jq '[.[] | select(.event == "push")] | sort_by(.createdAt) | last | .databaseId // empty' 2>/dev/null
}

# run_json <run id> → 印該 run 的 {status,conclusion,jobs,attempt} JSON（一次 gh 呼叫，供下面讀值函式共用）
run_json() {
  gh run view "$1" --json status,conclusion,jobs,attempt 2>/dev/null
}

# no_failure_steps <run json> → 0＝該 run 沒有任何 job 的任何 step 是 failure／timed_out（R1 M1 訂正：
# 原本要求「全 success／skipped」，對撞 timeout 那一刻正在跑的步驟會被 GitHub 記成 cancelled，這個
# 更嚴格的條件反而漏掉票要解決的主場景，見上方檔頭訂正說明）。
no_failure_steps() {
  printf '%s' "$1" | jq -e '[.jobs[].steps[]?.conclusion] | length > 0 and all(. != "failure" and . != "timed_out")' >/dev/null 2>&1
}

# print_failure_summary <run id> <run json> → 印失敗 job 名與該 job log 裡的 Test Case failed 摘要（stderr）
print_failure_summary() {
  local run=$1 json=$2 job
  job=$(printf '%s' "$json" | jq -r '[.jobs[] | select(.conclusion != "success" and .conclusion != "skipped")] | first | .databaseId // empty')
  if [ -z "${job}" ]; then
    echo "  找不到明確失敗的 job（run 的所有 job 皆 success／skipped，但 run 整體未成功——可能是取消／逾時，且不符合自動 rerun 資格）" >&2
    return
  fi
  echo "  失敗 job：${job}（run ${run}）" >&2
  gh run view "${run}" --job "${job}" --log-failed 2>/dev/null \
    | grep -oE "Test Case '[^']+' failed" | sort -u | sed 's/^/    /' >&2
}

for _attempt_outer in $(seq 1 6); do
  git fetch -q origin || { echo "✗ promote-follow：git fetch origin 失敗。" >&2; exit 2; }
  tip=$(git rev-parse "origin/${from}" 2>/dev/null) || { echo "✗ promote-follow：本機沒有 origin/${from}。" >&2; exit 2; }

  run=""
  for i in $(seq 1 10); do
    run=$(find_push_run "${tip}")
    [ -n "${run}" ] && break
    sleep 30
  done
  if [ -z "${run}" ]; then
    echo "✗ promote-follow：找不到 ${tip:0:7} 的 push run（等了 5 分鐘）。" >&2
    exit 2
  fi
  log "跟 ${from} tip ${tip:0:7} run ${run}"

  moved=0
  json=""
  for i in $(seq 1 60); do
    json=$(run_json "${run}")
    status=$(printf '%s' "${json}" | jq -r '.status // empty')
    [ "${status}" = completed ] && break
    git fetch -q origin
    if [ "$(git rev-parse "origin/${from}" 2>/dev/null)" != "${tip}" ]; then
      log "tip 前進，改跟新 tip"
      moved=1
      break
    fi
    sleep 60
  done
  [ "${moved}" = 1 ] && continue

  conclusion=$(printf '%s' "${json}" | jq -r '.conclusion // empty')
  log "run ${run} conclusion=${conclusion}"

  if [ "${conclusion}" = cancelled ] && no_failure_steps "${json}"; then
    attempt_before=$(printf '%s' "${json}" | jq -r '.attempt // empty')
    log "cancelled 且無 failure／timed_out 步驟（撞 timeout-minutes 的假紅，LS-257）→ gh run rerun ${run} --failed 一次（rerun 前 attempt=${attempt_before:-?}）"
    gh run rerun "${run}" --failed || { echo "✗ promote-follow：gh run rerun ${run} --failed 失敗。" >&2; exit 3; }
    # R1 merge-review M2：GitHub 端把 run 翻成新 attempt 有短暫延遲——先等 attempt 真的前進且
    # status≠completed，避免這個窗口內讀到舊 attempt 的 completed／cancelled 就誤判「rerun 後仍未綠」。
    new_attempt_seen=0
    for i in $(seq 1 10); do
      json=$(run_json "${run}")
      attempt=$(printf '%s' "${json}" | jq -r '.attempt // empty')
      status=$(printf '%s' "${json}" | jq -r '.status // empty')
      if [ -n "${attempt}" ] && [ "${attempt}" != "${attempt_before}" ] && [ "${status}" != completed ]; then
        log "rerun 後新 attempt=${attempt}（舊 attempt=${attempt_before:-?}）已開始，開始跟"
        new_attempt_seen=1
        break
      fi
      sleep 30
    done
    [ "${new_attempt_seen}" = 1 ] || log "等了 5 分鐘仍未見新 attempt 前進——照常往下跟目前讀到的狀態（可能 GitHub 端延遲較久，或此 run 從未真的被重跑）"
    for i in $(seq 1 60); do
      json=$(run_json "${run}")
      status=$(printf '%s' "${json}" | jq -r '.status // empty')
      [ "${status}" = completed ] && break
      sleep 60
    done
    conclusion=$(printf '%s' "${json}" | jq -r '.conclusion // empty')
    log "rerun 後 run ${run} conclusion=${conclusion}"
  fi

  if [ "${conclusion}" != success ]; then
    status=$(printf '%s' "${json}" | jq -r '.status // empty')
    if [ "${status}" != completed ]; then
      echo "✗ promote-follow：run ${run}（${from} tip ${tip:0:7}）等了逾時仍未完成（status=${status:-?}）。" >&2
    else
      echo "✗ promote-follow：run ${run}（${from} tip ${tip:0:7}）未綠（conclusion=${conclusion}）。" >&2
    fi
    print_failure_summary "${run}" "${json}"
    exit 3
  fi

  for i in $(seq 1 6); do
    if promote_sh "${from}" "${to}"; then
      log "✓ promoted ${from}→${to}（${tip:0:7}）"
      exit 0
    fi
    git fetch -q origin
    if [ "$(git rev-parse "origin/${from}" 2>/dev/null)" != "${tip}" ]; then
      log "promote 前 tip 前進，改跟新 tip"
      moved=1
      break
    fi
    sleep 45
  done
  [ "${moved}" = 1 ] && continue
  echo "✗ promote-follow：promote.sh ${from} ${to} 仍失敗。" >&2
  exit 4
done

echo "✗ promote-follow：${from} tip 連續前進 6 次，放棄。" >&2
exit 5
