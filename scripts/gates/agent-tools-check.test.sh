#!/bin/bash
# agent-tools-check.sh 的自測（LS-87 R3 F2）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成子字串比對（BashOutput 冒充 Bash）、只驗一份 agent、把正文的「tools:」
# 當 frontmatter、放過缺檔／未閉合 frontmatter／空值、多個違規只列第一條、或非目錄假綠，這裡會紅。樣本數由 ok() 計數。
# LS-170（⑤）：正文必含字樣——ios-dev／merge-reviewer 正文缺 `supabase-lock.sh --hold` 即紅；字樣只在 frontmatter 不算；只有
# `--release` 不算；CRLF 可；加 mutation 負控（awk 拿掉 LS170-BODY-RULES 區塊後同一份負樣本須變綠，且先驗 mutant 確實不含區塊）。
# LS-184（⑩）：三份的 `--hold` 寫法須為 `cd <worktree> && bash scripts/ops/supabase-lock.sh --hold` 同一命令鏈——裸 `--hold` 句（舊字樣仍在）即紅；
# 同一 mutant 下負樣本變綠。
# LS-186（⑪）：ios-dev 正文的 PR body 驗證句須為 `pr-body-check.sh <f> --branch <分支> --verify`——改回裸 `pr-body-check.sh <f>` 即紅；
# merge-reviewer／qa 不要求；同一 mutant 下負樣本變綠。
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
# LS-184：`--hold` 與 `cd <worktree>` 同一命令鏈才算；BARE_HOLD 是 LS-184 之前的裸寫法（⑩ 的負樣本）
HOLD='互動式驗證前 `cd <worktree> && bash scripts/ops/supabase-lock.sh --hold "LS-<n> dev E2E"`，收工 `--release`。'
BARE_HOLD='互動式驗證前 `bash scripts/ops/supabase-lock.sh --hold "LS-<n> dev E2E"`，收工 `--release`。'
# LS-183：ios-dev／merge-reviewer／qa 正文另須含「本機容器操作同樣要在 lock 內」（docker exec／psql／functions serve 的 H3b 規約句）；
# 合法的三份樣本 hold 句＋H3b 句都要有
H3B='`docker exec`／`psql`／`supabase functions serve` 等本機容器操作同樣要在 lock 內（PreToolUse H3b）。'
LOCK_BODY="${HOLD} ${H3B}"
# LS-158：qa 正文另須含 `qa-e2e.sh`（多步驟驗收優先端到端驅動）；合法的 qa 樣本三句都要有
E2E='多步驟驗收優先 `bash scripts/ops/qa-e2e.sh <login|publish|browse>`。'
QA_BODY="${LOCK_BODY} ${E2E}"
# LS-180：ui-designer／visual-reviewer 正文須含「--kill 只在 orchestrator 明示時」（切檔不殺行程的規約句）
KILL='切檔一律不殺行程；`pen-open.sh` 的 --force-reload／--kill 只在 orchestrator 明示時使用，用後必回報「需重連」。'
# LS-180 裁決：ui-designer 正文另須含「收工 Pen 停在票檔」（不切回主 checkout）；合法的 ui-designer 樣本兩句都要有
STAY='handoff 前不切回主 checkout：收工 Pen 停在票檔，handoff 註明路徑。'
UI_BODY="${KILL} ${STAY}"
# LS-186：ios-dev 正文另須含 CI 完整旗標的 PR body 驗證句；OLD_PRBODY 是 LS-186 之前的裸寫法（⑪ 的負樣本）
PRBODY='`gh pr create/edit --body-file <f>` 之前先 `bash scripts/gates/pr-body-check.sh <f> --branch <分支> --verify`，直接看 exit code。'
OLD_PRBODY='`gh pr create/edit --body-file <f>` 之前先 `bash scripts/gates/pr-body-check.sh <f>` 斷言檔頭段含本票票號。'
IOS_BODY="${LOCK_BODY} ${PRBODY}"
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
  mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "$LOCK_BODY"
  mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "$QA_BODY"
  mk dead-code-sweeper "Bash, Read, Grep, Glob, ${LINEAR3}"
  mk ui-designer NONE "$UI_BODY"
  mk visual-reviewer NONE "$KILL"
  mk ios-dev NONE "$IOS_BODY"
}

# ---- ① 合法 ----
reset; expect 0 '① 六份齊、白名單含必要工具 → exit 0' '✓ agent-tools gate 通過（6 份' 'ios-dev.md：無 tools: 行（繼承全部工具）→ 放行'
out="$(bash "$checker" 2>&1)"; got=$?   # 不帶參數＝真 repo 的 .claude/agents
if [ "$got" -eq 0 ]; then ok '① 真 repo 的 .claude/agents 通過'; else echo "✗ ① 真 repo 應通過（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
reset; mk ui-designer "Read, mcp__pencil__get_app_state, mcp__pencil__execute" "$UI_BODY"; expect 0 '① ui-designer 有 tools: 且含 execute → exit 0' '通過'
reset; mk qa "  Bash ,  ${LINEAR3},mcp__pencil__get_app_state,mcp__pencil__execute  " "$QA_BODY"; expect 0 '① 空白／逗號變體 → exit 0' '通過'
reset; printf -- '---\r\nname: qa\r\ndescription: x\r\ntools: Bash, %s, mcp__pencil__get_app_state, mcp__pencil__execute\r\nmodel: sonnet\r\n---\r\n\r\n%s\r\n' "$LINEAR3" "$QA_BODY" > "$agents/qa.md"; expect 0 '① CRLF 行尾 → exit 0' '通過'

# ---- ② 缺工具 ----
reset; mk qa "Read, ${LINEAR3}, mcp__pencil__get_app_state" "$HOLD"; expect 1 '② qa 少 Bash → exit 1' 'qa.md：tools: 缺 Bash'
reset; mk qa "BashOutput, ${LINEAR3}, mcp__pencil__get_app_state" "$HOLD"; expect 1 '② BashOutput 不算 Bash（整字比對）→ exit 1' 'qa.md：tools: 缺 Bash'
reset; mk merge-reviewer "Bash, mcp__linear__get_issue, mcp__linear__list_comments" "$HOLD"; expect 1 '② merge-reviewer 少 save_comment → exit 1' 'merge-reviewer.md：tools: 缺 mcp__linear__save_comment'
reset; mk qa "Bash, ${LINEAR3}" "$HOLD"; expect 1 '② qa 少 mcp__pencil__get_app_state → exit 1' 'qa.md：tools: 缺 mcp__pencil__get_app_state'
reset; mk qa "Bash, ${LINEAR3}, mcp__pencil__get_app_state" "$HOLD"; expect 1 '② qa 少 mcp__pencil__execute（LS-91 補釘）→ exit 1' 'qa.md：tools: 缺 mcp__pencil__execute'
reset; mk ios-dev "Read, Edit" "$IOS_BODY"; expect 0 '② ios-dev 有 tools: 行但必要工具留空 → 仍 exit 0（規則表無要求）' '通過'
reset; mk ui-designer "Read, mcp__pencil__get_app_state" "$UI_BODY"; expect 1 '② ui-designer 有 tools: 但缺 execute → exit 1' 'ui-designer.md：tools: 缺 mcp__pencil__execute'
reset; mk visual-reviewer "Read" "$KILL"; expect 1 '② visual-reviewer 有 tools: 但缺 execute → exit 1' 'visual-reviewer.md：tools: 缺 mcp__pencil__execute'
reset; mk dead-code-sweeper "Read, mcp__linear__get_issue"; expect 1 '② dead-code-sweeper 少 Bash／list_comments／save_comment → 一行列三支' 'dead-code-sweeper.md：tools: 缺 Bash mcp__linear__list_comments mcp__linear__save_comment'
reset; mk dead-code-sweeper "Bash, mcp__linear__get_issue, mcp__linear__list_comments"; expect 1 '② dead-code-sweeper 少 save_comment（LS-157 補釘）→ exit 1' 'dead-code-sweeper.md：tools: 缺 mcp__linear__save_comment'
reset; mk qa "Read" "$HOLD"; mk merge-reviewer "Read" "$HOLD"; expect 1 '② 兩份同時違規 → 一次列完' 'qa.md：tools: 缺' 'merge-reviewer.md：tools: 缺'

# ---- ③ 檔案／frontmatter 形狀 ----
reset; rm "$agents/visual-reviewer.md"; expect 1 '③ 缺檔 → exit 1' 'visual-reviewer.md：不存在'
reset; mk qa "Read, ${LINEAR3}, mcp__pencil__get_app_state" "tools: Bash, ${LINEAR3}, mcp__pencil__get_app_state"; expect 1 '③ 正文的 tools: 不算（frontmatter 缺 Bash）→ exit 1' 'qa.md：tools: 缺 Bash'
reset; printf -- '---\nname: qa\ntools: Bash\n\n正文沒有第二個 ---\n' > "$agents/qa.md"; expect 1 '③ frontmatter 未閉合 → exit 1' 'qa.md：frontmatter 缺失或未閉合'
reset; printf 'name: qa\ntools: Bash\n' > "$agents/qa.md"; expect 1 '③ 第一行不是 --- → exit 1' 'qa.md：frontmatter 缺失或未閉合'
reset; printf -- '---\nname: qa\ntools:\n  - Bash\nmodel: sonnet\n---\n' > "$agents/qa.md"; expect 1 '③ tools: 空值（YAML 多行清單）→ exit 1' 'qa.md：tools: 值為空'
reset; mk qa "Read, ${LINEAR3}, mcp__pencil__get_app_state" "$HOLD"; expect 1 '③ 違規時不印通過' 'qa.md：tools: 缺 Bash' '' '✓ agent-tools gate 通過'

# ---- ⑤ LS-170 正文必含字樣：ios-dev／merge-reviewer／qa（R2 (a)）正文缺 `supabase-lock.sh --hold` 即紅 ----
reset; expect 0 '⑤ 三份正文含字樣 → 印「正文含」、通過（14 條）' 'ios-dev.md：正文含「supabase-lock.sh --hold」' '正文必含字樣 14 條）'
# LS-158：qa 正文另一條 `qa-e2e.sh`——有 hold 字樣但沒有 e2e 字樣仍紅；三句都在才印「正文含」
reset; expect 0 '⑥ LS-158：qa 正文含 qa-e2e.sh → 印「正文含」' 'qa.md：正文含「qa-e2e.sh」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "$LOCK_BODY"; expect 1 '⑥ LS-158：qa 正文只有 hold＋H3b 句、缺 qa-e2e.sh → exit 1' 'qa.md：正文缺「qa-e2e.sh」' '' 'qa.md：正文缺「supabase-lock.sh --hold」'
# LS-180：ui-designer／visual-reviewer 正文須含「--kill 只在 orchestrator 明示時」——切檔不殺行程的規約句被刪即紅；工具齊全不救
reset; expect 0 '⑦ LS-180：ui-designer／visual-reviewer 正文含字樣 → 印「正文含」' 'ui-designer.md：正文含「--kill 只在 orchestrator 明示時」' 'visual-reviewer.md：正文含「--kill 只在 orchestrator 明示時」'
reset; mk ui-designer NONE; expect 1 '⑦ LS-180：ui-designer 正文缺字樣 → exit 1' 'ui-designer.md：正文缺「--kill 只在 orchestrator 明示時」'
reset; mk visual-reviewer "Read, mcp__pencil__get_app_state, mcp__pencil__execute"; expect 1 '⑦ LS-180：visual-reviewer 正文缺字樣 → exit 1，工具齊全不救' 'visual-reviewer.md：正文缺「--kill 只在 orchestrator 明示時」' '' 'visual-reviewer.md：tools: 缺'
reset; mk ui-designer NONE "只寫 --kill 而沒有那句規約不算"; expect 1 '⑦ LS-180：只有 --kill 字面、無「只在 orchestrator 明示時」→ 紅' 'ui-designer.md：正文缺「--kill 只在 orchestrator 明示時」'
# LS-180 裁決：ui-designer 正文另須含「收工 Pen 停在票檔」——有 --kill 句但收工句被刪（或改回「切回主 checkout」）即紅；visual-reviewer 不要求
reset; expect 0 '⑧ LS-180 裁決：ui-designer 正文含「收工 Pen 停在票檔」→ 印「正文含」' 'ui-designer.md：正文含「收工 Pen 停在票檔」'
reset; mk ui-designer NONE "$KILL"; expect 1 '⑧ LS-180 裁決：ui-designer 只有 --kill 句、缺收工句 → exit 1' 'ui-designer.md：正文缺「收工 Pen 停在票檔」' '' 'ui-designer.md：正文缺「--kill 只在 orchestrator 明示時」'
reset; mk ui-designer NONE "${KILL} handoff 前切回主 checkout。"; expect 1 '⑧ LS-180 裁決：改回「切回主 checkout」而無收工句 → exit 1' 'ui-designer.md：正文缺「收工 Pen 停在票檔」'
reset; mk visual-reviewer NONE "$KILL"; expect 0 '⑧ LS-180 裁決：visual-reviewer 不要求收工句 → 仍通過' '通過'
# LS-183：ios-dev／merge-reviewer／qa 正文須含「本機容器操作同樣要在 lock 內」——只有 hold 句、H3b 句被刪即紅；三份都驗；工具齊全不救
reset; expect 0 '⑨ LS-183：三份正文含 H3b 句 → 印「正文含」' 'ios-dev.md：正文含「本機容器操作同樣要在 lock 內」' 'qa.md：正文含「本機容器操作同樣要在 lock 內」'
reset; mk ios-dev NONE "$HOLD"; expect 1 '⑨ LS-183：ios-dev 只有 hold 句、缺 H3b 句 → exit 1' 'ios-dev.md：正文缺「本機容器操作同樣要在 lock 內」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "$HOLD"; expect 1 '⑨ LS-183：merge-reviewer 缺 H3b 句 → exit 1' 'merge-reviewer.md：正文缺「本機容器操作同樣要在 lock 內」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${HOLD} ${E2E}"; expect 1 '⑨ LS-183：qa 有 hold＋e2e、缺 H3b 句 → exit 1，工具齊全不救' 'qa.md：正文缺「本機容器操作同樣要在 lock 內」' '' 'qa.md：tools: 缺'
reset; mk ios-dev NONE "${HOLD} 只寫 docker exec 而沒有那句規約不算"; expect 1 '⑨ LS-183：只有 docker exec 字面、無「同樣要在 lock 內」→ 紅' 'ios-dev.md：正文缺「本機容器操作同樣要在 lock 內」'
# LS-184：三份正文的 `--hold` 寫法須為 `cd <worktree> && bash scripts/ops/supabase-lock.sh --hold` 同一命令鏈——裸 `--hold` 句（舊字樣 `supabase-lock.sh --hold` 仍在）即紅；三份都驗；工具齊全不救
reset; expect 0 '⑩ LS-184：三份正文含 cd <worktree> && … --hold 同鏈句 → 印「正文含」' 'ios-dev.md：正文含「cd <worktree> && bash scripts/ops/supabase-lock.sh --hold」' 'qa.md：正文含「cd <worktree> && bash scripts/ops/supabase-lock.sh --hold」'
reset; mk ios-dev NONE "${BARE_HOLD} ${H3B}"; expect 1 '⑩ LS-184：ios-dev 只有裸 --hold（無 cd 同鏈）→ exit 1，舊字樣仍在不救' 'ios-dev.md：正文缺「cd <worktree> && bash scripts/ops/supabase-lock.sh --hold」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${BARE_HOLD} ${H3B}"; expect 1 '⑩ LS-184：merge-reviewer 裸 --hold → exit 1' 'merge-reviewer.md：正文缺「cd <worktree> && bash scripts/ops/supabase-lock.sh --hold」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${BARE_HOLD} ${H3B} ${E2E}"; expect 1 '⑩ LS-184：qa 裸 --hold → exit 1，工具齊全不救' 'qa.md：正文缺「cd <worktree> && bash scripts/ops/supabase-lock.sh --hold」' '' 'qa.md：tools: 缺'
reset; mk ios-dev NONE "先 cd <worktree>，另一條命令再 bash scripts/ops/supabase-lock.sh --hold 不算同鏈。${H3B}"; expect 1 '⑩ LS-184：cd 與 --hold 不在同一命令鏈（沒有 &&）→ 紅' 'ios-dev.md：正文缺「cd <worktree> && bash scripts/ops/supabase-lock.sh --hold」'
# LS-186：ios-dev 正文的 PR body 驗證句須帶 CI 完整旗標 `pr-body-check.sh <f> --branch <分支> --verify`——裸 `pr-body-check.sh <f>`（LS-185 前寫法）即紅；
# lock 三句齊全不救；merge-reviewer／qa 不要求
reset; expect 0 '⑪ LS-186：ios-dev 正文含 pr-body-check.sh <f> --branch <分支> --verify → 印「正文含」' 'ios-dev.md：正文含「pr-body-check.sh <f> --branch <分支> --verify」'
reset; mk ios-dev NONE "${LOCK_BODY} ${OLD_PRBODY}"; expect 1 '⑪ LS-186：ios-dev 只有裸 pr-body-check.sh <f>（無 --branch --verify）→ exit 1，lock 三句齊全不救' 'ios-dev.md：正文缺「pr-body-check.sh <f> --branch <分支> --verify」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk ios-dev NONE "${LOCK_BODY} 先 bash scripts/gates/pr-body-check.sh <f> --verify 再看，沒有 --branch 不算。"; expect 1 '⑪ LS-186：只有 --verify、沒有 --branch <分支> → 紅' 'ios-dev.md：正文缺「pr-body-check.sh <f> --branch <分支> --verify」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "$LOCK_BODY"; expect 0 '⑪ LS-186：merge-reviewer 不要求 pr-body-check 句 → 仍通過' '通過'
reset; expect 0 '⑤ merge-reviewer／qa 也印「正文含」' 'merge-reviewer.md：正文含「supabase-lock.sh --hold」' 'qa.md：正文含「supabase-lock.sh --hold」'
reset; mk ios-dev NONE; expect 1 '⑤ ios-dev 正文缺字樣 → exit 1' 'ios-dev.md：正文缺「supabase-lock.sh --hold」' '' '✓ agent-tools gate 通過'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}"; expect 1 '⑤ merge-reviewer 正文缺字樣 → exit 1' 'merge-reviewer.md：正文缺「supabase-lock.sh --hold」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill"; expect 1 '⑤ qa 正文缺字樣（R2 (a)）→ exit 1，工具齊全不救' 'qa.md：正文缺「supabase-lock.sh --hold」' '' 'qa.md：tools: 缺'
reset; mk ios-dev NONE; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}"; expect 1 '⑤ 兩份同時缺 → 一次列完' 'ios-dev.md：正文缺' 'merge-reviewer.md：正文缺'
reset; mk ios-dev NONE "只寫 supabase-lock.sh --release 不算"; expect 1 '⑤ 只有 --release 沒有 --hold → 紅' 'ios-dev.md：正文缺'
reset; printf -- '---\nname: ios-dev\ndescription: frontmatter 提到 supabase-lock.sh --hold 不算\nmodel: sonnet\n---\n\n正文。\n' > "$agents/ios-dev.md"; expect 1 '⑤ 字樣只在 frontmatter → 仍紅（只看正文）' 'ios-dev.md：正文缺'
reset; printf -- '---\r\nname: ios-dev\r\nmodel: sonnet\r\n---\r\n\r\n%s\r\n' "$IOS_BODY" > "$agents/ios-dev.md"; expect 0 '⑤ CRLF 正文含字樣 → exit 0' 'ios-dev.md：正文含'
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
# LS-183 負控：同一個 mutant（規則區塊整段拿掉）下，上面 ⑨「只有 hold 句、缺 H3b 句」的負樣本也必須變綠——證明 ⑨ 的紅來自規則表的 H3b 行
reset; mk ios-dev NONE "$HOLD"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! printf '%s' "$out" | grep -qF '本機容器操作同樣要在 lock 內'; then
  ok '⑨ mutant：拿掉規則後「只有 hold 句」的負樣本變綠（H3b 行確實是原因）'
else
  echo "✗ ⑨ mutant 應 exit 0 且不印 H3b 字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
# LS-184 負控：同一個 mutant 下，上面 ⑩「裸 --hold（無 cd 同鏈）」的負樣本也必須變綠——證明 ⑩ 的紅來自規則表的 LS-184 行
reset; mk ios-dev NONE "${BARE_HOLD} ${H3B}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! printf '%s' "$out" | grep -qF 'cd <worktree> &&'; then
  ok '⑩ mutant：拿掉規則後「裸 --hold」的負樣本變綠（LS-184 行確實是原因）'
else
  echo "✗ ⑩ mutant 應 exit 0 且不印 cd <worktree> && 字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
# LS-186 負控：同一個 mutant 下，上面 ⑪「裸 pr-body-check.sh <f>」的負樣本也必須變綠——證明 ⑪ 的紅來自規則表的 LS-186 行
reset; mk ios-dev NONE "${LOCK_BODY} ${OLD_PRBODY}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! printf '%s' "$out" | grep -qF 'pr-body-check.sh <f> --branch'; then
  ok '⑪ mutant：拿掉規則後「裸 pr-body-check.sh <f>」的負樣本變綠（LS-186 行確實是原因）'
else
  echo "✗ ⑪ mutant 應 exit 0 且不印 pr-body-check.sh <f> --branch 字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
# R1 I-3：正文規則表多一個不在工具表的 agent（mutant 在 BODY_RULES 首行後插 `nobody|x`）→ exit 2 fail closed，不得靜默跳過
mut3="$work/agent-tools-check.body-not-subset.sh"
awk '{ print } /^BODY_RULES="ios-dev\|/ { print "nobody|x" }' "$checker" > "$mut3"
if grep -q '^nobody|x$' "$mut3"; then ok '⑤ I-3 mutant 已插入不在工具表的 agent'; else echo "✗ ⑤ I-3 mutant 插入失敗（負控本身無效）" >&2; fail=1; fi
reset
out="$(bash "$mut3" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF 'nobody 不在工具規則表'; then ok '⑤ I-3：正文規則表 ⊄ 工具表 → exit 2 並點名'; else echo "✗ ⑤ I-3 應 exit 2 並點名 nobody（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

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
