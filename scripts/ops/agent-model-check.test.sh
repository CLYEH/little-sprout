#!/bin/bash
# agent-model-check.sh 的自測（LS-353）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對這支查詢腳本也適用：若它挑錯「最近一次」（比對方向寫反、只看單一檔）、忽略
# meta.json 的 agentType 改回只靠 prompt 猜、effort 欄位抓錯或沒有時不明說、--days 視窗失效、
# 專案 slug 推導錯、或用法錯誤沒有 exit 2——這裡會紅。
# 夾具：CLAUDE_CONFIG_DIR 指到暫存目錄，在 projects/<由本 repo git-common-dir 推導的 slug>/ 下放假 jsonl／
# meta.json；腳本本身在本 repo 內執行，slug 推導走真的 git。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../gates/lib/selftest-helpers.sh
source "${root}/scripts/gates/lib/selftest-helpers.sh"
script="${root}/scripts/ops/agent-model-check.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cfg="$work/cfg"
common="$(cd "$root" && git rev-parse --path-format=absolute --git-common-dir)"
slug="$(printf '%s' "$(dirname "$common")" | sed 's/[^A-Za-z0-9]/-/g')"
proj="$cfg/projects/$slug"

# asst <ts> <model> [extra-json-fields]：一行 assistant turn
asst() { printf '{"type":"assistant","timestamp":"%s","message":{"id":"m-%s","model":"%s","usage":{}}%s}\n' "$1" "$1" "$2" "${3:-}"; }
user() { printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$1"; }
meta() { printf '{"agentType":"%s"}\n' "$2" > "${1%.jsonl}.meta.json"; }

reset() {
  rm -rf "$cfg"; mkdir -p "$proj/s1/subagents" "$proj/s2/subagents"
  # s1：ios-dev（meta），兩個 turn，後者較新、effort high
  f="$proj/s1/subagents/agent-a1.jsonl"
  { user "Ticket LS-1 實作"; asst 2026-09-20T01:00:00Z claude-sonnet-5 ',"effort":"medium"'
    asst 2026-09-20T02:00:00Z claude-opus-5-5 ',"effort":"high","perTurnEffort":"high"'; } > "$f"; meta "$f" ios-dev
  # s2：另一支 ios-dev，比 s1 舊——跨檔取最新必須挑 s1 的 02:00
  f="$proj/s2/subagents/agent-b1.jsonl"
  { user "Ticket LS-2"; asst 2026-09-19T05:00:00Z claude-sonnet-5; } > "$f"; meta "$f" ios-dev
  # meta 說 merge-reviewer、prompt 卻提到 ios-dev——必須算 merge-reviewer，不算 ios-dev（且時間最新，若誤算會被挑中）
  f="$proj/s2/subagents/agent-b2.jsonl"
  { user "審 ios-dev 的 PR"; asst 2026-09-21T09:00:00Z claude-opus-5 ',"effort":"high"'; } > "$f"; meta "$f" merge-reviewer
  # 無 meta：prompt 含 qa；effort 只在 message.output_config
  f="$proj/s2/subagents/agent-b3.jsonl"
  { user "你是 qa，驗收 LS-3"; printf '{"type":"assistant","timestamp":"2026-09-18T00:00:00Z","message":{"model":"claude-opus-5-5","output_config":{"effort":"low"}}}\n'; } > "$f"
  # 無任何 effort 欄的 ui-designer
  f="$proj/s2/subagents/agent-b4.jsonl"
  { user "設計"; asst 2026-09-17T00:00:00Z claude-sonnet-5; } > "$f"; meta "$f" ui-designer
  # 過期檔（mtime 30 天前）的 visual-reviewer
  f="$proj/s2/subagents/agent-b5.jsonl"
  { user "審稿"; asst 2026-08-01T00:00:00Z claude-opus-5; } > "$f"; meta "$f" visual-reviewer
  python3 -c 'import os,sys,time; t=time.time()-30*86400; os.utime(sys.argv[1],(t,t))' "$f"
  # 主 session 檔（不在 subagents/）不得被當成 agent
  { user "ios-dev"; asst 2026-09-22T00:00:00Z claude-fable-5-1; } > "$proj/s1.jsonl"
}

run() { out="$(cd "$root" && CLAUDE_CONFIG_DIR="$cfg" bash "${SCRIPT:-$script}" "$@" 2>&1)"; rc=$?; }

reset
run ios-dev
expect_exit 0 "$rc" '① ios-dev 找得到 → exit 0'
expect_has "$out" 'model：claude-opus-5-5' '① 跨檔取最新 turn（s1 02:00 的 opus-5-5）'
expect_has "$out" 'effort：effort=high  perTurnEffort=high' '① 印頂層 effort／perTurnEffort'
expect_has "$out" '時間：2026-09-20T02:00:00Z' '① 時間戳為最新那筆'
expect_has "$out" 'agent-a1.jsonl' '① 印檔路徑'
expect_has "$out" '來源：meta.json' '① 標明 agent 來源 meta.json'
expect_not_has "$out" '時間：2026-09-21' '① 不把 meta=merge-reviewer 的檔算成 ios-dev'
expect_not_has "$out" 'fable' '① 主 session 檔不當 agent'

run merge-reviewer
expect_has "$out" 'model：claude-opus-5' '② meta agentType 優先於 prompt 字樣'

run qa
expect_exit 0 "$rc" '③ 無 meta 時退回 prompt 辨識 → exit 0'
expect_has "$out" '來源：prompt' '③ 標明來源 prompt'
expect_has "$out" 'output_config.effort=low' '③ 印 message.output_config.effort'

run ui-designer
expect_has "$out" 'effort：transcript 無 effort 欄' '④ 無 effort 欄時明說'

run visual-reviewer
expect_exit 1 "$rc" '⑤ 過期檔（30 天前）在預設 14 天外 → exit 1'
run visual-reviewer --days 60
expect_exit 0 "$rc" '⑤ --days 60 納入 → exit 0'

run dead-code-sweeper
expect_exit 1 "$rc" '⑥ 找不到 agent → exit 1'
expect_has "$out" '找不到 agent「dead-code-sweeper」' '⑥ 找不到時說明'

run
expect_exit 2 "$rc" '⑦ 缺 agent 名 → exit 2'
run ios-dev --days abc
expect_exit 2 "$rc" '⑦ --days 非數字 → exit 2'
run ios-dev qa
expect_exit 2 "$rc" '⑦ 兩個 agent 名 → exit 2'
run ios-dev --bogus
expect_exit 2 "$rc" '⑦ 未知旗標 → exit 2'

rm -rf "$cfg"; mkdir -p "$cfg/projects/-wrong-slug"
run ios-dev
expect_exit 1 "$rc" '⑧ 專案 slug 目錄不存在 → exit 1'
expect_has "$out" '找不到專案 transcript 目錄' '⑧ 說明找不到專案目錄'

# ---- mutation：改壞腳本必須紅 ----
mut() { # mut <sed 表達式> <case 名> <期望在輸出中的字樣>
  local m="$work/mut.sh"; sed "$1" "$script" > "$m"
  if cmp -s "$m" "$script"; then fail "${2}（mutation 沒有改到任何字，sed 表達式失效）"; return; fi
  reset; SCRIPT="$m" run ios-dev
  if has "$out" "$3"; then fail "${2}（mutation 後仍綠：輸出含「${3}」）"; else ok "$2"; fi
}
mut 's/ts >= best\[0\]/ts <= best[0]/' 'M1 最新比對方向反轉 → ① 紅' '時間：2026-09-20T02:00:00Z'
mut 's/if os.path.exists(meta):/if False:/' 'M2 不讀 meta.json → 來源不再是 meta' '來源：meta.json'
mut 's/"subagents", "\*.jsonl"/"*.jsonl"/' 'M3 不限 subagents/ → 主 session 被誤算（最新 turn 變 fable）' 'model：claude-opus-5-5'

n=${selftest_helpers_n}
if [ "${selftest_helpers_fail}" -ne 0 ]; then
  echo "✗ agent-model-check 自測失敗" >&2
  exit 1
fi
echo "✓ agent-model-check 自測全綠（${n} 組）"
