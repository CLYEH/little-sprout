#!/bin/bash
# PreToolUse fail-closed gate（LS-154）：擋 agent 寫入主 checkout。與 pretool.sh（LS-88／LS-104）
# 同型——bash 只做「讀 stdin → 呼叫 python 引擎 → fail-closed 轉譯」，判定規則 W0–W5 全部在
# scripts/hooks/main_checkout_guard.py（檔頭有完整規則表、盲區、開關說明）。
#
# 註冊：.claude/settings.json PreToolUse matcher `Bash|Write|Edit|MultiEdit|NotebookEdit`
#（獨立一條，與 pretool.sh 的 `Bash|Read|Grep` 並列，只加不刪）。
#
# deny：stdout `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
#   "permissionDecisionReason":"W<n>：…"}}`（python 端印）＋stderr 同一句理由，exit 2。允許：exit 0。
# fail-closed：`RESPONDED` 旗標＋`trap on_exit EXIT`，任何未預期中止一律 deny；stdin 空、python3
#   缺席、引擎檔缺席、引擎以非 0/2 結束 → deny。
# 已知盲區見 main_checkout_guard.py 檔頭與 docs/COLLABORATION.md §7。
set -u

RESPONDED=
COLL_REF="docs/COLLABORATION.md §7"

json_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
}

final_deny() {
  json_deny "$1"
  printf '%s\n' "$1" >&2
  RESPONDED=1
  exit 2
}

final_allow() {
  RESPONDED=1
  exit 0
}

on_exit() {
  if [ -z "$RESPONDED" ]; then
    json_deny "W0：main-checkout-guard.sh 未預期中止（fail-closed，見 ${COLL_REF}）"
    exit 2
  fi
}
trap on_exit EXIT

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR="."
GUARD_PY="${SCRIPT_DIR}/main_checkout_guard.py"

input=
IFS= read -r -d '' input || true
[ -n "$input" ] || final_deny "W0：stdin 是空的，無法判斷 tool_input（fail-closed），見 ${COLL_REF}"

command -v python3 >/dev/null 2>&1 || final_deny "W0：python3 不存在，無法執行主 checkout 寫入判定（fail-closed），見 ${COLL_REF}"
[ -f "$GUARD_PY" ] || final_deny "W0：main_checkout_guard.py 不存在（fail-closed），見 ${COLL_REF}"

# stderr 直接透傳（deny 理由／放行註記給 Claude 看）；stdout 只在 deny 時有 JSON。
out=$(printf '%s' "$input" | python3 "$GUARD_PY")
rc=$?
case "$rc" in
  0) final_allow ;;
  2)
    [ -n "$out" ] || out=$(json_deny "W0：主 checkout 判定回傳 deny 但無理由文字（fail-closed），見 ${COLL_REF}")
    printf '%s' "$out"
    RESPONDED=1
    exit 2
    ;;
  *) final_deny "W0：main_checkout_guard.py 執行異常（rc=${rc}），fail-closed，見 ${COLL_REF}" ;;
esac
