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
#   --max-minutes <n>  單次執行最長等待分鐘數（預設 7；必須 <10——Bash 工具上限是 600 秒／10 分鐘）
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
# R2（merge-review R1 B1，major，已修）：逾時檢查原本只在「成功拿到 json」那個分支做，`gh` 失敗
# （fail_streak 未達 3、正在重試）的迭代完全跳過逾時檢查、直接 `sleep "$interval"` 後 `continue`——
# 「失敗、失敗、成功」這種間歇性節奏（腳本自己設計要容忍的情境）會讓好幾輪失敗迭代的 sleep 都不被計入
# 逾時判斷，等下一次成功呼叫才重新比對，逾時退出點可以晚於 `--max-minutes` 好幾個 `--interval`——
# reviewer 實測 `--max-minutes 1 --interval 5`（60s 預算）在 2-fail-1-success 節奏下跑了 71s 才 exit 3；
# 用預設值（9 分＋30s）推算最壞可能上探到 ~600-630s，等於重現這張票要修的事故本身。
# 修法：逾時檢查移到迴圈**最前面**、在呼叫 `gh` 之前，兩個分支（成功／失敗）共用同一個檢查點——不論
# 這一輪是要重試還是要查詢完成度，都先確認還沒超時。這樣任何一輪的「多墊時間」只可能來自**這一輪自己**
# 的 `gh` 呼叫耗時＋前一輪的 `sleep "$interval"`（單一次 overshoot，不會像原本那樣跨多輪累積）。
#
# 最壞總時長估算（R2 新增，供選預設值與 --help 參考；`GH_TIMEOUT_SEC`＝假設單次 `gh` 呼叫最壞耗時，
# 對應 curl／gh CLI 本身的網路逾時量級，非本腳本可控，僅為抓數量級）：
#   worst_seconds ≈ --max-minutes×60 ＋ --interval ＋ 3×GH_TIMEOUT_SEC
# 用舊預設（9 分＋30s 間隔＋gh 逾時 3×25s）算：9×60 + 30 + 3×25 ≈ 645s——已經超過 Bash 工具 600s 硬
# 上限，是這次 review 抓到的根因之一。R2 把預設 `--max-minutes` 降到 7，同樣公式算：7×60 + 30 + 75 =
# 525s，留有 ≥45s 安全邊界；執行時若使用者自訂的組合讓這個估算值 ≥570s（600s 硬上限扣一點緩衝），
# 腳本會 fail loud 拒絕執行並教怎麼調（見下方參數驗證）。
#
# 自測：scripts/ops/ci-wait.test.sh（PATH 前置假 gh；含完成 success／完成 failure／到時仍在跑 exit 3／
#   --job 只看單一 job／gh 連續 3 次失敗 exit 2／gh 失敗兩次後恢復不誤判／R2 新增「失敗、失敗、成功」
#   節奏夾具驗證 elapsed 不超過預算＋一次 interval；mutation：拿掉逾時檢查（含失敗分支的檢查點）→
#   「仍在跑」夾具失去逾時退出、陷入無窮迴圈，自測用背景 watchdog 強制中止並斷言這就是紅的來源）掛 CI
#   rules job 的自測 step；本檔也在 selftest-wiring-check 的清單裡。
set -uo pipefail

# 假設單次 `gh` 呼叫最壞耗時（秒）——curl／gh CLI 本身的網路逾時量級，供最壞總時長估算用，非本腳本可控。
GH_TIMEOUT_SEC=25
# 逾時估算的安全門檻（秒）——比 Bash 工具硬上限 600s 再留緩衝，不要卡在邊界上。
WORST_CASE_LIMIT_SEC=570

usage() {
  cat >&2 <<EOF
用法：ci-wait.sh <run-id> [--max-minutes <n>] [--job <name>] [--interval <sec>]
等 CI 一律前景執行這支（禁 \`gh run watch\`、禁 run_in_background）；exit 3 就照印出的指令再跑一次。
  --max-minutes <n>  單次最長等待分鐘數（預設 7，必須 <10）
  --job <name>       只看該 job 的結論
  --interval <sec>   輪詢間隔秒數（預設 30；自測專用）
  -h, --help         印本說明

最壞總時長估算：--max-minutes×60 ＋ --interval ＋ 3×${GH_TIMEOUT_SEC}（假設單次 gh 呼叫最壞耗時，
量級估計，非本腳本可控）。舊預設（9 分＋30s 間隔）算出來 ≈645s，已超過 Bash 工具 600s 硬上限——這正是
R2 把預設改成 7 分的原因（7×60+30+3×${GH_TIMEOUT_SEC}=525s，留 ≥45s 緩衝）。這個估算值 ≥${WORST_CASE_LIMIT_SEC}s
就會拒絕執行，教你調小 --max-minutes 或 --interval。
EOF
}

run_id=
max_minutes=7
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

max_seconds=$((max_minutes * 60))
worst_seconds=$((max_seconds + interval + 3 * GH_TIMEOUT_SEC))
if [ "$worst_seconds" -ge "$WORST_CASE_LIMIT_SEC" ]; then
  echo "✗ ci-wait：--max-minutes ${max_minutes}（${max_seconds}s）＋--interval ${interval}s＋gh 逾時緩衝 $((3 * GH_TIMEOUT_SEC))s ≈ ${worst_seconds}s，逼近或超過 Bash 工具 600s 硬上限（門檻 ${WORST_CASE_LIMIT_SEC}s）——調小 --max-minutes 或 --interval。" >&2
  exit 2
fi

command -v gh >/dev/null 2>&1 || { echo "✗ ci-wait：需要 gh（brew install gh）" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "✗ ci-wait：需要 jq" >&2; exit 2; }

start_ts=$(date +%s)
fail_streak=0
last_json=

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

timeout_exit() {
  local elapsed=$1
  local job_flag=""
  [ -n "$job_name" ] && job_flag=" --job ${job_name}"
  echo "仍在跑：已耗時 $((elapsed / 60)) 分 $((elapsed % 60)) 秒／再跑一次 bash scripts/ops/ci-wait.sh ${run_id}${job_flag}" >&2
  [ -n "$last_json" ] && print_jobs "$last_json"
  exit 3
}

while :; do
  now_ts=$(date +%s)
  elapsed=$((now_ts - start_ts))
  # MUTATION-TIMEOUT-START（ci-wait.test.sh 的 mutation 案例用 awk 拿掉這段：少了逾時退出，遇到「一直
  # 在跑」或「間歇性 gh 失敗」的夾具都會無窮迴圈——自測藉此證明這段就是「仍在跑就乖乖退出」行為的來源。
  # R2：這個檢查點在迴圈最前面、呼叫 gh 之前，成功／失敗兩個分支都會先經過這裡，不再只有成功分支才比對
  # elapsed——這正是 B1 的修法本身，拿掉這段等於連同失敗分支的逾時保護一起消失。）
  if [ "$elapsed" -ge "$max_seconds" ]; then
    timeout_exit "$elapsed"
  fi
  # MUTATION-TIMEOUT-END

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
  last_json=$json

  status=$(printf '%s' "$json" | jq -r '.status // empty')

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

  sleep "$interval"
done
