#!/bin/bash
# 跟隨 promote 鏈（LS-257，來源 LS-96 池項 6049fddb）：把先前只存在 orchestrator 記憶（scratch-0913/
# dev-promote-follow-tip.sh）裡的「跟 <from> tip 的 push run」動作正式入 repo，並補一個新行為——
# 今日三次 dev／main／test push run 的 `ci` job 全部步驟 success，卻因總時長撞
# `.github/workflows/ci.yml` `timeout-minutes` 被標 `cancelled`（純逾時假紅，與 diff 無關）；過去只能
# 人工 `gh run rerun --failed` 一次。這裡機械化：run `conclusion=cancelled` 且該 run 所有 job 的所有
# steps 皆 `success`／`skipped`（沒有任何 failure／未完成的步驟）時，視為這種假紅，自動 rerun 一次再跟；
# 若不是這個形狀（真的有步驟紅或未完成），不 rerun，直接印失敗摘要退出——避免把「真的壞了」誤判成
# 「逾時假紅」而白等一輪 rerun。
#
# 用法：promote-follow.sh <from> <to>（development test ／ test main，同 promote.sh；在 repo 內任一目錄執行）
# 步驟：(a) git fetch origin，取 origin/<from> tip
#       (b) 找 tip 的 push run（gh run list --branch <from> --commit <tip> --json databaseId,event,createdAt，
#           篩 event=="push"、取最新一筆）；找不到最多等 5 分鐘（10 次 × 30s）
#       (c) 等 run 跑完（最多 60 次 × 60s）；等待中 origin/<from> 前進就改跟新 tip（整個 (a)-(c) 重來，
#           上限 6 輪，見 (f)）
#       (d) run 完成後看 conclusion：
#           - success → 進 (e)
#           - cancelled 且所有 job 的所有 steps 皆 success／skipped → gh run rerun <run> --failed 一次，
#             重新等它跑完，再看一次 conclusion；仍非 success 就印失敗摘要、exit 3
#           - 其他（真的有步驟紅、或 cancelled 但步驟不是全綠）→ 不 rerun，印失敗摘要、exit 3
#       (e) bash scripts/ops/promote.sh <from> <to>；失敗且期間 tip 前進就改跟新 tip（上限 6 次），
#           否則 exit 4
#       (f) tip 連續前進 6 次（(c) 或 (e) 期間）仍未 promote 成功 → exit 5，放棄
# exit：0＝已 promote（或呼叫 promote.sh 本身回報「已等於，無需動作」也算 0，promote.sh 自己印）；
#       2＝參數／環境錯誤（gh／git 缺、不在 git repo、fetch 失敗、找不到 push run）；
#       3＝run 未綠（含 rerun 一次後仍未綠，或本來就不符合 rerun 資格）；
#       4＝promote.sh 本身失敗（check／status 未綠或推送被拒）；5＝tip 連續前進 6 次，放棄
# 自測：scripts/ops/promote-follow.test.sh（PATH 前置假 gh／git／sleep／promote.sh，掛 CI rules job）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() { echo "用法：promote-follow.sh <from> <to>（development test ／ test main）" >&2; exit 2; }
[ $# -eq 2 ] || usage
from=$1; to=$2

command -v gh >/dev/null 2>&1 || { echo "✗ promote-follow：需要 gh（brew install gh）。" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "✗ promote-follow：需要 jq。" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ promote-follow：目前目錄不在 git repo 內。" >&2; exit 2; }

log() { echo "[$(date +%H:%M:%S)] $*"; }

# 自測用間接層：PATH 若已能解析出一支叫 promote.sh 的可執行檔（自測 PATH 前置假 bin 目錄放了一支）
# 就直接呼叫它；一般執行不會有人把 scripts/ops 加進 PATH，落回呼叫本檔旁邊的真正 promote.sh。
promote_sh() {
  if command -v promote.sh >/dev/null 2>&1; then
    promote.sh "$@"
  else
    bash "${root}/scripts/ops/promote.sh" "$@"
  fi
}

# find_push_run <sha> → 印該 sha 在 <from> 分支上最新一筆 push 事件的 run id；找不到印空字串
find_push_run() {
  local sha=$1
  gh run list --branch "${from}" --commit "${sha}" --json databaseId,event,createdAt \
    --jq '[.[] | select(.event == "push")] | sort_by(.createdAt) | last | .databaseId // empty' 2>/dev/null
}

# run_json <run id> → 印該 run 的 {status,conclusion,jobs} JSON（一次 gh 呼叫，供下面三個讀值函式共用）
run_json() {
  gh run view "$1" --json status,conclusion,jobs 2>/dev/null
}

# all_steps_green <run json> → 0＝該 run 所有 job 的所有 steps 皆 success／skipped（沒有 failure／
# cancelled／未完成的 null）——只有這個形狀才是「純逾時、步驟本身沒問題」的假紅。
all_steps_green() {
  printf '%s' "$1" | jq -e '[.jobs[].steps[]?.conclusion] | length > 0 and all(. == "success" or . == "skipped")' >/dev/null 2>&1
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

for outer in $(seq 1 6); do
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

  if [ "${conclusion}" = cancelled ] && all_steps_green "${json}"; then
    log "cancelled 且所有步驟 success／skipped（撞 timeout-minutes 的假紅，LS-257）→ gh run rerun ${run} --failed 一次"
    gh run rerun "${run}" --failed || { echo "✗ promote-follow：gh run rerun ${run} --failed 失敗。" >&2; exit 3; }
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
    echo "✗ promote-follow：run ${run}（${from} tip ${tip:0:7}）未綠（conclusion=${conclusion}）。" >&2
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
