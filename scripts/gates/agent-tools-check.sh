#!/bin/bash
# Agent 定義工具白名單檢查（LS-87 R3 F2）。
#
# 前饋：.claude/agents/*.md 的 frontmatter `tools:` 是**窮舉**白名單——列了就只有那些工具。qa／merge-reviewer 的「裁決必貼
# commit status」靠 Bash 跑 scripts/ops/post-status.sh、讀票寫 comment 靠三支 Linear 工具；qa 視覺驗收對設計稿路徑靠
# mcp__pencil__get_app_state、實際取圖靠 mcp__pencil__execute（唯讀用途，見 qa.md；LS-91）；ui-designer／visual-reviewer
# 操作／截圖 .pen 也靠 mcp__pencil__execute。白名單漏列任何一支，該規約就靜默不可執行（CI 四項全綠、下一次派工才發現——
# R2 I3 指出、R2 F1 實際發生在 qa 漏了 pencil）。
# 這裡驗每份被點名的 agent 定義：檔案存在、frontmatter 閉合、`tools:` 行含全部必要工具（整字比對：`BashOutput` 不算 `Bash`）。
# 沒有 `tools:` 行＝繼承全部工具 → 放行並註明（白名單不存在就漏不了）。工具名是否真的存在於 MCP server 只有連上 server
# 才驗得到（CI 驗不了）——那是盲區；擋得住的是「白名單漏掉必要工具」。
# LS-170 第二張規則表「正文必含字樣」：規約寫在 agent 定義正文、只有正文到得了 agent；日後改寫／精簡定義把那段刪掉，規約就
# 靜默消失（LS-159 只把 `supabase-lock.sh --hold` 寫進 qa.md、ios-dev／merge-reviewer 沒有對應段落，LS-169 的 E2E 被他票合法
# 取得 lock 的 reset 打斷四次）。驗 frontmatter 之後的正文（fixed-string，不看位置；frontmatter 內出現不算）含指定字樣。
# 任一違規即紅並列出全部（不在第一條就停），exit 1；參數／路徑錯誤 exit 2（fail closed）。
# 掛 CI rules job（所有 PR，純檔案比對）；自測 agent-tools-check.test.sh。規約見 docs/COLLABORATION.md §1、§6、§7。
#
# 用法：agent-tools-check.sh [<agents 目錄>]（參數只給自測餵臨時目錄用；CI 不帶參數＝<repo>/.claude/agents）
set -uo pipefail

if [ $# -gt 1 ]; then
  echo "✗ agent-tools gate：只接受一個 agents 目錄參數（多給了 $2）" >&2
  exit 2
fi
if [ $# -eq 1 ]; then
  dir=$1
else
  root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "✗ agent-tools gate：不在 git repo 內且未給 agents 目錄（fail closed）" >&2
    exit 2
  }
  dir="${root}/.claude/agents"
fi
if [ ! -d "$dir" ]; then
  echo "✗ agent-tools gate：找不到目錄「${dir}」（fail closed）" >&2
  exit 2
fi

# 規則表：<agent>|<必要工具（空白分隔）>——加規約時在這裡加一行（前饋必有反饋）
# LS-91：qa 補釘 mcp__pencil__execute——qa.md 視覺驗收唯讀截圖靠它（get_app_state 對路徑後以 execute 的
# TakeScreenshot／Get 取圖），先前規則表只釘了 get_app_state，漏了實際取圖要用的工具。
# ios-dev 沒有 tools: 行（繼承全部工具），這裡仍列一行（必要工具留空）：確保「無 tools: 行＝放行」這條路徑
# 有樣本覆蓋，不只是隱含行為。
# LS-157：dead-code-sweeper 補 save_comment——巡檢結果改由 sweeper 直貼票（此前缺該工具、orchestrator 一日代貼三次）。
LINEAR3="mcp__linear__get_issue mcp__linear__list_comments mcp__linear__save_comment"
RULES="merge-reviewer|Bash ${LINEAR3}
qa|Bash ${LINEAR3} mcp__pencil__get_app_state mcp__pencil__execute
dead-code-sweeper|Bash ${LINEAR3}
ui-designer|mcp__pencil__execute
visual-reviewer|mcp__pencil__execute
ios-dev|"

# 正文必含字樣規則表（LS-170）：<agent>|<字樣>——規約段落被刪即紅。先給空值、再由標記區塊填入：自測的 mutation 負控用 awk 整段
# 拿掉標記區塊（留下空表）驗「拿掉規則後負樣本變綠」，證明紅是這條規則造成的（同 linear-issue-check.test.sh 慣例）。
# ios-dev／merge-reviewer／qa：互動式本機驗證（模擬器對本機 Supabase 容器的多步驟操作）前必 `supabase-lock.sh --hold`——qa 的同段
# 自 LS-159 起就在但當時沒有 gate，R2 (a) 一併釘住（三份同一條規則）。
BODY_RULES=
# LS170-BODY-RULES-START
BODY_RULES="ios-dev|supabase-lock.sh --hold
merge-reviewer|supabase-lock.sh --hold
qa|supabase-lock.sh --hold"
# LS170-BODY-RULES-END

hits=""; n=0
while IFS='|' read -r agent required; do
  [ -n "$agent" ] || continue
  n=$((n + 1))
  f="${dir}/${agent}.md"
  if [ ! -r "$f" ]; then
    hits+="    ${agent}.md：不存在或不可讀"$'\n'
    continue
  fi
  # frontmatter（純 bash 3.2 逐行；`|| [ -n "$line" ]` 讓末行無換行也讀得到）：只看第一個 --- 到第二個 --- 之間的 tools:，
  # 正文提到的「tools:」不算
  first=1; in_fm=0; closed=0; has_tools=0; tools_line=
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
        tools:*) has_tools=1; tools_line=${line#tools:} ;;
      esac
    fi
  done < "$f"
  if [ "$in_fm" -ne 1 ] || [ "$closed" -ne 1 ]; then
    hits+="    ${agent}.md：frontmatter 缺失或未閉合（第一行須 ---、其後須再有一行 ---）"$'\n'
    continue
  fi
  if [ "$has_tools" -eq 0 ]; then
    echo "  ${agent}.md：無 tools: 行（繼承全部工具）→ 放行"
    continue
  fi
  # 逗號→空白、壓成單一空白、前後各補一格：整字比對用 *" <tool> "*
  toks=" $(printf '%s' "$tools_line" | tr ',' ' ' | tr -s '[:space:]' ' ') "
  case "$toks" in
    *[![:space:]]*) ;;
    *) hits+="    ${agent}.md：tools: 值為空（YAML 多行清單不支援——請寫成同一行逗號分隔）"$'\n'; continue ;;
  esac
  missing=
  for t in $required; do
    case "$toks" in
      *" ${t} "*) ;;
      *) missing+=" ${t}" ;;
    esac
  done
  if [ -n "$missing" ]; then
    hits+="    ${agent}.md：tools: 缺${missing}"$'\n'
  else
    echo "  ${agent}.md：tools: 含必要工具（${required}）"
  fi
done <<RULES_EOF
$RULES
RULES_EOF

# 正文必含字樣（LS-170）：正文＝第二個 --- 之後（CR 一併剝除）；缺檔已由上表列出，這裡略過不重複；frontmatter 未閉合時正文為空、
# 會多列一條「正文缺」（上表已列未閉合，兩條都是真的）。
# R1 I-3：「缺檔略過不重複」依賴 BODY_RULES 的 agent ⊆ 工具表——不成立時缺檔會靜默跳過整條規則。先斷言，不成立＝兩表沒同步、exit 2。
while IFS='|' read -r agent _; do
  [ -n "$agent" ] || continue
  case $'\n'"${RULES}"$'\n' in
    *$'\n'"${agent}|"*) ;;
    *) echo "✗ agent-tools gate：正文規則表的 ${agent} 不在工具規則表（缺檔會靜默跳過）——兩表要同步（fail closed）" >&2; exit 2 ;;
  esac
done <<BODY_EOF
$BODY_RULES
BODY_EOF
m=0
while IFS='|' read -r agent literal; do
  [ -n "$agent" ] || continue
  m=$((m + 1))
  f="${dir}/${agent}.md"
  [ -r "$f" ] || continue
  body=$(awk '{ sub(/\r$/, "") } NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; b = 1; next } b { print }' "$f")
  if printf '%s' "$body" | grep -qF -- "$literal"; then
    echo "  ${agent}.md：正文含「${literal}」"
  else
    hits+="    ${agent}.md：正文缺「${literal}」（LS-170：互動式本機驗證先 hold 的規約段被刪或未寫；frontmatter 內出現不算）"$'\n'
  fi
done <<BODY_EOF
$BODY_RULES
BODY_EOF

if [ -n "$hits" ]; then
  echo "✗ agent-tools gate：agent 定義的 tools: 白名單缺必要工具、正文缺必含字樣（或檔案／frontmatter 有問題）：" >&2
  printf '%s' "$hits" >&2
  echo "  少了工具的規約會靜默不可執行（qa／merge-reviewer 少 Bash → 貼不了 status；qa 少 pencil → 開不了設計稿）。修 .claude/agents/<agent>.md 的 tools: 行（整字、逗號分隔）；沒有 tools: 行＝繼承全部工具。正文缺字樣＝該規約段被刪（LS-170：互動式本機驗證先 supabase-lock.sh --hold），補回正文。" >&2
  exit 1
fi
echo "✓ agent-tools gate 通過（${n} 份 agent 定義；正文必含字樣 ${m} 條）"
