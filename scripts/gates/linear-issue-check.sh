#!/bin/bash
# scripts/gates/linear-issue-check.sh（LS-77／LS-79）
#
# PreToolUse gate：matcher `mcp__linear__save_issue`（.claude/settings.json），讀 stdin 的
# hook JSON（`tool_input` 即 save_issue 呼叫的參數）。規則 A-D 只在**建票**（tool_input 無
# `id`）時生效，對應 docs/COLLABORATION.md §3「開票結構」／§5-b（LS-75 lane 標籤）：
#   A：缺 `project`                              → deny（Project＝epic，開票必帶）
#   B：`project` 以 "Phase" 開頭且缺 `milestone`  → deny（Milestone＝feature 群）
#   C：`title` 以「Task：」／「Task:」開頭且缺 `parentId` → deny（Sub-issue＝task 須掛 parent）
#   D：`labels` 內 `lane:*` 標籤數 ≠ 1             → deny（§5-b 每張票必帶恰一個 lane 標籤）
# 更新既有票（`tool_input.id` 為非空**字串**）對 A-D 一律放行——避免改狀態／改其他欄位被誤攔
# （LS-77 票文明定）。
#
# 規則 E（LS-79，docs/COLLABORATION.md §5-c）：`state` 為 `Ready` 或（僅限建票時）
# `In Progress` 且未帶 `cycle` → deny（派工必進 cycle）。**R1 merge-review 混合案**（PR #216
# comment `7377158a`，orchestrator 拍板；票文原字面是兩狀態、建票與更新票皆驗，此處是有實證
# 依據的偏離，見 §5-c 修訂理由）：
#   - `Ready`：建票與更新票皆套用——`Ready` 是 unstarted，Linear「active 票自動加入當前
#     cycle」（G2）不涵蓋這個狀態，這裡是唯一防線，有真實攔截價值。
#   - `In Progress`：**只在建票**（`tool_input` 無合法字串 `id`）時套用；更新既有票改成
#     `In Progress` 不驗——594 筆歷史 `save_issue` 流量回放顯示 82 筆會被 Rule E 誤攔，其中
#     61 筆是「更新票改 In Progress」這個 orchestrator 日常派工形狀，且未違反實質不變量：
#     G2（Linear Team Settings 自動把 active 票加進當前 cycle）對 `started` 狀態確實生效
#     （LS-112 實測：全流量從未傳 cycle，`cycleId` 仍正確），加上 G3 (a)（`cycle_reconciliation()`
#     每 26 分鐘兜底）已守住不變量——這條分支的邊際效益趨近於零，代價是每次派工多一次
#     round-trip。
# `state` 未出現在這次 `tool_input`（沒有要改狀態）或值不是上述情況（含 `Backlog`／`Done`／
# 其他），皆不觸發，交由 A-D 的既有放行規則處理。故意排在「有 id 就放行」與 A-D 之前判斷。
# deny reason 教可執行修法（去哪裡查當前 cycle 編號），不暗示照抄字面數字——歷史流量 60 筆
# 都是字面 `cycle:"1"`，換 cycle 後沿用這個字面值會把在飛票寫進已結束的 cycle。
#
# cycle 正規化（LS-79，池項 F6）：JSON 數字 `0`（或字面 `"0"`）與純空白字串視同未帶
# `cycle`——jq 的 `// ""` 對數字 `0` 視為真值、python3 的 `or ""` 視為假值，兩條解析路徑原本
# 對同一份 payload 判決不同（cycle 編號從 1 起，`0` 從來不是合法值）；純空白字串兩路徑原本
# 都放行。在 bash 層統一正規化一次，不必在 jq／python3 兩處各自維護同款邏輯。
#
# `id` 型別防呆（LS-79，池項 F6）：`tool_input.id` 只有在是 **JSON 字串**時才算「有 id」；
# 傳 `{}`／`[]`（物件／陣列）等非字串型別視同沒有 id（仍走建票的完整規則），避免用型別
# 混淆繞過 A-D。
#
# fail-closed（同 scripts/hooks/pretool.sh 慣例）：空 stdin／JSON 解析失敗（jq 與 python3
# 皆失敗、或兩者皆不存在於 PATH）／腳本自身中途未預期中止（trap on_exit EXIT），一律 deny。
#
# deny 輸出：{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
#   "permissionDecisionReason":"…見 docs/COLLABORATION.md §3／§5-c"}}，exit 2；允許＝exit 0
#   無輸出（Claude Code 的 PreToolUse hook 只認 exit 2 為 deny，其餘視為放行）。
#
# reason 只放本檔案自己寫的靜態文字，不回顯 tool_input 裡的任何欄位值（project 名稱／票標題等
# 使用者可控內容一律不帶進 reason），故組字串不需要跑時對它們做 JSON escaping（同 pretool.sh
# json_deny 的既有設計原則）。
#
# 自測：scripts/gates/linear-issue-check.test.sh（八情境＋labels 過多＋id 型別防呆兩組＋
# state／cycle 交界情境（Ready 建票／更新各自 deny＋allow；In Progress 建票 deny／更新
# allow——混合案的核心交界；state 缺席＋state 非 Ready/In Progress 皆不觸發；cycle 正規化
# 0／純空白）＋fail-closed 三態＋settings.json 接線斷言＋trap 移除 mutation 負控＋`-d ''`
# 修法負控（title 含換行）＋五條 deny 規則各一個 mutant 負控），掛 CI rules job。
#
# 已知盲區：使用者在 Linear UI 手動建票／改狀態不經此 hook（見 docs/COLLABORATION.md §7／
# LS-77 票文「盲區」段）——開票結構 (a)-(e) 由巡檢 `scripts/ops/patrol_linear.py` 的
# `ticket_structure()` 補抓；cycle 規則（本檔案規則 E）由同檔 `cycle_reconciliation()` 的
# (a) 段補抓（active 票不在當前 cycle → 列出並 `save_issue cycle=` 補加），見 §4-b／§5-c／
# §7。**已知且刻意接受的缺口**（R1 混合案）：更新票改 `In Progress` 不經本規則驗 cycle，
# 完全靠 G2（Linear 自動把 active 票加進當前 cycle）＋G3 (a)（26 分鐘兜底）——不是本檔案
# 的攔截範圍，見上方規則 E 註解與 §5-c 修訂理由。hook 本身需 `/hooks` 或重啟 session 才會
# 載入 .claude/settings.json 的新 matcher（本檔案改完當次 session 仍照舊放行）。
set -u

RESPONDED=
COLL_REF="docs/COLLABORATION.md §3"
COLL_REF_CYCLE="docs/COLLABORATION.md §5-c"

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
# 八個欄位：id／project／milestone／title／parentId／labels（逗號合併——lane／size 標籤名稱
# 本身不含逗號，足夠安全）／state／cycle（LS-79 新增，用於規則 E）；同 pretool.sh 用 \x1f
# 當欄位分隔字元，避免與欄位值本身的分隔符衝突；`read -d ''`（NUL 分隔，同 pretool.sh:182）
# 取代預設換行分隔，讓欄位值裡的換行不會被截斷（LS-104 R1 F1 根因的同類修法，LS-79 池項 F3）；
# herestring `<<<` 結尾會多補一個換行，會被吃進最後一個欄位（`cyclev`），用完後去掉尾端換行。
SEP=$'\x1f'
parsed=0

if command -v jq >/dev/null 2>&1; then
  if out=$(printf '%s' "$input" | jq -r --arg sep "$SEP" '
      [
        (.tool_input.id | if type == "string" then . else "" end),
        (.tool_input.project // "" | tostring),
        (.tool_input.milestone // "" | tostring),
        (.tool_input.title // "" | tostring),
        (.tool_input.parentId // "" | tostring),
        ((.tool_input.labels // []) | if type == "array" then join(",") else error("labels 不是陣列") end),
        (.tool_input.state // "" | tostring),
        (.tool_input.cycle // "" | tostring)
      ] | map(gsub($sep; " ")) | join($sep)
    ' 2>/dev/null); then
    IFS="$SEP" read -r -d '' idv projectv milestonev titlev parentidv labelsv statev cyclev <<<"$out" || true
    cyclev=${cyclev%$'\n'}
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
    id_val = ti.get("id")
    id_str = id_val if isinstance(id_val, str) else ""
except Exception:
    sys.exit(1)
def esc(s):
    return str(s).replace("\x1f", " ")
fields = [id_str, ti.get("project") or "", ti.get("milestone") or "", ti.get("title") or "", ti.get("parentId") or "", labels_str, ti.get("state") or "", ti.get("cycle") or ""]
sys.stdout.write("\x1f".join(esc(f) for f in fields))
' 2>/dev/null); then
    IFS="$SEP" read -r -d '' idv projectv milestonev titlev parentidv labelsv statev cyclev <<<"$out" || true
    cyclev=${cyclev%$'\n'}
    parsed=1
  fi
fi

[ "$parsed" -eq 1 ] || final_deny "LS-77：jq／python3 皆無法解析 tool_input（缺工具或 JSON 壞），見 ${COLL_REF}"

# ---- CYCLE-NORM-START：cycle 正規化（池項 F6）：數字／字面 "0" 與純空白字串視同未帶
# cycle，兩條解析路徑統一在此處理一次，見上方檔頭註解 ----
if [ "${cyclev:-}" = "0" ]; then
  cyclev=""
fi
case "${cyclev:-}" in
  *[![:space:]]*) : ;;  # 含至少一個非空白字元，維持原值
  *) cyclev="" ;;        # 空字串或純空白 → 視同未帶
esac
# ---- CYCLE-NORM-END ----

# ---- RULE-E-START：state 為 Ready（建票與更新票皆套用）或 In Progress（僅限建票）且未帶
# cycle → deny（§5-c，LS-79；R1 merge-review 混合案，見上方檔頭註解與 §5-c 修訂理由）。
# state 未出現在這次 tool_input，或值不是上述情況（含 Backlog／Done／其他），皆不觸發 ----
CYCLE_HINT='補 cycle＝當前 cycle 編號（用 list_cycles 或巡檢輸出的「current cycle：N」查，勿沿用上次用過的字面值）'
if [ -n "${statev:-}" ]; then
  case "$statev" in
    Ready)
      if [ -z "${cyclev:-}" ]; then
        final_deny "LS-79：state 為 Ready 但未帶 cycle（§5-c 派工必進 cycle）。${CYCLE_HINT}，見 ${COLL_REF_CYCLE}"
      fi
      ;;
    'In Progress')
      if [ -z "${idv:-}" ] && [ -z "${cyclev:-}" ]; then
        final_deny "LS-79：建票 state 為 In Progress 但未帶 cycle（§5-c 派工必進 cycle）。${CYCLE_HINT}，見 ${COLL_REF_CYCLE}"
      fi
      ;;
  esac
fi
# ---- RULE-E-END ----

# 更新既有票（有 id，且 id 為字串型別——見上方「id 型別防呆」）：A-D 一律放行，票文明定：
# 避免改狀態／改其他欄位被誤攔；state=Ready 的 cycle 要求已由上面的規則 E 驗過（In Progress
# 對更新票不驗，見規則 E 註解與 §5-c 修訂理由）。
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
