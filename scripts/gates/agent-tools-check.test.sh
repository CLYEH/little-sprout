#!/bin/bash
# agent-tools-check.sh 的自測（LS-87 R3 F2）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成子字串比對（BashOutput 冒充 Bash）、只驗一份 agent、把正文的「tools:」
# 當 frontmatter、放過缺檔／未閉合 frontmatter／空值、多個違規只列第一條、或非目錄假綠，這裡會紅。樣本數由 ok() 計數。
# LS-170（⑤）：正文必含字樣——ios-dev／merge-reviewer 正文缺 `supabase-lock.sh --hold` 即紅；字樣只在 frontmatter 不算；只有
# `--release` 不算；CRLF 可；加 mutation 負控（awk 拿掉 LS170-BODY-RULES 區塊後同一份負樣本須變綠，且先驗 mutant 確實不含區塊）。
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
# LS-170：ios-dev／merge-reviewer 的正文必含字樣（真 .md 的寫法是整段規約，這裡只要字樣在正文即可）
HOLD='互動式驗證前 `bash scripts/ops/supabase-lock.sh --hold "LS-<n> dev E2E"`，收工 `--release`。'
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
  mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "$HOLD"
  mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill"
  mk dead-code-sweeper "Bash, Read, Grep, Glob, ${LINEAR3}"
  mk ui-designer NONE
  mk visual-reviewer NONE
  mk ios-dev NONE "$HOLD"
}

# ---- ① 合法 ----
reset; expect 0 '① 六份齊、白名單含必要工具 → exit 0' '✓ agent-tools gate 通過（6 份' 'ios-dev.md：無 tools: 行（繼承全部工具）→ 放行'
out="$(bash "$checker" 2>&1)"; got=$?   # 不帶參數＝真 repo 的 .claude/agents
if [ "$got" -eq 0 ]; then ok '① 真 repo 的 .claude/agents 通過'; else echo "✗ ① 真 repo 應通過（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
reset; mk ui-designer "Read, mcp__pencil__get_app_state, mcp__pencil__execute"; expect 0 '① ui-designer 有 tools: 且含 execute → exit 0' '通過'
reset; mk qa "  Bash ,  ${LINEAR3},mcp__pencil__get_app_state,mcp__pencil__execute  "; expect 0 '① 空白／逗號變體 → exit 0' '通過'
reset; printf -- '---\r\nname: qa\r\ndescription: x\r\ntools: Bash, %s, mcp__pencil__get_app_state, mcp__pencil__execute\r\nmodel: sonnet\r\n---\r\n' "$LINEAR3" > "$agents/qa.md"; expect 0 '① CRLF 行尾 → exit 0' '通過'

# ---- ② 缺工具 ----
reset; mk qa "Read, ${LINEAR3}, mcp__pencil__get_app_state"; expect 1 '② qa 少 Bash → exit 1' 'qa.md：tools: 缺 Bash'
reset; mk qa "BashOutput, ${LINEAR3}, mcp__pencil__get_app_state"; expect 1 '② BashOutput 不算 Bash（整字比對）→ exit 1' 'qa.md：tools: 缺 Bash'
reset; mk merge-reviewer "Bash, mcp__linear__get_issue, mcp__linear__list_comments" "$HOLD"; expect 1 '② merge-reviewer 少 save_comment → exit 1' 'merge-reviewer.md：tools: 缺 mcp__linear__save_comment'
reset; mk qa "Bash, ${LINEAR3}"; expect 1 '② qa 少 mcp__pencil__get_app_state → exit 1' 'qa.md：tools: 缺 mcp__pencil__get_app_state'
reset; mk qa "Bash, ${LINEAR3}, mcp__pencil__get_app_state"; expect 1 '② qa 少 mcp__pencil__execute（LS-91 補釘）→ exit 1' 'qa.md：tools: 缺 mcp__pencil__execute'
reset; mk ios-dev "Read, Edit" "$HOLD"; expect 0 '② ios-dev 有 tools: 行但必要工具留空 → 仍 exit 0（規則表無要求）' '通過'
reset; mk ui-designer "Read, mcp__pencil__get_app_state"; expect 1 '② ui-designer 有 tools: 但缺 execute → exit 1' 'ui-designer.md：tools: 缺 mcp__pencil__execute'
reset; mk visual-reviewer "Read"; expect 1 '② visual-reviewer 有 tools: 但缺 execute → exit 1' 'visual-reviewer.md：tools: 缺 mcp__pencil__execute'
reset; mk dead-code-sweeper "Read, mcp__linear__get_issue"; expect 1 '② dead-code-sweeper 少 Bash／list_comments／save_comment → 一行列三支' 'dead-code-sweeper.md：tools: 缺 Bash mcp__linear__list_comments mcp__linear__save_comment'
reset; mk dead-code-sweeper "Bash, mcp__linear__get_issue, mcp__linear__list_comments"; expect 1 '② dead-code-sweeper 少 save_comment（LS-157 補釘）→ exit 1' 'dead-code-sweeper.md：tools: 缺 mcp__linear__save_comment'
reset; mk qa "Read"; mk merge-reviewer "Read" "$HOLD"; expect 1 '② 兩份同時違規 → 一次列完' 'qa.md：tools: 缺' 'merge-reviewer.md：tools: 缺'

# ---- ③ 檔案／frontmatter 形狀 ----
reset; rm "$agents/visual-reviewer.md"; expect 1 '③ 缺檔 → exit 1' 'visual-reviewer.md：不存在'
reset; mk qa "Read, ${LINEAR3}, mcp__pencil__get_app_state" "tools: Bash, ${LINEAR3}, mcp__pencil__get_app_state"; expect 1 '③ 正文的 tools: 不算（frontmatter 缺 Bash）→ exit 1' 'qa.md：tools: 缺 Bash'
reset; printf -- '---\nname: qa\ntools: Bash\n\n正文沒有第二個 ---\n' > "$agents/qa.md"; expect 1 '③ frontmatter 未閉合 → exit 1' 'qa.md：frontmatter 缺失或未閉合'
reset; printf 'name: qa\ntools: Bash\n' > "$agents/qa.md"; expect 1 '③ 第一行不是 --- → exit 1' 'qa.md：frontmatter 缺失或未閉合'
reset; printf -- '---\nname: qa\ntools:\n  - Bash\nmodel: sonnet\n---\n' > "$agents/qa.md"; expect 1 '③ tools: 空值（YAML 多行清單）→ exit 1' 'qa.md：tools: 值為空'
reset; mk qa "Read, ${LINEAR3}, mcp__pencil__get_app_state"; expect 1 '③ 違規時不印通過' 'qa.md：tools: 缺 Bash' '' '✓ agent-tools gate 通過'

# ---- ⑤ LS-170 正文必含字樣：ios-dev／merge-reviewer 正文缺 `supabase-lock.sh --hold` 即紅 ----
reset; expect 0 '⑤ 兩份正文含字樣 → 印「正文含」、通過' 'ios-dev.md：正文含「supabase-lock.sh --hold」' 'merge-reviewer.md：正文含「supabase-lock.sh --hold」'
reset; mk ios-dev NONE; expect 1 '⑤ ios-dev 正文缺字樣 → exit 1' 'ios-dev.md：正文缺「supabase-lock.sh --hold」' '' '✓ agent-tools gate 通過'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}"; expect 1 '⑤ merge-reviewer 正文缺字樣 → exit 1' 'merge-reviewer.md：正文缺「supabase-lock.sh --hold」'
reset; mk ios-dev NONE; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}"; expect 1 '⑤ 兩份同時缺 → 一次列完' 'ios-dev.md：正文缺' 'merge-reviewer.md：正文缺'
reset; mk ios-dev NONE "只寫 supabase-lock.sh --release 不算"; expect 1 '⑤ 只有 --release 沒有 --hold → 紅' 'ios-dev.md：正文缺'
reset; printf -- '---\nname: ios-dev\ndescription: frontmatter 提到 supabase-lock.sh --hold 不算\nmodel: sonnet\n---\n\n正文。\n' > "$agents/ios-dev.md"; expect 1 '⑤ 字樣只在 frontmatter → 仍紅（只看正文）' 'ios-dev.md：正文缺'
reset; printf -- '---\r\nname: ios-dev\r\nmodel: sonnet\r\n---\r\n\r\n%s\r\n' "$HOLD" > "$agents/ios-dev.md"; expect 0 '⑤ CRLF 正文含字樣 → exit 0' 'ios-dev.md：正文含'
reset; mk ios-dev "Read" ; mk merge-reviewer "Read"; expect 1 '⑤ 工具缺與正文缺同時 → 兩類一起列' 'merge-reviewer.md：tools: 缺' 'merge-reviewer.md：正文缺'
# mutation 負控（同 linear-issue-check.test.sh 慣例）：拿掉 LS170-BODY-RULES 區塊（留下空表）後，上面「ios-dev 正文缺」的
# 同一份負樣本必須變綠——證明紅是這條規則造成的，不是別條規則湊巧命中；先驗 mutant 確實不含區塊，否則負控本身無效。
mut="$work/agent-tools-check.no-body-rules.sh"
awk 'index($0, "LS170-BODY-RULES-START") > 0 { skip = 1 } skip != 1 { print } index($0, "LS170-BODY-RULES-END") > 0 { skip = 0 }' "$checker" > "$mut"
if grep -q 'LS170-BODY-RULES-START' "$mut" || grep -q 'ios-dev|supabase-lock.sh --hold' "$mut"; then
  echo "✗ ⑤ mutant 仍含正文規則區塊（awk 拿掉失敗，負控本身無效）" >&2; fail=1
else
  ok '⑤ mutant 確實已拿掉正文規則區塊'
fi
reset; mk ios-dev NONE
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '✓ agent-tools gate 通過' && ! printf '%s' "$out" | grep -qF '正文缺'; then
  ok '⑤ mutant：拿掉規則後同一份負樣本變綠（證明規則區塊確實是原因）'
else
  echo "✗ ⑤ mutant 應 exit 0 且不印「正文缺」（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

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
