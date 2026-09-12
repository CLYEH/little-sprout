#!/bin/bash
# PreToolUse fail-closed gate（LS-239 範圍 2）：擋 orchestrator（主 session）直接 Read／Bash
# 讀取 `tasks/*.output` 或超過約 4 KB 又無 offset／limit 的檔案，強制改派 Explore subagent
# 讀完回結論。與 pretool.sh（LS-88／LS-104）、background-bash-guard.sh（LS-215）同型——bash
# 只做「讀 stdin → 呼叫 python 引擎 → fail-closed 轉譯」，判定規則全部在
# scripts/hooks/large_file_read_guard.py（檔頭有完整規則表、身分信號來源、已知盲區）。
#
# 註冊：.claude/settings.json PreToolUse matcher `Bash|Read`（獨立一條，與 pretool.sh 的
# `Bash|Read|Grep`、main-checkout-guard.sh 的 `Bash|Write|Edit|MultiEdit|NotebookEdit`、
# background-bash-guard.sh 的 `Bash` 並列，只加不刪）。
#
# deny：stdout `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
#   "permissionDecisionReason":"H-LF<n>：…"}}`，exit 2。允許：exit 0、無輸出。
# fail-closed：`RESPONDED` 旗標＋`trap on_exit EXIT`；stdin 空、python3 缺席、引擎檔缺席、引擎以
#   非 0/2 結束 → deny。已知盲區與身分信號驗證方法見 large_file_read_guard.py 檔頭與
#   docs/COLLABORATION.md §7。
set -u

RESPONDED=
COLL_REF="docs/COLLABORATION.md §7"

json_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
}

final_deny() {
  json_deny "$1"
  RESPONDED=1
  exit 2
}

final_allow() {
  RESPONDED=1
  exit 0
}

on_exit() {
  if [ -z "$RESPONDED" ]; then
    json_deny "H-LF0：large-file-read-guard.sh 未預期中止（fail-closed，見 ${COLL_REF}）"
    exit 2
  fi
}
trap on_exit EXIT

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR="."
ENGINE_PY="${SCRIPT_DIR}/large_file_read_guard.py"

# ---- 讀 stdin：用內建 `read -d ''`，不倚賴外部 cat（PATH 淨空時仍要撐到這裡；同其餘 hook）----
input=
IFS= read -r -d '' input || true
[ -n "$input" ] || final_deny "H-LF0：stdin 是空的，無法判斷 tool_input（fail-closed），見 ${COLL_REF}"

command -v python3 >/dev/null 2>&1 || final_deny "H-LF0：python3 不存在，無法執行 LS-239 命令評估引擎（fail-closed），見 ${COLL_REF}"
[ -f "$ENGINE_PY" ] || final_deny "H-LF0：large_file_read_guard.py 不存在（fail-closed），見 ${COLL_REF}"

# run rc：0＝allow；2＝deny（stdout 是理由文字，這裡才包成 JSON）；其他＝執行異常，fail-closed。
# stderr 直接透傳（身分不明的 fail-open 註記要給 Claude 看，同 background-bash-guard.sh 的既有慣例）。
out=$(printf '%s' "$input" | python3 "$ENGINE_PY")
rc=$?
case "$rc" in
  0) final_allow ;;
  2)
    [ -n "$out" ] || out="H-LF0：命令評估引擎回傳 deny 但無理由文字（fail-closed），見 ${COLL_REF}"
    final_deny "$out"
    ;;
  *) final_deny "H-LF0：large_file_read_guard.py 執行異常（rc=${rc}），fail-closed，見 ${COLL_REF}" ;;
esac
