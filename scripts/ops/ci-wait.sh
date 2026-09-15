#!/bin/bash
# ci-wait.sh — LS-299（源自 LS-96 池項 26bbff68）：qa／ios-dev 等 agent 等 CI 時用 `gh run watch <id>
# --exit-status` 一次跑到底，撞 Bash 工具 600 秒上限後系統把命令自動移到背景、agent 收到「已移背景」
# 就停下等通知——但**背景命令完成不會喚醒 subagent**，09-15 當天三次（LS-286／287／295）都要
# orchestrator SendMessage 催（LS-295 那次 qa 甚至開了三個殘留 watch）。派工單已寫「單次逾時再前景跑
# 一次」仍發生，代表只靠 prompt 不夠，要機械化。
#
# 這支腳本把「單次前景執行最長 N 分鐘、到時就乖乖印出下一步再退出」做成可重入的獨立命令——agent 自己
# 在前景反覆呼叫（不像 promote-follow.sh 是 orchestrator 背景鏈自己內建的等待迴圈）。
#
# 用法：ci-wait.sh <run-id> [--max-minutes <n>] [--job <name>] [--interval <sec>]
#   --max-minutes <n>  單次執行最長等待分鐘數（預設 9；必須 <10——Bash 工具上限是 600 秒／10 分鐘）
#   --job <name>       只看該 job 的結論（qa 常只需要 `rules`）；job 不存在或尚未完成都視為仍在跑
#   --interval <sec>   輪詢間隔秒數（預設 30；自測用 1，非典型用途不要調）
#   -h/--help
#
# exit：
#   0＝run（或指定 --job 的那個 job）完成且 conclusion=success
#   1＝完成但 conclusion≠success（failure／cancelled／timed_out／…）
#   2＝`gh run view` 連續失敗 3 次（curl 逾時之類）
#   3＝到 --max-minutes 仍未完成，印「仍在跑：<已耗時>／再跑一次 bash scripts/ops/ci-wait.sh <id>」
#     ——agent 應照這行再呼叫一次；禁改用 `gh run watch`、禁 `run_in_background`（見
#     docs/COLLABORATION.md §7、.claude/agents/{qa,ios-dev,merge-reviewer}.md）
#
# 自測：scripts/ops/ci-wait.test.sh（PATH 前置假 gh；六組：完成 success／完成 failure／到時仍在跑
#   exit 3／--job 只看單一 job／gh 連續 3 次失敗 exit 2／gh 失敗兩次後恢復不誤判；mutation：拿掉下方
#   MUTATION-TIMEOUT 區塊 → 「仍在跑」夾具失去逾時退出、陷入無窮迴圈，自測用背景 watchdog 強制中止並
#   斷言這就是紅的來源）掛 CI rules job 的自測 step；本檔也在 selftest-wiring-check 的清單裡。
set -uo pipefail

usage() {
  cat >&2 <<'EOF'
用法：ci-wait.sh <run-id> [--max-minutes <n>] [--job <name>] [--interval <sec>]
等 CI 一律前景執行這支（禁 `gh run watch`、禁 run_in_background）；exit 3 就照印出的指令再跑一次。
  --max-minutes <n>  單次最長等待分鐘數（預設 9，必須 <10）
  --job <name>       只看該 job 的結論
  --interval <sec>   輪詢間隔秒數（預設 30；自測專用）
  -h, --help         印本說明
EOF
}

run_id=
max_minutes=9
job_name=
interval=30

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --max-minutes)
      [ -n "${2:-}" ] || { echo "✗ ci-wait：--max-minutes 缺值" >&2; exit 2; }
      max_minutes=$2; shift 2 ;;
    --job)
      [ -n "${2:-}" ] || { echo "✗ ci-wait：--job 缺值" >&2; exit 2; }
      job_name=$2; shift 2 ;;
    --interval)
      [ -n "${2:-}" ] || { echo "✗ ci-wait：--interval 缺值" >&2; exit 2; }
      interval=$2; shift 2 ;;
    --)
      shift; break ;;
    -*)
      echo "✗ ci-wait：未知參數「$1」" >&2; usage; exit 2 ;;
    *)
      if [ -n "$run_id" ]; then
        echo "✗ ci-wait：只接受一個 run-id（多給了「$1」）" >&2; exit 2
      fi
      run_id=$1; shift ;;
  esac
done

[ -n "$run_id" ] || { echo "✗ ci-wait：缺 <run-id>" >&2; usage; exit 2; }
case "$max_minutes" in ''|*[!0-9]*) echo "✗ ci-wait：--max-minutes 必須是非負整數" >&2; exit 2 ;; esac
case "$interval" in ''|*[!0-9]*) echo "✗ ci-wait：--interval 必須是非負整數" >&2; exit 2 ;; esac
if [ "$max_minutes" -ge 10 ]; then
  echo "✗ ci-wait：--max-minutes 必須 <10（Bash 工具上限 600 秒／10 分鐘，見 docs/COLLABORATION.md §7）" >&2
  exit 2
fi

command -v gh >/dev/null 2>&1 || { echo "✗ ci-wait：需要 gh（brew install gh）" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "✗ ci-wait：需要 jq" >&2; exit 2; }

max_seconds=$((max_minutes * 60))
start_ts=$(date +%s)
fail_streak=0

run_view() {
  gh run view "$run_id" --json status,conclusion,jobs 2>/dev/null
}

print_jobs() {
  printf '%s' "$1" | jq -r '.jobs[]? | "  job " + .name + "：" + (.conclusion // "（未完成）")'
}

# job_line <json> → 印 "<status>\t<conclusion>"（找不到該名字的 job 印 "\t"）
job_line() {
  printf '%s' "$1" | jq -r --arg n "$job_name" \
    '([.jobs[]? | select(.name == $n)] | first) as $j | (($j.status // "") + "\t" + ($j.conclusion // ""))'
}

while :; do
  json=$(run_view)
  if [ -z "$json" ]; then
    fail_streak=$((fail_streak + 1))
    if [ "$fail_streak" -ge 3 ]; then
      echo "✗ ci-wait：gh run view ${run_id} 連續失敗 3 次（curl 逾時之類）" >&2
      exit 2
    fi
    sleep "$interval"
    continue
  fi
  fail_streak=0

  status=$(printf '%s' "$json" | jq -r '.status // empty')
  now_ts=$(date +%s)
  elapsed=$((now_ts - start_ts))

  if [ -n "$job_name" ]; then
    line=$(job_line "$json")
    jstatus=${line%%$'\t'*}
    jconclusion=${line#*$'\t'}
    if [ "$jstatus" = completed ]; then
      echo "run ${run_id} job「${job_name}」conclusion=${jconclusion:-（無）}"
      print_jobs "$json"
      if [ "$jconclusion" = success ]; then exit 0; else exit 1; fi
    fi
  else
    if [ "$status" = completed ]; then
      conclusion=$(printf '%s' "$json" | jq -r '.conclusion // empty')
      echo "run ${run_id} conclusion=${conclusion:-（無）}"
      print_jobs "$json"
      if [ "$conclusion" = success ]; then exit 0; else exit 1; fi
    fi
  fi

  # MUTATION-TIMEOUT-START（ci-wait.test.sh 的 mutation 案例用 awk 拿掉這段：少了逾時退出，遇到「一直
  # 在跑」的夾具會無窮迴圈——自測藉此證明這段就是「仍在跑就乖乖退出」行為的來源）
  if [ "$elapsed" -ge "$max_seconds" ]; then
    job_flag=""
    [ -n "$job_name" ] && job_flag=" --job ${job_name}"
    echo "仍在跑：已耗時 $((elapsed / 60)) 分 $((elapsed % 60)) 秒／再跑一次 bash scripts/ops/ci-wait.sh ${run_id}${job_flag}" >&2
    print_jobs "$json"
    exit 3
  fi
  # MUTATION-TIMEOUT-END

  sleep "$interval"
done
