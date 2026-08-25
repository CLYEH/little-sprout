#!/bin/bash
# agent-tools-check.sh 的自測（LS-87 R3 F2）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成子字串比對（BashOutput 冒充 Bash）、只驗一份 agent、把正文的「tools:」
# 當 frontmatter、放過缺檔／未閉合 frontmatter／空值、多個違規只列第一條、或非目錄假綠，這裡會紅。樣本數由 ok() 計數。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/agent-tools-check.sh"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n+1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
agents="$work/agents"

# expect <期望 exit> <名稱> <輸出必含|''> [<第二個必含>] [<不得含>]（對 $agents 跑 checker）
expect() {
  local want=$1 name=$2 must=$3 must2=${4:-} mustnot=${5:-} out got
  out="$(bash "$checker" "$agents" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; } \
     && { [ -z "$must2" ] || printf '%s' "$out" | grep -qF -- "$must2"; } \
     && { [ -z "$mustnot" ] || ! printf '%s' "$out" | grep -qF -- "$mustnot"; }; then
    ok "${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}${must2:+、「${must2}」}${mustnot:+、不含「${mustnot}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

LINEAR3="mcp__linear__get_issue, mcp__linear__list_comments, mcp__linear__save_comment"
# mk <agent> <tools 行的值|NONE> [<正文附加行>]：寫一份最小 agent 定義
mk() {
  local agent=$1 tools=$2 body=${3:-}
  {
    echo "---"; echo "name: ${agent}"; echo "description: 測試用"
    [ "$tools" = NONE ] || echo "tools: ${tools}"
    echo "model: sonnet"; echo "---"; echo; echo "正文。"; [ -z "$body" ] || echo "$body"
  } > "$agents/${agent}.md"
}
reset() {
  rm -rf "$agents"; mkdir -p "$agents"
  mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}"
  mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill"
  mk dead-code-sweeper "Bash, Read, Grep, Glob, mcp__linear__get_issue, mcp__linear__list_comments"
  mk ui-designer NONE
  mk visual-reviewer NONE
}

# ---- ① 合法 ----
reset; expect 0 '① 五份齊、白名單含必要工具 → exit 0' '✓ agent-tools gate 通過（5 份' 'ui-designer.md：無 tools: 行（繼承全部工具）→ 放行'
out="$(bash "$checker" 2>&1)"; got=$?   # 不帶參數＝真 repo 的 .claude/agents
if [ "$got" -eq 0 ]; then ok '① 真 repo 的 .claude/agents 通過'; else echo "✗ ① 真 repo 應通過（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
reset; mk ui-designer "Read, mcp__pencil__get_app_state, mcp__pencil__execute"; expect 0 '① ui-designer 有 tools: 且含 execute → exit 0' '通過'
reset; mk qa "  Bash ,  ${LINEAR3},mcp__pencil__get_app_state  "; expect 0 '① 空白／逗號變體 → exit 0' '通過'
reset; printf -- '---\r\nname: qa\r\ndescription: x\r\ntools: Bash, %s, mcp__pencil__get_app_state\r\nmodel: sonnet\r\n---\r\n' "$LINEAR3" > "$agents/qa.md"; expect 0 '① CRLF 行尾 → exit 0' '通過'

# ---- ② 缺工具 ----
reset; mk qa "Read, ${LINEAR3}, mcp__pencil__get_app_state"; expect 1 '② qa 少 Bash → exit 1' 'qa.md：tools: 缺 Bash'
reset; mk qa "BashOutput, ${LINEAR3}, mcp__pencil__get_app_state"; expect 1 '② BashOutput 不算 Bash（整字比對）→ exit 1' 'qa.md：tools: 缺 Bash'
reset; mk merge-reviewer "Bash, mcp__linear__get_issue, mcp__linear__list_comments"; expect 1 '② merge-reviewer 少 save_comment → exit 1' 'merge-reviewer.md：tools: 缺 mcp__linear__save_comment'
reset; mk qa "Bash, ${LINEAR3}"; expect 1 '② qa 少 mcp__pencil__get_app_state → exit 1' 'qa.md：tools: 缺 mcp__pencil__get_app_state'
reset; mk ui-designer "Read, mcp__pencil__get_app_state"; expect 1 '② ui-designer 有 tools: 但缺 execute → exit 1' 'ui-designer.md：tools: 缺 mcp__pencil__execute'
reset; mk visual-reviewer "Read"; expect 1 '② visual-reviewer 有 tools: 但缺 execute → exit 1' 'visual-reviewer.md：tools: 缺 mcp__pencil__execute'
reset; mk dead-code-sweeper "Read, mcp__linear__get_issue"; expect 1 '② dead-code-sweeper 少 Bash 與 list_comments → 一行列兩支' 'dead-code-sweeper.md：tools: 缺 Bash mcp__linear__list_comments'
reset; mk qa "Read"; mk merge-reviewer "Read"; expect 1 '② 兩份同時違規 → 一次列完' 'qa.md：tools: 缺' 'merge-reviewer.md：tools: 缺'

# ---- ③ 檔案／frontmatter 形狀 ----
reset; rm "$agents/visual-reviewer.md"; expect 1 '③ 缺檔 → exit 1' 'visual-reviewer.md：不存在'
reset; mk qa "Read, ${LINEAR3}, mcp__pencil__get_app_state" "tools: Bash, ${LINEAR3}, mcp__pencil__get_app_state"; expect 1 '③ 正文的 tools: 不算（frontmatter 缺 Bash）→ exit 1' 'qa.md：tools: 缺 Bash'
reset; printf -- '---\nname: qa\ntools: Bash\n\n正文沒有第二個 ---\n' > "$agents/qa.md"; expect 1 '③ frontmatter 未閉合 → exit 1' 'qa.md：frontmatter 缺失或未閉合'
reset; printf 'name: qa\ntools: Bash\n' > "$agents/qa.md"; expect 1 '③ 第一行不是 --- → exit 1' 'qa.md：frontmatter 缺失或未閉合'
reset; printf -- '---\nname: qa\ntools:\n  - Bash\nmodel: sonnet\n---\n' > "$agents/qa.md"; expect 1 '③ tools: 空值（YAML 多行清單）→ exit 1' 'qa.md：tools: 值為空'
reset; mk qa "Read, ${LINEAR3}, mcp__pencil__get_app_state"; expect 1 '③ 違規時不印通過' 'qa.md：tools: 缺 Bash' '' '✓ agent-tools gate 通過'

# ---- ④ 參數 ----
out="$(bash "$checker" "$work/nope" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '找不到目錄'; then ok '④ 目錄不存在 → exit 2'; else echo "✗ ④ 目錄不存在應 exit 2（實得 ${got}）" >&2; fail=1; fi
out="$(bash "$checker" "$agents" extra 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '只接受一個'; then ok '④ 多參數 → exit 2'; else echo "✗ ④ 多參數應 exit 2（實得 ${got}）" >&2; fail=1; fi

if [ "$fail" -ne 0 ]; then
  echo "✗ agent-tools-check 自測失敗" >&2
  exit 1
fi
echo "✓ agent-tools-check 自測通過（${n} 組樣本）"
