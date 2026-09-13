#!/bin/bash
# PreToolUse fail-open gate（LS-254）：擋 worker agent（非主 session，hook JSON 頂層有 `agent_id`）派
# `subagent_type: fork` 的 Agent 呼叫——fork 繼承整份派工單並平行執行整項任務（LS-234 R7 同一 .pen／
# branch 雙寫；LS-188／LS-192 越權改檔）。與 large-file-read-guard.sh（LS-239）同型——bash 只做「讀
# stdin → 呼叫 python 引擎 → 轉譯」，判定規則全部在 scripts/hooks/fork_guard.py（檔頭有規則、身分判準、
# fail-open 理由、已知盲區）。
#
# 註冊：.claude/settings.json PreToolUse matcher `Agent`（獨立一條，與既有四條並列，只加不刪；**不接
# `|| exit 2`**——本 gate 極性是 fail-open，wiring 層也不把「腳本本身跑不起來」轉成 deny）。
#
# deny：stdout `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
#   "permissionDecisionReason":"LS-254：…"}}`＋stderr 同一行理由，exit 2。允許：exit 0、無 stdout。
# fail-open（票文明示，與 pretool.sh／large-file-read-guard.sh 相反）：stdin 空、python3 缺席、引擎檔缺席、
#   引擎以非 0/2 結束、JSON 壞 → exit 0 並 stderr 註明原因（理由見 fork_guard.py 檔頭：fail-closed 會讓
#   任一次解析失敗變成整條產線派不出任何 agent）。
set -u

COLL_REF="docs/COLLABORATION.md §7"

json_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
}

fail_open() {
  echo "fork-guard：$1，fail-open 放行（見 ${COLL_REF}）" >&2
  exit 0
}

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR="."
ENGINE_PY="${SCRIPT_DIR}/fork_guard.py"

# ---- 讀 stdin：用內建 `read -d ''`，不倚賴外部 cat（同其餘 hook）----
input=
IFS= read -r -d '' input || true
[ -n "$input" ] || fail_open "stdin 是空的，無法判斷 tool_input"

command -v python3 >/dev/null 2>&1 || fail_open "python3 不存在，無法執行 fork_guard.py"
[ -f "$ENGINE_PY" ] || fail_open "fork_guard.py 不存在"

# run rc：0＝allow；2＝deny（stdout 是理由文字，這裡才包成 JSON＋stderr 同一行）；其他＝執行異常，fail-open。
# 引擎的 stderr 直接透傳（身分不明／解析失敗的 fail-open 註記要給 Claude 看）。
out=$(printf '%s' "$input" | python3 "$ENGINE_PY")
rc=$?
case "$rc" in
  0) exit 0 ;;
  2)
    [ -n "$out" ] || out="LS-254：worker agent 禁派 fork（引擎未回傳理由文字）；研究改派 Explore（唯讀）"
    json_deny "$out"
    echo "$out" >&2
    exit 2
    ;;
  *) fail_open "fork_guard.py 執行異常（rc=${rc}）" ;;
esac
