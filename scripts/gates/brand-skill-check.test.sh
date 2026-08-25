#!/bin/bash
# brand-skill-check.sh 的自測（LS-30）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成只看 SKILL.md 存在、不驗 frontmatter、放過 name 不符目錄名、
# 放過空 description、放過指到空檔的 references、只驗一份 agent、多個違規只列第一條、或非目錄假綠，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/brand-skill-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# expect <期望 exit code> <樣本名稱> <輸出必含字串|''> [<第二個必含字串>]
# 對 $work/repo 跑 checker。
expect() {
  local want=$1 name=$2 must=$3 must2=${4:-} out got
  out="$(bash "$checker" "$work/repo" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; } \
     && { [ -z "$must2" ] || printf '%s' "$out" | grep -qF -- "$must2"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}${must2:+、「${must2}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# reset：重建一個合法的最小 repo 形狀
reset() {
  rm -rf "$work/repo"
  mkdir -p "$work/repo/.claude/skills/little-sprout-brand/references" "$work/repo/.claude/agents"
  cat > "$work/repo/.claude/skills/little-sprout-brand/SKILL.md" <<'EOF'
---
name: little-sprout-brand
description: 設計語言定案。ui-designer 與 visual-reviewer 開工必載。
---

# 內容

讀 `references/tokens.md` 與 `references/slop-forbidden.md`。
EOF
  echo '# tokens' > "$work/repo/.claude/skills/little-sprout-brand/references/tokens.md"
  echo '# slop' > "$work/repo/.claude/skills/little-sprout-brand/references/slop-forbidden.md"
  printf -- '---\nname: ui-designer\n---\n- 開工先用 Skill 工具載入 `little-sprout-brand`。\n' > "$work/repo/.claude/agents/ui-designer.md"
  printf -- '---\nname: visual-reviewer\n---\n- 開工先用 Skill 工具載入 `little-sprout-brand`。\n' > "$work/repo/.claude/agents/visual-reviewer.md"
}

# ① 合法形狀 → 綠
reset
expect 0 '① 最小合法形狀（frontmatter 齊、references 存在、兩份 agent 接線）' '已接線'

# ①b CRLF frontmatter（web 編輯器貼上）仍認得
reset
printf -- '---\r\nname: little-sprout-brand\r\ndescription: 設計語言\r\n---\r\n\r\n# 內容\r\n' > "$work/repo/.claude/skills/little-sprout-brand/SKILL.md"
expect 0 '① CRLF frontmatter 仍綠' '已接線'

# ①c SKILL.md 沒引用任何 references → 不因此紅
reset
printf -- '---\nname: little-sprout-brand\ndescription: 設計語言\n---\n# 只有本文\n' > "$work/repo/.claude/skills/little-sprout-brand/SKILL.md"
expect 0 '① 無 references 引用 → 綠（引用檢查不是必有引用）' '已接線'

# ② skill 本體
reset; rm "$work/repo/.claude/skills/little-sprout-brand/SKILL.md"
expect 1 '② SKILL.md 缺 → 紅' '不存在或不可讀'

reset; printf -- '# 沒有 frontmatter\nname: little-sprout-brand\n' > "$work/repo/.claude/skills/little-sprout-brand/SKILL.md"
expect 1 '② 第一行不是 --- → 紅' '沒有 frontmatter'

reset; printf -- '---\nname: little-sprout-brand\ndescription: x\n\n# 忘了閉合\n' > "$work/repo/.claude/skills/little-sprout-brand/SKILL.md"
expect 1 '② frontmatter 未閉合 → 紅' '沒有閉合'

reset; printf -- '---\ndescription: 設計語言\n---\n# x\n' > "$work/repo/.claude/skills/little-sprout-brand/SKILL.md"
expect 1 '② 缺 name → 紅' '缺 `name:`'

reset; printf -- '---\nname: little-sprout-brand-v2\ndescription: 設計語言\n---\n# x\n' > "$work/repo/.claude/skills/little-sprout-brand/SKILL.md"
expect 1 '② name 不等於目錄名 → 紅' 'little-sprout-brand-v2'

reset; printf -- '---\nname: little-sprout-brand\ndescription:   \n---\n# x\n' > "$work/repo/.claude/skills/little-sprout-brand/SKILL.md"
expect 1 '② description 值為空白 → 紅' '`description:`'

reset; printf -- '---\nname: little-sprout-brand\n---\n# x\n' > "$work/repo/.claude/skills/little-sprout-brand/SKILL.md"
expect 1 '② 缺 description → 紅' '`description:`'

# ②b name/description 寫在 frontmatter 之外（本文）不算
reset; printf -- '---\ntitle: x\n---\nname: little-sprout-brand\ndescription: 本文裡的不算\n' > "$work/repo/.claude/skills/little-sprout-brand/SKILL.md"
expect 1 '② name／description 在本文而非 frontmatter → 紅' '缺 `name:`' '`description:`'

# ③ references 指到空檔
reset; rm "$work/repo/.claude/skills/little-sprout-brand/references/slop-forbidden.md"
expect 1 '③ SKILL.md 引用的 references/slop-forbidden.md 不存在 → 紅並點名' 'references/slop-forbidden.md' '不存在'

# ④ agent 接線
reset; printf -- '---\nname: ui-designer\n---\n- 開工先載入 frontend-design。\n' > "$work/repo/.claude/agents/ui-designer.md"
expect 1 '④ ui-designer.md 不含字樣 → 紅' 'ui-designer.md'

reset; printf -- '---\nname: visual-reviewer\n---\n- 只審查。\n' > "$work/repo/.claude/agents/visual-reviewer.md"
expect 1 '④ visual-reviewer.md 不含字樣 → 紅' 'visual-reviewer.md'

reset; rm "$work/repo/.claude/agents/visual-reviewer.md"
expect 1 '④ agent 定義檔缺 → 紅' 'visual-reviewer.md' '不存在或不可讀'

# ⑤ 多個違規一次全列（不在第一條就停）
reset
rm "$work/repo/.claude/skills/little-sprout-brand/references/tokens.md"
printf -- '---\nname: ui-designer\n---\n- 沒接線。\n' > "$work/repo/.claude/agents/ui-designer.md"
printf -- '---\nname: visual-reviewer\n---\n- 沒接線。\n' > "$work/repo/.claude/agents/visual-reviewer.md"
expect 1 '⑤ 三處違規同時列出（references＋兩份 agent）' 'references/tokens.md' 'visual-reviewer.md'
out="$(bash "$checker" "$work/repo" 2>&1)"
if printf '%s' "$out" | grep -qF 'ui-designer.md'; then echo "✓ ⑤ 第三處（ui-designer.md）也在同一次輸出"; else echo "✗ ⑤ ui-designer.md 未列出" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

# ⑥ 參數／路徑錯誤：fail closed（exit 2）
if out="$(bash "$checker" "$work/nope" 2>&1)"; then
  echo "✗ ⑥ repo 路徑不存在 → 應 exit 2（實得 0）" >&2; fail=1
elif [ $? -eq 2 ] && printf '%s' "$out" | grep -qF '找不到目錄'; then
  echo "✓ ⑥ repo 路徑不存在 → exit 2"
else
  echo "✗ ⑥ repo 路徑不存在（期望 exit 2、輸出含「找不到目錄」）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
if out="$(bash "$checker" "$work/repo" extra 2>&1)"; then
  echo "✗ ⑥ 多餘參數 → 應 exit 2（實得 0）" >&2; fail=1
elif [ $? -eq 2 ] && printf '%s' "$out" | grep -qF '只接受一個'; then
  echo "✓ ⑥ 多餘參數 → exit 2"
else
  echo "✗ ⑥ 多餘參數（期望 exit 2）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ⑦ 真 repo：本 repo 自己的接線必須是綠的（gate 自測順便驗實際狀態；未傳參數＝從 git 推 toplevel）
out="$( (cd "$root" && bash "$checker") 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '已接線'; then
  echo "✓ ⑦ 本 repo 實際接線 → 綠（未傳參數）"
else
  echo "✗ ⑦ 本 repo 實際接線（期望 exit 0，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ brand-skill-check 自測通過（19 組樣本）"
fi
exit "$fail"
