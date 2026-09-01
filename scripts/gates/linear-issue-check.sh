#!/bin/bash
# scripts/gates/linear-issue-check.sh（LS-77）
#
# PreToolUse gate：matcher `mcp__linear__save_issue`（.claude/settings.json），讀 stdin 的
# hook JSON（`tool_input` 即 save_issue 呼叫的參數）。只在**建票**（tool_input 無 `id`）時
# 生效，四條規則對應 docs/COLLABORATION.md §3「開票結構」／§5-b（LS-75 lane 標籤）：
#   A：缺 `project`                              → deny（Project＝epic，開票必帶）
#   B：`project` 以 "Phase" 開頭且缺 `milestone`  → deny（Milestone＝feature 群）
#   C：`title` 以「Task：」／「Task:」開頭且缺 `parentId` → deny（Sub-issue＝task 須掛 parent）
#   D：`labels` 內 `lane:*` 標籤數 ≠ 1             → deny（§5-b 每張票必帶恰一個 lane 標籤）
# 更新既有票（`tool_input.id` 非空）一律放行——避免改狀態／改其他欄位被誤攔（票文明定）。
#
# fail-closed（同 scripts/hooks/pretool.sh 慣例）：空 stdin／JSON 解析失敗（jq 與 python3
# 皆失敗、或兩者皆不存在於 PATH）／腳本自身中途未預期中止（trap on_exit EXIT），一律 deny。
#
# deny 輸出：{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
#   "permissionDecisionReason":"…見 docs/COLLABORATION.md §3"}}，exit 2；允許＝exit 0 無輸出
#   （Claude Code 的 PreToolUse hook 只認 exit 2 為 deny，其餘視為放行）。
#
# reason 只放本檔案自己寫的靜態文字，不回顯 tool_input 裡的任何欄位值（project 名稱／票標題等
# 使用者可控內容一律不帶進 reason），故組字串不需要跑時對它們做 JSON escaping（同 pretool.sh
# json_deny 的既有設計原則）。
#
# 自測：scripts/gates/linear-issue-check.test.sh（六情境＋labels 過多＋fail-closed 三態＋
# 四條 deny 規則各一個 mutant 負控），掛 CI rules job。
#
# 已知盲區：使用者在 Linear UI 手動建票不經此 hook（見 docs/COLLABORATION.md §7／LS-77 票文
# 「盲區」段）——由巡檢 `scripts/ops/patrol_linear.py` 的 `ticket_structure()`（開票結構
# (a)-(e)）補抓，見 §4-b／§7。hook 本身需 `/hooks` 或重啟 session 才會載入 .claude/settings.json
# 的新 matcher（本檔案改完當次 session 仍照舊放行）。
set -u

RESPONDED=
COLL_REF="docs/COLLABORATION.md §3"

# ---- 建 deny JSON（reason 只放本檔案自己寫的靜態文字，不帶使用者輸入，故不需跑時逸出）----
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
    json_deny "LS-77：linear-issue-check.sh 未預期中止（fail-closed），見 ${COLL_REF}"
    exit 2
  fi
}
trap on_exit EXIT

# ---- 讀 stdin：內建 `read -d ''`，不倚賴外部 cat（同 pretool.sh）----
input=
IFS= read -r -d '' input || true

[ -n "$input" ] || final_deny "LS-77：stdin 是空的，無法判斷 tool_input（fail-closed），見 ${COLL_REF}"

# ---- 解析 JSON：jq 優先，缺才退 python3；兩者都解不出（缺工具或 JSON 壞）→ deny ----
# 六個欄位：id／project／milestone／title／parentId／labels（逗號合併——lane／size 標籤名稱
# 本身不含逗號，足夠安全；同 pretool.sh 用 \x1f 當欄位分隔字元，避免與欄位值本身的分隔符衝突）。
SEP=$'\x1f'
parsed=0

if command -v jq >/dev/null 2>&1; then
  if out=$(printf '%s' "$input" | jq -r --arg sep "$SEP" '
      [
        (.tool_input.id // "" | tostring),
        (.tool_input.project // "" | tostring),
        (.tool_input.milestone // "" | tostring),
        (.tool_input.title // "" | tostring),
        (.tool_input.parentId // "" | tostring),
        ((.tool_input.labels // []) | if type == "array" then join(",") else error("labels 不是陣列") end)
      ] | map(gsub($sep; " ")) | join($sep)
    ' 2>/dev/null); then
    IFS="$SEP" read -r idv projectv milestonev titlev parentidv labelsv <<<"$out" || true
    labelsv=${labelsv%$'\n'}
    parsed=1
  fi
fi

if [ "$parsed" -ne 1 ] && command -v python3 >/dev/null 2>&1; then
  if out=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    if not isinstance(d, dict):
        raise ValueError("top-level not object")
    ti = d.get("tool_input")
    if not isinstance(ti, dict):
        ti = {}
    labels = ti.get("labels")
    if labels is None:
        labels = []
    if not isinstance(labels, list):
        raise ValueError("labels not a list")
    labels_str = ",".join(str(x) for x in labels)
except Exception:
    sys.exit(1)
def esc(s):
    return str(s).replace("\x1f", " ")
fields = [ti.get("id") or "", ti.get("project") or "", ti.get("milestone") or "", ti.get("title") or "", ti.get("parentId") or "", labels_str]
sys.stdout.write("\x1f".join(esc(f) for f in fields))
' 2>/dev/null); then
    IFS="$SEP" read -r idv projectv milestonev titlev parentidv labelsv <<<"$out" || true
    labelsv=${labelsv%$'\n'}
    parsed=1
  fi
fi

[ "$parsed" -eq 1 ] || final_deny "LS-77：jq／python3 皆無法解析 tool_input（缺工具或 JSON 壞），見 ${COLL_REF}"

# 更新既有票（有 id）一律放行——票文明定：避免改狀態／改其他欄位被誤攔。
if [ -n "${idv:-}" ]; then
  final_allow
fi

# ---- RULE-A-START：缺 project → deny ----
if [ -z "${projectv:-}" ]; then
  final_deny "LS-77：建票缺 project（§3 開票結構：Project＝epic，開票必帶），見 ${COLL_REF}"
fi
# ---- RULE-A-END ----

# ---- RULE-B-START：project 以 Phase 開頭且缺 milestone → deny ----
case "${projectv:-}" in
  Phase*)
    if [ -z "${milestonev:-}" ]; then
      final_deny "LS-77：Phase 專案票缺 milestone（§3 開票結構：Milestone＝feature 群），見 ${COLL_REF}"
    fi
    ;;
esac
# ---- RULE-B-END ----

# ---- RULE-C-START：title 以「Task：」／「Task:」開頭且缺 parentId → deny ----
case "${titlev:-}" in
  'Task：'*|'Task:'*)
    if [ -z "${parentidv:-}" ]; then
      final_deny "LS-77：Task 票缺 parentId（§3 開票結構：Sub-issue＝task 須掛 parent），見 ${COLL_REF}"
    fi
    ;;
esac
# ---- RULE-C-END ----

# ---- RULE-D-START：labels 內 lane:* 標籤數須恰為 1 → deny（§5-b，LS-75）----
lane_count=0
if [ -n "${labelsv:-}" ]; then
  old_ifs=$IFS
  IFS=','
  for l in ${labelsv}; do
    case "$l" in
      lane:*) lane_count=$((lane_count + 1)) ;;
    esac
  done
  IFS=$old_ifs
fi
if [ "$lane_count" -ne 1 ]; then
  final_deny "LS-77：labels 需恰一個 lane:* 標籤（§5-b 每張票必帶一個 lane 標籤），見 ${COLL_REF}"
fi
# ---- RULE-D-END ----

final_allow
