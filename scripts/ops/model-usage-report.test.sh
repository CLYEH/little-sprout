#!/bin/bash
# model-usage-report.py 的自測（LS-353）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對這支估值腳本也適用：若牌價對表退回「第一個前綴相符」（Opus 5.5 被算成 Opus 5 的價，
# LS-350 scratchpad 原版的 bug）、同一 message.id 重複計、meta.json 的 agentType 沒讀到、未知 model 靜默
# 記 0、或 --days 視窗失效——這裡會紅。
# 夾具：CLAUDE_CONFIG_DIR 指到暫存目錄，projects/<由本 repo git-common-dir 推導的 slug>/ 下放假 jsonl。
# 數值設計成整百萬 token，估值可心算：
#   main（fable-5-1）output 1M ×2 turns＝$100.00；ios-dev（opus-5-5）同一 id 兩行（串流中途 output 3、終值 1M），
#   以最後一行為準＝$20.00，且只計 1 turn（R1 M1：first-wins 會變 $0.00）；
#   qa（sonnet-5，無 meta、靠 prompt）cache read 10M＝$2.00；unknown model 記 0 並列出；過期檔不計。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../gates/lib/selftest-helpers.sh
source "${root}/scripts/gates/lib/selftest-helpers.sh"
script="${root}/scripts/ops/model-usage-report.py"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cfg="$work/cfg"
common="$(cd "$root" && git rev-parse --path-format=absolute --git-common-dir)"
slug="$(printf '%s' "$(dirname "$common")" | sed 's/[^A-Za-z0-9]/-/g')"
proj="$cfg/projects/$slug"

# turn <id> <model> <out tokens> [cache read tokens]
turn() { printf '{"type":"assistant","message":{"id":"%s","model":"%s","usage":{"input_tokens":0,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' "$1" "$2" "$3" "${4:-0}"; }
user() { printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$1"; }

reset() {
  rm -rf "$cfg"; mkdir -p "$proj/s1/subagents"
  { user "hi"; turn f1 claude-fable-5-1 1000000; turn f2 claude-fable-5-1 1000000; } > "$proj/s1.jsonl"
  f="$proj/s1/subagents/agent-a.jsonl"
  { user "Ticket"; turn o1 claude-opus-5-5 3; turn o1 claude-opus-5-5 1000000; } > "$f"
  printf '{"agentType":"ios-dev"}\n' > "${f%.jsonl}.meta.json"
  { user "你是 qa"; turn q1 claude-sonnet-5 0 10000000; } > "$proj/s1/subagents/agent-b.jsonl"
  { user "x"; turn u1 claude-mystery-9 1000000; } > "$proj/s1/subagents/agent-c.jsonl"
  f="$proj/s1/subagents/agent-old.jsonl"
  { user "old"; turn z1 claude-opus-5 1000000; } > "$f"
  python3 -c 'import os,sys,time; t=time.time()-30*86400; os.utime(sys.argv[1],(t,t))' "$f"
}

run() { out="$(cd "$root" && CLAUDE_CONFIG_DIR="$cfg" python3 "${SCRIPT:-$script}" "$@" 2>&1)"; rc=$?; }
line() { grep -E "^$1 " <<<"$out" | head -1; }

reset; run
expect_exit 0 "$rc" '① 正常跑 → exit 0'
expect_has "$out" 'files=4 days=14' '① 過期檔不計（4 檔）'
expect_has "$(line claude-opus-5-5)" ' 20.00' '① opus-5-5 以自己的牌價計（$20，非 opus-5 的 $25）'
expect_has "$(line claude-opus-5-5)" '       1 ' '① 重複 message.id 只計 1 turn、以最後一行 usage 為準'
expect_has "$(line claude-fable-5-1)" ' 100.00' '① fable-5-1 output 2M＝$100'
expect_has "$(line claude-sonnet-5)" ' 2.00' '① sonnet-5 cache read 10M＝$2'
expect_has "$(line TOTAL)" ' 122.00' '① TOTAL＝122（未知 model 記 0）'
expect_has "$out" '牌價表無此 model、估值記 0：claude-mystery-9' '① 未知 model 明列不靜默'
expect_has "$(line subagent:ios-dev)" ' 20.00' '② meta.json agentType 歸到 subagent:ios-dev'
expect_has "$(line subagent:qa)" ' 2.00' '② 無 meta 退回 prompt 辨識 subagent:qa'
expect_has "$(line main)" ' 100.00' '② 主 session 記 main'
expect_has "$out" 'subagent:?' '② 認不出的 subagent 記 subagent:?'

run --days 60
expect_has "$out" 'files=5 days=60' '③ --days 60 納入過期檔'

rm -rf "$cfg"; run
expect_exit 1 "$rc" '④ 專案目錄不存在 → exit 1'
expect_has "$out" '找不到專案 transcript 目錄' '④ 說明找不到專案目錄'

# ---- mutation ----
mut() { # mut <sed 表達式> <case 名> <輸出中不該再出現的字樣（出現＝mutation 沒被抓）>
  local m="$work/mut.py"; sed "$1" "$script" > "$m"
  if cmp -s "$m" "$script"; then fail "${2}（mutation 沒有改到任何字，sed 表達式失效）"; return; fi
  reset; SCRIPT="$m" run
  if has "$(line "$4")" "$3"; then fail "${2}（mutation 後仍綠）"; else ok "$2"; fi
}
mut 's/ and (best is None or len(k) > len(best\[0\]))/ and best is None/' 'M1 牌價改回第一個前綴相符 → opus-5-5 估值錯' ' 20.00' claude-opus-5-5
mut 's/pending\[mid\] = entry/pending.setdefault(mid, entry)/' 'M2 同 id 改回 first-wins（留串流中途值）→ opus-5-5 估值錯' ' 20.00' claude-opus-5-5
mut 's/pending\[mid\] = entry/rows.append(entry)/' 'M4 不去重 message.id → turn 數變 2' '       1 ' claude-opus-5-5
mut 's/t = agent_from_meta(path)/t = None/' 'M3 不讀 meta.json → ios-dev 列消失' ' 20.00' subagent:ios-dev

n=${selftest_helpers_n}
if [ "${selftest_helpers_fail}" -ne 0 ]; then
  echo "✗ model-usage-report 自測失敗" >&2
  exit 1
fi
echo "✓ model-usage-report 自測全綠（${n} 組）"
