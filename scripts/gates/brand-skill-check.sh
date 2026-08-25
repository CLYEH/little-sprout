#!/bin/bash
# 品牌 skill 接線檢查（LS-30）。
#
# 前饋：ui-designer／visual-reviewer 開工必先用 Skill 工具載入專案 skill `little-sprout-brand`
# （LS-46 定案的設計語言：tokens／字標／母題／長輩硬約束／專案版 slop 禁例／實作進場條件）。
# 載入動作發生在 subagent 內部、repo 側驗不到（與 frontend-design 同型，靠 handoff 欄位＋orchestrator）；
# 這裡驗的是它的前提——skill 本體存在且 Claude Code 讀得到、兩份 agent 定義真的有接線：
#   1. .claude/skills/little-sprout-brand/SKILL.md 存在且可讀
#   2. frontmatter 齊：第一行 `---`、有閉合的第二個 `---`、其間有 `name: little-sprout-brand`（＝目錄名）與非空 `description:`
#      （name／description 是 Claude Code 列出 skill 的唯一依據；缺了 skill 就靜默不存在，Skill 工具找不到）
#   3. SKILL.md 內引用的 references/<x>.md 全部存在且非空（`-s`：0 bytes 也算指到空檔——progressive disclosure 的指標指到空檔＝載入後仍拿不到內容）
#   4. .claude/agents/ui-designer.md 與 visual-reviewer.md 各含同一行的「載入…little-sprout-brand」必載指示（只剩註解／歷史提及不算；接線被人改掉即紅）
# 任一缺即紅並列出全部違規（不在第一條就停），exit 1；參數／路徑錯誤 exit 2（fail closed）。
# 掛 CI rules job（所有 PR，純檔案比對）；自測 brand-skill-check.test.sh。規約見 docs/COLLABORATION.md §1、§7。
#
# 用法：brand-skill-check.sh [repo 路徑]（參數只給自測餵臨時目錄用；CI 不帶參數）
set -uo pipefail

if [ $# -gt 1 ]; then
  echo "✗ brand-skill gate：只接受一個 repo 路徑參數（多給了 $2）" >&2
  exit 2
fi
if [ $# -eq 1 ]; then
  repo=$1
else
  repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "✗ brand-skill gate：不在 git repo 內且未給 repo 路徑（fail closed）" >&2
    exit 2
  }
fi
if [ ! -d "$repo" ]; then
  echo "✗ brand-skill gate：找不到目錄「${repo}」（fail closed）" >&2
  exit 2
fi

skill_dir="${repo}/.claude/skills/little-sprout-brand"
skill="${skill_dir}/SKILL.md"
agents=("${repo}/.claude/agents/ui-designer.md" "${repo}/.claude/agents/visual-reviewer.md")
hits=""

# 1. SKILL.md 存在且可讀
if [ ! -r "$skill" ]; then
  hits+="    ${skill#"$repo"/}：不存在或不可讀（skill 本體缺失，Skill 工具找不到 little-sprout-brand）"$'\n'
else
  # 2. frontmatter（純 bash 3.2 逐行；`|| [ -n "$line" ]` 讓末行無換行也讀得到）
  first=1; in_fm=0; closed=0; name_val=; desc_val=; has_name=0; has_desc=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [ "$first" -eq 1 ]; then
      first=0
      if [ "$line" = "---" ]; then in_fm=1; continue; fi
      break
    fi
    if [ "$in_fm" -eq 1 ]; then
      if [ "$line" = "---" ]; then closed=1; break; fi
      case "$line" in
        name:*)        has_name=1; name_val=${line#name:}; name_val=${name_val#"${name_val%%[![:space:]]*}"}; name_val=${name_val%"${name_val##*[![:space:]]}"} ;;
        description:*) has_desc=1; desc_val=${line#description:}; desc_val=${desc_val#"${desc_val%%[![:space:]]*}"}; desc_val=${desc_val%"${desc_val##*[![:space:]]}"} ;;
      esac
    fi
  done < "$skill"
  rel=${skill#"$repo"/}
  if [ "$in_fm" -eq 0 ]; then
    hits+="    ${rel}：第一行不是 \`---\`，沒有 frontmatter（Claude Code 不會把它列為 skill）"$'\n'
  else
    [ "$closed" -eq 1 ] || hits+="    ${rel}：frontmatter 沒有閉合的第二個 \`---\`"$'\n'
    if [ "$has_name" -eq 0 ]; then
      hits+="    ${rel}：frontmatter 缺 \`name:\`"$'\n'
    elif [ "$name_val" != "little-sprout-brand" ]; then
      hits+="    ${rel}：frontmatter \`name:\` 是「${name_val}」，必須等於目錄名 little-sprout-brand"$'\n'
    fi
    if [ "$has_desc" -eq 0 ] || [ -z "$desc_val" ]; then
      hits+="    ${rel}：frontmatter 缺 \`description:\` 或其值為空（description 是 skill 被觸發的唯一依據）"$'\n'
    fi
  fi
  # 3. SKILL.md 引用的 references/<x>.md 全部存在且非空（-s：0-byte 檔＝指到空檔）
  refs=$(grep -oE 'references/[A-Za-z0-9_.-]+\.md' "$skill" | sort -u || true)
  if [ -n "$refs" ]; then
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      if [ ! -s "${skill_dir}/${ref}" ]; then
        hits+="    ${rel} 引用 ${ref}，但 ${skill_dir#"$repo"/}/${ref} 不存在或為 0 bytes"$'\n'
      fi
    done <<< "$refs"
  fi
fi

# 4. 兩份 agent 定義各含「載入…little-sprout-brand」必載指示（陣列逐檔，路徑含空白不分詞）
for a in "${agents[@]}"; do
  rel=${a#"$repo"/}
  if [ ! -r "$a" ]; then
    hits+="    ${rel}：不存在或不可讀（agent 定義缺失，接線無從驗起）"$'\n'
  elif ! grep -qE '載入.*little-sprout-brand' "$a"; then
    hits+="    ${rel}：不含「載入…little-sprout-brand」必載指示（被拿掉了，或只剩註解／歷史提及）"$'\n'
  fi
done

if [ -n "$hits" ]; then
  echo "✗ brand-skill gate：little-sprout-brand skill 接線不完整（LS-30）：" >&2
  printf '%s' "$hits" >&2
  echo "  規則：ui-designer／visual-reviewer 開工必載入 .claude/skills/little-sprout-brand（docs/COLLABORATION.md §1、§7）；skill 本體要有 frontmatter name／description、references 指到的檔要存在且非空、兩份 agent 定義要保留「載入…little-sprout-brand」必載指示。" >&2
  exit 1
fi
echo "✓ brand-skill gate：little-sprout-brand skill 本體齊全、ui-designer／visual-reviewer 已接線"
