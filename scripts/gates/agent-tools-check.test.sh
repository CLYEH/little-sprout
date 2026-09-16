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
# LS-256（㉓）：dead-code-sweeper 正文須含「禁派 fork」（LS-254 只釘五份，sweeper 是第六份）——缺即紅、工具齊全不救；同一 mutant 下負樣本變綠；
#   正文必含字樣總數 47→48。
# LS-299（㉗）：ios-dev／qa／merge-reviewer 正文須含 `scripts/ops/ci-wait.sh`（等 CI 改一律前景分段輪詢，取代 `gh run watch`）——
#   缺即紅、其餘句子齊全不救；同一 mutant 下負樣本變綠；正文必含字樣總數 53→56。
# LS-300（㉘，LS-96 池項 3aa46c78）：ios-dev 正文須含「實作新畫面必逐條對 Notes「畫面級屬性」並在 handoff 勾選」、
#   merge-reviewer 正文須含「對 handoff 勾選表抽兩列重放」——各自缺即紅、其餘句子齊全不救；同一 mutant 下負樣本變綠；
#   正文必含字樣總數 56→58。
# LS-306 A2（㉙）：ios-dev 正文須含 push-gate.sh 開始前的進度句（含「逾時被背景化就前景重跑 push，快取秒過」）——
#   缺即紅、其餘句子齊全不救；同一 mutant 下負樣本變綠；正文必含字樣總數 58→59。
# LS-306 B1（㉚）：ui-designer／visual-reviewer 正文須含 `scripts/ops/ci-wait.sh`（同 ios-dev／qa／
#   merge-reviewer 既有 CIWAIT 句）——各自缺即紅、其餘句子齊全不救；同一 mutant 下負樣本變綠；
#   正文必含字樣總數 59→61。
# LS-308 B2：六份 agent 定義正文皆須含 mcp__linear__* 備援句（Linear MCP token 過期時改用
#   bash scripts/ops/linear-post.sh get|comment|state，並在 handoff 註明走備援）——併進全部六份合法樣本；
#   正文必含字樣總數 61→67。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/agent-tools-check.sh"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n+1)); }
# has <文字> <子字串>：LS-301 起改用共用庫（scripts/gates/lib/selftest-helpers.sh），語意不變
# （here-string 比對，避免 `printf | grep -q` 在 pipefail 下的 SIGPIPE 誤判，LS-295）。
source "${root}/scripts/gates/lib/selftest-helpers.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
agents="$work/agents"

# expect <期望 exit> <名稱> <輸出必含|''> [<第二個必含>] [<不得含>]（對 $agents 跑 checker）
expect() {
  local want=$1 name=$2 must=$3 must2=${4:-} mustnot=${5:-} out got
  out="$(bash "$checker" "$agents" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || has "$out" "$must"; } \
     && { [ -z "$must2" ] || has "$out" "$must2"; } \
     && { [ -z "$mustnot" ] || ! has "$out" "$mustnot"; }; then
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
# LS-207（a7b0f49e）：ios-dev／qa／merge-reviewer 正文另須含這句（三份都要，併進 LOCK_BODY）
TIMEOUT_RULE='git push／xcodebuild／run.sh 等長命令一律前景 Bash 帶 timeout（≤25 分），禁用背景＋等通知。'
LOCK_BODY="${HOLD} ${H3B} ${TIMEOUT_RULE}"
# LS-211：三份正文另須含「「已驗證」逐項對應派工單／票文編號，並寫「怎麼驗」」；qa／merge-reviewer 另須含
# 「貼 comment 前先跑 handoff-evidence-check.sh」的命令句（ios-dev 不要求，因為 ios-dev 不貼裁決 comment）。
EVIDENCE_ITEM='「已驗證」逐項對應派工單／票文編號，並寫「怎麼驗」（測試名或路徑）。'
# R2（merge-review R1 F3）：措辭改為「跑過並附輸出；紅則逐條說明是誤判或補證據」——不要求一定要綠，
# 避免 agent 為了討好工具改寫正確敘述。拆兩個變數才能各自獨立缺席（⑱ 要測「只有命令句缺說明句」）。
EVIDENCE_RUN_CMD='貼 comment 前先跑 `bash scripts/gates/handoff-evidence-check.sh <暫存檔>`，把輸出附在 comment 末尾；'
EVIDENCE_RUN_EXPLAIN='紅則逐條說明是誤判或補證據，不得為了討好工具改寫正確敘述。'
EVIDENCE_RUN="${EVIDENCE_RUN_CMD}${EVIDENCE_RUN_EXPLAIN}"
# LS-158：qa 正文另須含 `qa-e2e.sh`（多步驟驗收優先端到端驅動）；合法的 qa 樣本三句都要有
E2E='多步驟驗收優先 `bash scripts/ops/qa-e2e.sh <login|publish|browse>`。'
# LS-207（c18ef27f）：qa／merge-reviewer 正文另須含這句（ios-dev 不要求，不併進 LOCK_BODY／IOS_BODY）
# LS-207 R3（merge-review R2 b907173c N1）：句子本身之外，數值本身也要對得上——SIMCTLUI 帶 large，SIMCTLUI_MEDIUM 是
# R2 之前的舊數值（regression 樣本），句子仍在但值錯，用來證明新規則只釘數值、不是重複釘句子。
SIMCTLUI='用 `simctl ui` 改過字級／外觀的 handoff 必列已復原（會自動把 content_size／appearance 改成 large／light）。'
SIMCTLUI_MEDIUM='用 `simctl ui` 改過字級／外觀的 handoff 必列已復原（會自動把 content_size／appearance 改成 medium／light）。'
# LS-215：ios-dev／qa／merge-reviewer 正文另須引用新 PreToolUse gate 名稱
BGGATE='PreToolUse `background-bash-guard.sh`（LS-215）機械擋 run_in_background:true 與背景化再等的命令文字慣用形狀。'
# LS-236：三份正文另須含「不得依賴截斷後的自動背景化」（工具 timeout 600000 截斷後子行程不會被殺掉，
# 殘留會與下一輪 xcodebuild 搶模擬器，stale-xcodebuild-check.sh 機械擋殘留）
NOBGXC='xcodebuild 一律前景、Bash timeout 600000（工具上限）；預期超過 10 分鐘的測試以 -only-testing 分段跑；不得依賴截斷後的自動背景化。'
# LS-254：五份（ios-dev／ui-designer／visual-reviewer／merge-reviewer／qa）正文另須含「禁派 fork」（fork 繼承整份派工單並平行
# 執行整項任務；PreToolUse fork-guard.sh 機械擋非主 session 的 subagent_type: fork）；併進五份合法樣本
NOFORK254='研究用 `Explore`（唯讀）；禁派 fork（LS-254）——fork 繼承整份派工單、會把它當自己的任務平行執行。'
QA_BODY="${LOCK_BODY} ${E2E} ${SIMCTLUI} ${EVIDENCE_ITEM} ${EVIDENCE_RUN} ${BGGATE} ${NOBGXC} ${NOFORK254}"
# LS-180：ui-designer／visual-reviewer 正文須含「--kill 只在 orchestrator 明示時」（切檔不殺行程的規約句）
KILL='切檔一律不殺行程；`pen-open.sh` 的 --force-reload／--kill 只在 orchestrator 明示時使用，用後必回報「需重連」。'
# LS-180 裁決：ui-designer 正文另須含「收工 Pen 停在票檔」（不切回主 checkout）；合法的 ui-designer 樣本兩句都要有
STAY='handoff 前不切回主 checkout：收工 Pen 停在票檔，handoff 註明路徑。'
# LS-264（LS-96 池項 c1b67f93）：ui-designer／visual-reviewer 正文另須含「editId 成功套用後即失效」
# （Pencil execute 的 edits/editId 成功後不能再用，分批每批都要重送 snippet 全文）；併進兩份合法樣本
EDITID='`execute` 的 editId 成功套用後即失效，分批每批都要重送 snippet 全文。'
UI_BODY="${KILL} ${STAY} ${NOFORK254} ${EDITID}"
# LS-254：visual-reviewer 合法樣本＝LS-180 的 --kill 句＋禁派 fork 句（不要求收工句，見 ⑧）
VR_BODY="${KILL} ${NOFORK254} ${EDITID}"
# LS-186：ios-dev 正文另須含 CI 完整旗標的 PR body 驗證句；OLD_PRBODY 是 LS-186 之前的裸寫法（⑪ 的負樣本）
PRBODY='`gh pr create/edit --body-file <f>` 之前先 `bash scripts/gates/pr-body-check.sh <f> --branch <分支> --verify`，直接看 exit code。'
OLD_PRBODY='`gh pr create/edit --body-file <f>` 之前先 `bash scripts/gates/pr-body-check.sh <f>` 斷言檔頭段含本票票號。'
# LS-207：ios-dev／merge-reviewer 正文另須含這兩句（qa 不要求，不併進 LOCK_BODY／QA_BODY）
DBCHAN='DB 測試 handoff 必附通道：抄 run.sh 印出的連線方式那一行。'
SHEETUI='iOS 26.2+ sheet 內 UITest 座標斷言用相對參照、可點元件 minHeight ≥48。'
# LS-209：ios-dev 正文另須含「不得派 fork／subagent 改動任何檔案」（禁動 Pen、禁派會寫檔的 subagent）
NOFORK='不得派 fork／subagent 改動任何檔案。'
# LS-209：ios-dev 正文另須含 mutation 三段式（改了什麼一行 → 哪條測試紅 → 斷言訊息原文）；merge-reviewer
# 正文另須含「handoff 申報的 mutation 一律自己重放，對不上列 major」
MUTPLAY='每支 mutation 必列三段：改了什麼一行 → 哪條測試紅 → 斷言訊息原文。'
REPLAYRULE='handoff 申報的 mutation 一律自己重放，對不上列 major。'
# LS-270（LS-96 池項 d4c1add5(c)）：merge-reviewer 正文另須含「shell 自測在 ubuntu:24.04 通道跑 ≥10 次」
# （BSD-GNU 差異有一整類是機率性的，macOS 跑一次綠不算驗過）；併進 merge-reviewer 的合法樣本
UBUNTU10='shell 自測在 ubuntu:24.04 通道跑 ≥10 次並記錄紅幾次，macOS 跑一次綠不算驗過。'
UBUNTU1='shell 自測在 ubuntu:24.04 通道跑一次確認。'
# LS-270（LS-96 池項 3e9347c4(5)／8a946ea2(3)）：merge-reviewer 的 mutation 段另須含兩句——UITest mutation
# 重放的判準（xcodebuild 可能沒把改動編進 bundle → 只看 exit code 是假綠）與「macOS 沒有 timeout 指令」
# （timeout 600 xcodebuild … exit 127＝根本沒跑）；併進 merge-reviewer 的合法樣本
UITESTMUT='UITest mutation 重放要看失敗點／時間軸是否隨 mutation 改變，不能只看 exit code。'
NOTIMEOUT='macOS 沒有 timeout 指令，exit 127＝整個測試沒跑過；改用 gtimeout 或 XCTest 看門狗。'
# LS-232：ios-dev 正文另須含「新增登入後全屏 gate 必同 PR 更新 QADriver」（qa-driver-gate-check 機械化）
QAGATE='新增登入後全屏 gate 必同 PR 更新 QADriver（`qa-driver-gate-check` 會擋）。'
# LS-299（源自 LS-96 池項 26bbff68）：三份正文另須含 `scripts/ops/ci-wait.sh`——等 CI 改一律前景分段輪詢，
# 取代 `gh run watch`（撞 Bash 工具 600s 上限被系統移背景後停下等通知，09-15 三次事故）
CIWAIT='等 CI 一律前景 `bash scripts/ops/ci-wait.sh <run-id>`（exit 3 就再跑一次；禁 `gh run watch`、禁 `run_in_background`）。'
QA_BODY="${QA_BODY} ${CIWAIT}"
# LS-300（LS-96 池項 3aa46c78）：ios-dev 正文須含「實作新畫面必逐條對 Notes「畫面級屬性」並在 handoff 勾選」；
# merge-reviewer 正文須含「對 handoff 勾選表抽兩列重放」（qa 不要求，不併進 QA_BODY）
SCREENATTR='實作新畫面必逐條對 Notes「畫面級屬性」並在 handoff 勾選。'
REPLAYSCREENATTR='對 handoff 勾選表抽兩列重放。'
# LS-306 A2：ios-dev 正文另須含 push-gate.sh 開始前的進度句（含「快取秒過」提示，同句寫進
# scripts/gates/push-gate.sh 的實際 echo）
PUSHCACHE='push gate 同 tree 快取，unit tests 開始前印「→ push gate：unit tests 開始（<時間>，通常 5–12 分；逾時被背景化就前景重跑 push，快取秒過）」。'
IOS_BODY="${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE} ${QAGATE} ${NOBGXC} ${NOFORK254} ${CIWAIT} ${SCREENATTR} ${PUSHCACHE}"
MR_BODY="${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI} ${REPLAYRULE} ${EVIDENCE_ITEM} ${EVIDENCE_RUN} ${BGGATE} ${NOBGXC} ${NOFORK254} ${UBUNTU10} ${UITESTMUT} ${NOTIMEOUT} ${CIWAIT} ${REPLAYSCREENATTR}"
# LS-306 B1：ui-designer／visual-reviewer 正文另須含 `scripts/ops/ci-wait.sh`（同 ios-dev／qa／
# merge-reviewer 既有的 CIWAIT 句，直接併進兩份合法樣本，不另立新常數）
UI_BODY="${UI_BODY} ${CIWAIT}"
VR_BODY="${VR_BODY} ${CIWAIT}"
# LS-308 B2：六份 agent 定義正文皆須含 mcp__linear__* 備援句（Linear MCP token 過期時改用 linear-post.sh）——
# 併進全部六份合法樣本（IOS_BODY／MR_BODY／QA_BODY／UI_BODY／VR_BODY 五個變數＋下面 reset() 的 dead-code-sweeper
# mk 呼叫，dead-code-sweeper 在 reset() 裡直接用 $NOFORK254 當整份正文、沒有專屬 ALLBODY 變數）
LINEARFALLBACK='mcp__linear__* 失敗（token 過期／斷線）時改用 bash scripts/ops/linear-post.sh get|comment|state，並在 handoff 註明走備援。'
IOS_BODY="${IOS_BODY} ${LINEARFALLBACK}"
MR_BODY="${MR_BODY} ${LINEARFALLBACK}"
QA_BODY="${QA_BODY} ${LINEARFALLBACK}"
UI_BODY="${UI_BODY} ${LINEARFALLBACK}"
VR_BODY="${VR_BODY} ${LINEARFALLBACK}"
# LS-209：ios-dev 新增 tools: 白名單（移除 mcp__pencil__*）——取代舊的 `NONE`（無 tools: 行＝繼承全部工具，其中
# 必然含 pencil，會被新的「禁止工具」規則擋下）。merge-review R1 M2：RULES 表現在對 ios-dev 有必要工具要求
# （Bash／Read／Edit／Write／Grep／Glob／Agent／三支 Linear 工具），這裡的乾淨清單須包含全部才能當合法基準。
IOS_TOOLS="Bash, Read, Edit, Write, Grep, Glob, Agent, ${LINEAR3}"
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
  mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "$MR_BODY"
  mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "$QA_BODY"
  mk dead-code-sweeper "Bash, Read, Grep, Glob, ${LINEAR3}" "${NOFORK254} ${LINEARFALLBACK}"
  mk ui-designer NONE "$UI_BODY"
  mk visual-reviewer NONE "$VR_BODY"
  mk ios-dev "$IOS_TOOLS" "$IOS_BODY"
}

# ---- ① 合法 ----
reset; expect 0 '① 六份齊、白名單含必要工具 → exit 0' '✓ agent-tools gate 通過（6 份' 'ios-dev.md：tools: 不含被禁工具（字首「mcp__pencil__」）'
reset; expect 0 '① ui-designer／visual-reviewer 仍可無 tools: 行（未被列進禁止工具表）→ 放行' 'ui-designer.md：無 tools: 行（繼承全部工具）→ 放行' 'visual-reviewer.md：無 tools: 行（繼承全部工具）→ 放行'
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
# LS-209 merge-review R1 M2：ios-dev 現在有必要工具表（曾經留空、「規則表無要求」故意讓任何子集通過）——
# 缺 Bash／Read 等基本工具，或漏了三支 Linear 工具的任一支，都要紅，不能再靜默放行。
reset; mk ios-dev "Read, Edit" "$IOS_BODY"; expect 1 '② M2：ios-dev 有 tools: 行但缺必要工具 → exit 1（regression：曾經規則表無要求，本票起要求）' 'ios-dev.md：tools: 缺'
reset; mk ios-dev "Bash, Read, Edit, Write, Grep, Glob, Agent, mcp__linear__get_issue, mcp__linear__list_comments" "$IOS_BODY"; expect 1 '② M2：ios-dev 缺 mcp__linear__save_comment（i1：白名單加回）→ exit 1' 'ios-dev.md：tools: 缺 mcp__linear__save_comment'
reset; expect 0 '② M2：ios-dev 具備完整必要工具（含三支 Linear）→ 通過' 'ios-dev.md：tools: 含必要工具'
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
reset; expect 0 '⑤ 三份正文含字樣 → 印「正文含」、通過（67 條）' 'ios-dev.md：正文含「supabase-lock.sh --hold」' '正文必含字樣 67 條）'
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
reset; mk visual-reviewer NONE "$VR_BODY"; expect 0 '⑧ LS-180 裁決：visual-reviewer 不要求收工句 → 仍通過' '通過'
# LS-183：ios-dev／merge-reviewer／qa 正文須含「本機容器操作同樣要在 lock 內」——只有 hold 句、H3b 句被刪即紅；三份都驗；工具齊全不救
reset; expect 0 '⑨ LS-183：三份正文含 H3b 句 → 印「正文含」' 'ios-dev.md：正文含「本機容器操作同樣要在 lock 內」' 'qa.md：正文含「本機容器操作同樣要在 lock 內」'
reset; mk ios-dev "$IOS_TOOLS" "$HOLD"; expect 1 '⑨ LS-183：ios-dev 只有 hold 句、缺 H3b 句 → exit 1' 'ios-dev.md：正文缺「本機容器操作同樣要在 lock 內」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "$HOLD"; expect 1 '⑨ LS-183：merge-reviewer 缺 H3b 句 → exit 1' 'merge-reviewer.md：正文缺「本機容器操作同樣要在 lock 內」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${HOLD} ${E2E}"; expect 1 '⑨ LS-183：qa 有 hold＋e2e、缺 H3b 句 → exit 1，工具齊全不救' 'qa.md：正文缺「本機容器操作同樣要在 lock 內」' '' 'qa.md：tools: 缺'
reset; mk ios-dev "$IOS_TOOLS" "${HOLD} 只寫 docker exec 而沒有那句規約不算"; expect 1 '⑨ LS-183：只有 docker exec 字面、無「同樣要在 lock 內」→ 紅' 'ios-dev.md：正文缺「本機容器操作同樣要在 lock 內」'
# LS-184：三份正文的 `--hold` 寫法須為 `cd <worktree> && bash scripts/ops/supabase-lock.sh --hold` 同一命令鏈——裸 `--hold` 句（舊字樣 `supabase-lock.sh --hold` 仍在）即紅；三份都驗；工具齊全不救
reset; expect 0 '⑩ LS-184：三份正文含 cd <worktree> && … --hold 同鏈句 → 印「正文含」' 'ios-dev.md：正文含「cd <worktree> && bash scripts/ops/supabase-lock.sh --hold」' 'qa.md：正文含「cd <worktree> && bash scripts/ops/supabase-lock.sh --hold」'
reset; mk ios-dev "$IOS_TOOLS" "${BARE_HOLD} ${H3B}"; expect 1 '⑩ LS-184：ios-dev 只有裸 --hold（無 cd 同鏈）→ exit 1，舊字樣仍在不救' 'ios-dev.md：正文缺「cd <worktree> && bash scripts/ops/supabase-lock.sh --hold」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${BARE_HOLD} ${H3B}"; expect 1 '⑩ LS-184：merge-reviewer 裸 --hold → exit 1' 'merge-reviewer.md：正文缺「cd <worktree> && bash scripts/ops/supabase-lock.sh --hold」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${BARE_HOLD} ${H3B} ${E2E}"; expect 1 '⑩ LS-184：qa 裸 --hold → exit 1，工具齊全不救' 'qa.md：正文缺「cd <worktree> && bash scripts/ops/supabase-lock.sh --hold」' '' 'qa.md：tools: 缺'
reset; mk ios-dev "$IOS_TOOLS" "先 cd <worktree>，另一條命令再 bash scripts/ops/supabase-lock.sh --hold 不算同鏈。${H3B}"; expect 1 '⑩ LS-184：cd 與 --hold 不在同一命令鏈（沒有 &&）→ 紅' 'ios-dev.md：正文缺「cd <worktree> && bash scripts/ops/supabase-lock.sh --hold」'
# LS-186：ios-dev 正文的 PR body 驗證句須帶 CI 完整旗標 `pr-body-check.sh <f> --branch <分支> --verify`——裸 `pr-body-check.sh <f>`（LS-185 前寫法）即紅；
# lock 三句齊全不救；merge-reviewer／qa 不要求
reset; expect 0 '⑪ LS-186：ios-dev 正文含 pr-body-check.sh <f> --branch <分支> --verify → 印「正文含」' 'ios-dev.md：正文含「pr-body-check.sh <f> --branch <分支> --verify」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${OLD_PRBODY}"; expect 1 '⑪ LS-186：ios-dev 只有裸 pr-body-check.sh <f>（無 --branch --verify）→ exit 1，lock 三句齊全不救' 'ios-dev.md：正文缺「pr-body-check.sh <f> --branch <分支> --verify」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} 先 bash scripts/gates/pr-body-check.sh <f> --verify 再看，沒有 --branch 不算。"; expect 1 '⑪ LS-186：只有 --verify、沒有 --branch <分支> → 紅' 'ios-dev.md：正文缺「pr-body-check.sh <f> --branch <分支> --verify」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "$MR_BODY"; expect 0 '⑪ LS-186：merge-reviewer 不要求 pr-body-check 句 → 仍通過' '通過'
reset; expect 0 '⑤ merge-reviewer／qa 也印「正文含」' 'merge-reviewer.md：正文含「supabase-lock.sh --hold」' 'qa.md：正文含「supabase-lock.sh --hold」'
reset; mk ios-dev "$IOS_TOOLS"; expect 1 '⑤ ios-dev 正文缺字樣 → exit 1' 'ios-dev.md：正文缺「supabase-lock.sh --hold」' '' '✓ agent-tools gate 通過'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}"; expect 1 '⑤ merge-reviewer 正文缺字樣 → exit 1' 'merge-reviewer.md：正文缺「supabase-lock.sh --hold」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill"; expect 1 '⑤ qa 正文缺字樣（R2 (a)）→ exit 1，工具齊全不救' 'qa.md：正文缺「supabase-lock.sh --hold」' '' 'qa.md：tools: 缺'
reset; mk ios-dev "$IOS_TOOLS"; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}"; expect 1 '⑤ 兩份同時缺 → 一次列完' 'ios-dev.md：正文缺' 'merge-reviewer.md：正文缺'
reset; mk ios-dev "$IOS_TOOLS" "只寫 supabase-lock.sh --release 不算"; expect 1 '⑤ 只有 --release 沒有 --hold → 紅' 'ios-dev.md：正文缺'
reset; printf -- '---\nname: ios-dev\ndescription: frontmatter 提到 supabase-lock.sh --hold 不算\nmodel: sonnet\n---\n\n正文。\n' > "$agents/ios-dev.md"; expect 1 '⑤ 字樣只在 frontmatter → 仍紅（只看正文）' 'ios-dev.md：正文缺'
reset; printf -- '---\r\nname: ios-dev\r\ntools: %s\r\nmodel: sonnet\r\n---\r\n\r\n%s\r\n' "$IOS_TOOLS" "$IOS_BODY" > "$agents/ios-dev.md"; expect 0 '⑤ CRLF 正文含字樣 → exit 0' 'ios-dev.md：正文含'
reset; mk ios-dev "Read" ; mk merge-reviewer "Read"; expect 1 '⑤ 工具缺與正文缺同時 → 兩類一起列' 'merge-reviewer.md：tools: 缺' 'merge-reviewer.md：正文缺'
# mutation 負控（同 linear-issue-check.test.sh 慣例）：拿掉 LS170-BODY-RULES 區塊（留下空表）後，上面「ios-dev 正文缺」的
# 同一份負樣本必須變綠——證明紅是這條規則造成的，不是別條規則湊巧命中；先驗 mutant 確實不含區塊，否則負控本身無效。
mut="$work/agent-tools-check.no-body-rules.sh"
awk 'index($0, "LS170-BODY-RULES-START") > 0 { skip = 1 } skip != 1 { print } index($0, "LS170-BODY-RULES-END") > 0 { skip = 0 }' "$checker" > "$mut"
if grep -q -e 'LS170-BODY-RULES-START' -e 'ios-dev|supabase-lock.sh --hold' "$mut"; then
  echo "✗ ⑤ mutant 仍含正文規則區塊（awk 拿掉失敗，負控本身無效）" >&2; fail=1
else
  ok '⑤ mutant 確實已拿掉正文規則區塊'
fi
reset; mk ios-dev "$IOS_TOOLS"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && grep -qF '✓ agent-tools gate 通過' <<<"$out" && ! grep -qF '正文缺' <<<"$out"; then
  ok '⑤ mutant：拿掉規則後同一份負樣本變綠（證明規則區塊確實是原因）'
else
  echo "✗ ⑤ mutant 應 exit 0 且不印「正文缺」（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
# LS-183 負控：同一個 mutant（規則區塊整段拿掉）下，上面 ⑨「只有 hold 句、缺 H3b 句」的負樣本也必須變綠——證明 ⑨ 的紅來自規則表的 H3b 行
reset; mk ios-dev "$IOS_TOOLS" "$HOLD"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '本機容器操作同樣要在 lock 內' <<<"$out"; then
  ok '⑨ mutant：拿掉規則後「只有 hold 句」的負樣本變綠（H3b 行確實是原因）'
else
  echo "✗ ⑨ mutant 應 exit 0 且不印 H3b 字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
# LS-184 負控：同一個 mutant 下，上面 ⑩「裸 --hold（無 cd 同鏈）」的負樣本也必須變綠——證明 ⑩ 的紅來自規則表的 LS-184 行
reset; mk ios-dev "$IOS_TOOLS" "${BARE_HOLD} ${H3B}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'cd <worktree> &&' <<<"$out"; then
  ok '⑩ mutant：拿掉規則後「裸 --hold」的負樣本變綠（LS-184 行確實是原因）'
else
  echo "✗ ⑩ mutant 應 exit 0 且不印 cd <worktree> && 字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
# LS-186 負控：同一個 mutant 下，上面 ⑪「裸 pr-body-check.sh <f>」的負樣本也必須變綠——證明 ⑪ 的紅來自規則表的 LS-186 行
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${OLD_PRBODY}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'pr-body-check.sh <f> --branch' <<<"$out"; then
  ok '⑪ mutant：拿掉規則後「裸 pr-body-check.sh <f>」的負樣本變綠（LS-186 行確實是原因）'
else
  echo "✗ ⑪ mutant 應 exit 0 且不印 pr-body-check.sh <f> --branch 字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
# ---- ⑫ LS-207：ios-dev／merge-reviewer 正文須含「DB 測試 handoff 必附通道」與「sheet 內 UITest 座標斷言用相對參照、
#        可點元件 minHeight ≥48」；qa 不要求 ----
reset; expect 0 '⑫ ios-dev／merge-reviewer 正文含 DB 測試通道句 → 印「正文含」' 'ios-dev.md：正文含「DB 測試 handoff 必附通道」' 'merge-reviewer.md：正文含「DB 測試 handoff 必附通道」'
reset; expect 0 '⑫ ios-dev／merge-reviewer 正文含 sheet UITest 句 → 印「正文含」' 'ios-dev.md：正文含「sheet 內 UITest 座標斷言用相對參照、可點元件 minHeight ≥48」' 'merge-reviewer.md：正文含「sheet 內 UITest 座標斷言用相對參照、可點元件 minHeight ≥48」'
reset; mk ios-dev "$IOS_TOOLS" "$LOCK_BODY ${PRBODY} ${SHEETUI}"; expect 1 '⑫ ios-dev 缺 DB 測試通道句 → exit 1，其餘句子齊全不救' 'ios-dev.md：正文缺「DB 測試 handoff 必附通道」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "$LOCK_BODY ${SHEETUI}"; expect 1 '⑫ merge-reviewer 缺 DB 測試通道句 → exit 1' 'merge-reviewer.md：正文缺「DB 測試 handoff 必附通道」'
reset; mk ios-dev "$IOS_TOOLS" "$LOCK_BODY ${PRBODY} ${DBCHAN}"; expect 1 '⑫ ios-dev 缺 sheet UITest 句 → exit 1' 'ios-dev.md：正文缺「sheet 內 UITest 座標斷言用相對參照、可點元件 minHeight ≥48」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "$LOCK_BODY ${DBCHAN}"; expect 1 '⑫ merge-reviewer 缺 sheet UITest 句 → exit 1' 'merge-reviewer.md：正文缺「sheet 內 UITest 座標斷言用相對參照、可點元件 minHeight ≥48」'
reset; expect 0 '⑫ qa 不要求這兩句 → 仍通過' '通過'
# mutation 負控：同一個「拿掉 LS170-BODY-RULES 區塊」mutant 下，⑫ 的兩份負樣本也必須變綠
reset; mk ios-dev "$IOS_TOOLS" "$LOCK_BODY ${PRBODY} ${SHEETUI}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'DB 測試 handoff 必附通道' <<<"$out"; then
  ok '⑫ mutant：拿掉規則後「缺 DB 通道句」的負樣本變綠'
else
  echo "✗ ⑫ mutant（DB 通道）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
reset; mk ios-dev "$IOS_TOOLS" "$LOCK_BODY ${PRBODY} ${DBCHAN}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'minHeight ≥48' <<<"$out"; then
  ok '⑫ mutant：拿掉規則後「缺 sheet UITest 句」的負樣本變綠'
else
  echo "✗ ⑫ mutant（sheet UITest）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑬ LS-207（a7b0f49e）：ios-dev／qa／merge-reviewer 正文須含「等長命令一律前景 Bash 帶 timeout」 ----
reset; expect 0 '⑬ 三份正文含長命令前景 timeout 句 → 印「正文含」' 'ios-dev.md：正文含「等長命令一律前景 Bash 帶 timeout」' 'qa.md：正文含「等長命令一律前景 Bash 帶 timeout」'
reset; mk ios-dev "$IOS_TOOLS" "${HOLD} ${H3B} ${PRBODY} ${DBCHAN} ${SHEETUI}"; expect 1 '⑬ ios-dev 缺長命令前景 timeout 句 → exit 1，其餘句子齊全不救' 'ios-dev.md：正文缺「等長命令一律前景 Bash 帶 timeout」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${HOLD} ${H3B} ${E2E}"; expect 1 '⑬ qa 缺長命令前景 timeout 句 → exit 1' 'qa.md：正文缺「等長命令一律前景 Bash 帶 timeout」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${HOLD} ${H3B} ${DBCHAN} ${SHEETUI}"; expect 1 '⑬ merge-reviewer 缺長命令前景 timeout 句 → exit 1' 'merge-reviewer.md：正文缺「等長命令一律前景 Bash 帶 timeout」'
reset; mk ios-dev "$IOS_TOOLS" "${HOLD} ${H3B} ${PRBODY} ${DBCHAN} ${SHEETUI}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '等長命令一律前景 Bash 帶 timeout' <<<"$out"; then
  ok '⑬ mutant：拿掉規則後「缺長命令前景 timeout 句」的負樣本變綠'
else
  echo "✗ ⑬ mutant 應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑭ LS-207（c18ef27f）：qa／merge-reviewer 正文須含「用 `simctl ui` 改過字級／外觀的 handoff 必列已復原」；ios-dev 不要求 ----
reset; expect 0 'qa／merge-reviewer 正文含 simctl ui 復原句 → 印「正文含」' 'qa.md：正文含「用 `simctl ui` 改過字級／外觀的 handoff 必列已復原」' 'merge-reviewer.md：正文含「用 `simctl ui` 改過字級／外觀的 handoff 必列已復原」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${LOCK_BODY} ${E2E}"; expect 1 'qa 缺 simctl ui 復原句 → exit 1，其餘句子齊全不救' 'qa.md：正文缺「用 `simctl ui` 改過字級／外觀的 handoff 必列已復原」' '' 'qa.md：正文缺「qa-e2e.sh」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI}"; expect 1 'merge-reviewer 缺 simctl ui 復原句 → exit 1' 'merge-reviewer.md：正文缺「用 `simctl ui` 改過字級／外觀的 handoff 必列已復原」'
reset; expect 0 'ios-dev 不要求 simctl ui 復原句 → 仍通過' '通過'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${LOCK_BODY} ${E2E}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'simctl ui' <<<"$out"; then
  echo '✓ mutant：拿掉規則後「缺 simctl ui 復原句」的負樣本變綠'
else
  echo "✗ mutant（simctl ui）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑭-b LS-207 R3（merge-review R2 b907173c N1）：句子在但數值寫 medium（R2 之前的舊值）→ 仍紅，只釘句子不夠 ----
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${LOCK_BODY} ${E2E} ${SIMCTLUI_MEDIUM}"; expect 1 '⑭-b qa 復原句寫 medium（非 large）→ exit 1，句子本身在也不救' 'qa.md：正文缺「content_size／appearance 改成 large」' '' 'qa.md：正文缺「用 `simctl ui` 改過字級／外觀的 handoff 必列已復原」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI_MEDIUM}"; expect 1 '⑭-b merge-reviewer 復原句寫 medium → exit 1' 'merge-reviewer.md：正文缺「content_size／appearance 改成 large」' '' 'merge-reviewer.md：正文缺「用 `simctl ui` 改過字級／外觀的 handoff 必列已復原」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${LOCK_BODY} ${E2E} ${SIMCTLUI_MEDIUM}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'content_size／appearance 改成 large' <<<"$out"; then
  echo '✓ ⑭-b mutant：拿掉規則後「復原句寫 medium」的負樣本變綠（新數值規則確實是原因）'
else
  echo "✗ ⑭-b mutant 應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑮ LS-209：FORBIDDEN_RULES（禁止工具）——ios-dev 不得含 mcp__pencil__*；沒有 tools: 行（繼承全部工具）也算違規，
#        不是「放行」（與 RULES 必要工具表的「無 tools: 行→放行」語意刻意不同：那條規則沒有要求，這條規則有明確禁止）----
reset; mk ios-dev "${IOS_TOOLS}, mcp__pencil__execute" "$IOS_BODY"; expect 1 '⑮ ios-dev tools: 含 mcp__pencil__execute → exit 1' 'ios-dev.md：tools: 含被禁工具（字首「mcp__pencil__」）'
reset; mk ios-dev "${IOS_TOOLS}, mcp__pencil__get_app_state" "$IOS_BODY"; expect 1 '⑮ ios-dev tools: 含 mcp__pencil__get_app_state（任何 mcp__pencil__* 都算，不只 execute）→ exit 1' 'ios-dev.md：tools: 含被禁工具（字首「mcp__pencil__」）'
reset; mk ios-dev NONE "$IOS_BODY"; expect 1 '⑮ ios-dev 無 tools: 行（繼承全部工具，隱含含 pencil）→ exit 1，不是放行' 'ios-dev.md：無 tools: 行（繼承全部工具）——隱含含有禁止工具「mcp__pencil__*」'
reset; expect 0 '⑮ ios-dev tools: 明確列出且不含 mcp__pencil__* → 通過' 'ios-dev.md：tools: 不含被禁工具（字首「mcp__pencil__」）'
# mutation：FORBIDDEN_RULES 整條清空 → 上面「含 mcp__pencil__execute」的負樣本必須變綠，證明紅是這條規則造成的
mut_forbid="$work/agent-tools-check.no-forbidden.sh"
sed 's/^FORBIDDEN_RULES="ios-dev|mcp__pencil__"$/FORBIDDEN_RULES=""/' "$checker" > "$mut_forbid"
if grep -q '^FORBIDDEN_RULES=""$' "$mut_forbid" && ! grep -q 'FORBIDDEN_RULES="ios-dev|mcp__pencil__"' "$mut_forbid"; then
  ok '⑮ mutant 確實已清空 FORBIDDEN_RULES'
else
  echo "✗ ⑮ mutant 清空失敗（sed 未命中，負控本身無效）" >&2; fail=1
fi
reset; mk ios-dev "${IOS_TOOLS}, mcp__pencil__execute" "$IOS_BODY"
out="$(bash "$mut_forbid" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '含被禁工具' <<<"$out"; then
  ok '⑮ mutant：清空 FORBIDDEN_RULES 後「tools: 含 mcp__pencil__execute」的負樣本變綠（禁止工具規則確實是原因）'
else
  echo "✗ ⑮ mutant 應 exit 0 且不印「含被禁工具」（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
reset; mk ios-dev NONE "$IOS_BODY"
out="$(bash "$mut_forbid" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '隱含含有禁止工具' <<<"$out"; then
  ok '⑮ mutant：清空 FORBIDDEN_RULES 後「無 tools: 行」的負樣本也變綠（同一條規則造成兩種樣本的紅）'
else
  echo "✗ ⑮ mutant 應 exit 0 且不印「隱含含有禁止工具」（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑯ LS-209：ios-dev 正文須含 mutation 三段式句；merge-reviewer 正文須含「handoff 申報的 mutation 一律
#        自己重放，對不上列 major」----
reset; expect 0 '⑯ ios-dev 正文含 mutation 三段式句 → 印「正文含」' 'ios-dev.md：正文含「改了什麼一行 → 哪條測試紅 → 斷言訊息原文」'
reset; expect 0 '⑯ merge-reviewer 正文含「一律自己重放」句 → 印「正文含」' 'merge-reviewer.md：正文含「handoff 申報的 mutation 一律自己重放，對不上列 major」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK}"; expect 1 '⑯ ios-dev 缺 mutation 三段式句 → exit 1，其餘句子齊全不救' 'ios-dev.md：正文缺「改了什麼一行 → 哪條測試紅 → 斷言訊息原文」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI}"; expect 1 '⑯ merge-reviewer 缺重放句 → exit 1' 'merge-reviewer.md：正文缺「handoff 申報的 mutation 一律自己重放，對不上列 major」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '斷言訊息原文' <<<"$out"; then
  ok '⑯ mutant：拿掉規則後「缺 mutation 三段式句」的負樣本變綠'
else
  echo "✗ ⑯ mutant（mutation 三段式）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '一律自己重放' <<<"$out"; then
  ok '⑯ mutant：拿掉規則後「缺重放句」的負樣本變綠'
else
  echo "✗ ⑯ mutant（重放句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑰ LS-211：三份正文須含「「已驗證」逐項對應派工單／票文編號，並寫「怎麼驗」」；qa／merge-reviewer
#        另須含「貼 comment 前先跑 handoff-evidence-check.sh」的命令句（ios-dev 不要求，不貼裁決 comment）----
reset; expect 0 '⑰ 三份正文含逐項對應句 → 印「正文含」' 'ios-dev.md：正文含「「已驗證」逐項對應派工單／票文編號，並寫「怎麼驗」」' 'qa.md：正文含「「已驗證」逐項對應派工單／票文編號，並寫「怎麼驗」」'
reset; expect 0 '⑰ qa／merge-reviewer 正文含 handoff-evidence-check.sh 命令句 → 印「正文含」' 'qa.md：正文含「bash scripts/gates/handoff-evidence-check.sh <暫存檔>」' 'merge-reviewer.md：正文含「bash scripts/gates/handoff-evidence-check.sh <暫存檔>」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY}"; expect 1 '⑰ ios-dev 缺逐項對應句 → exit 1，其餘句子齊全不救' 'ios-dev.md：正文缺「「已驗證」逐項對應派工單／票文編號，並寫「怎麼驗」」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${LOCK_BODY} ${E2E} ${SIMCTLUI}"; expect 1 '⑰ qa 缺逐項對應句與 handoff-evidence-check.sh 句 → exit 1' 'qa.md：正文缺「「已驗證」逐項對應派工單／票文編號，並寫「怎麼驗」」' 'qa.md：正文缺「bash scripts/gates/handoff-evidence-check.sh <暫存檔>」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI} ${REPLAYRULE} ${EVIDENCE_ITEM}"; expect 1 '⑰ merge-reviewer 有逐項對應句但缺 handoff-evidence-check.sh 命令句 → exit 1' 'merge-reviewer.md：正文缺「bash scripts/gates/handoff-evidence-check.sh <暫存檔>」' '' 'merge-reviewer.md：正文缺「「已驗證」逐項對應派工單／票文編號，並寫「怎麼驗」」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '逐項對應派工單' <<<"$out"; then
  ok '⑰ mutant：拿掉規則後「缺逐項對應句」的負樣本變綠'
else
  echo "✗ ⑰ mutant（逐項對應句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI} ${REPLAYRULE} ${EVIDENCE_ITEM}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'handoff-evidence-check.sh' <<<"$out"; then
  ok '⑰ mutant：拿掉規則後「缺 handoff-evidence-check.sh 命令句」的負樣本變綠'
else
  echo "✗ ⑰ mutant（handoff-evidence-check.sh 命令句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑱ LS-211 R2（merge-review R1 F3）：qa／merge-reviewer 正文須含「紅則逐條說明是誤判或補證據」
#        ——措辭從「綠再貼」改為「跑過並附輸出；紅則逐條說明是誤判或補證據」，不讓 agent 為了討好工具
#        改寫正確敘述；ios-dev 不要求（不貼裁決 comment）----
reset; expect 0 '⑱ qa／merge-reviewer 正文含「紅則逐條說明是誤判或補證據」→ 印「正文含」' 'qa.md：正文含「紅則逐條說明是誤判或補證據」' 'merge-reviewer.md：正文含「紅則逐條說明是誤判或補證據」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${LOCK_BODY} ${E2E} ${SIMCTLUI} ${EVIDENCE_ITEM} ${EVIDENCE_RUN_CMD}"; expect 1 '⑱ qa 只有 handoff-evidence-check.sh 命令句、缺「紅則逐條說明」→ exit 1' 'qa.md：正文缺「紅則逐條說明是誤判或補證據」' '' 'qa.md：正文缺「bash scripts/gates/handoff-evidence-check.sh <暫存檔>」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI} ${REPLAYRULE} ${EVIDENCE_ITEM} ${EVIDENCE_RUN_CMD}"; expect 1 '⑱ merge-reviewer 只有 handoff-evidence-check.sh 命令句、缺「紅則逐條說明」→ exit 1' 'merge-reviewer.md：正文缺「紅則逐條說明是誤判或補證據」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${LOCK_BODY} ${E2E} ${SIMCTLUI} ${EVIDENCE_ITEM} ${EVIDENCE_RUN_CMD}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '紅則逐條說明' <<<"$out"; then
  ok '⑱ mutant：拿掉規則後「缺紅則逐條說明句」的負樣本變綠'
else
  echo "✗ ⑱ mutant（紅則逐條說明句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑲ LS-215：ios-dev／qa／merge-reviewer 正文須含新 PreToolUse gate 名稱
#        「background-bash-guard.sh」（「不使用背景 Bash」規約落地後仍三起 agent 停在等背景通知，升機械 gate）----
reset; expect 0 '⑲ 三份正文含 background-bash-guard.sh → 印「正文含」' 'ios-dev.md：正文含「background-bash-guard.sh」' 'qa.md：正文含「background-bash-guard.sh」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM}"; expect 1 '⑲ ios-dev 缺 background-bash-guard.sh → exit 1，其餘句子齊全不救' 'ios-dev.md：正文缺「background-bash-guard.sh」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${LOCK_BODY} ${E2E} ${SIMCTLUI} ${EVIDENCE_ITEM} ${EVIDENCE_RUN}"; expect 1 '⑲ qa 缺 background-bash-guard.sh → exit 1' 'qa.md：正文缺「background-bash-guard.sh」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI} ${REPLAYRULE} ${EVIDENCE_ITEM} ${EVIDENCE_RUN}"; expect 1 '⑲ merge-reviewer 缺 background-bash-guard.sh → exit 1' 'merge-reviewer.md：正文缺「background-bash-guard.sh」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'background-bash-guard.sh' <<<"$out"; then
  ok '⑲ mutant：拿掉規則後「缺 background-bash-guard.sh」的負樣本變綠'
else
  echo "✗ ⑲ mutant（background-bash-guard.sh）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑳ LS-232：ios-dev 正文須含「新增登入後全屏 gate 必同 PR 更新 QADriver」（qa-driver-gate-check 機械化，
#        來源 LS-190／LS-217 兩次全屏 gate 新增後 QADriver 沒同步更新的事故）----
reset; expect 0 '⑳ ios-dev 正文含新增全屏 gate 規約句 → 印「正文含」' 'ios-dev.md：正文含「新增登入後全屏 gate 必同 PR 更新 QADriver」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE}"; expect 1 '⑳ ios-dev 缺該句 → exit 1，其餘句子齊全不救' 'ios-dev.md：正文缺「新增登入後全屏 gate 必同 PR 更新 QADriver」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '新增登入後全屏 gate 必同 PR 更新 QADriver' <<<"$out"; then
  ok '⑳ mutant：拿掉規則後「缺新增全屏 gate 規約句」的負樣本變綠'
else
  echo "✗ ⑳ mutant（新增全屏 gate 規約句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ㉑ LS-236：三份正文須含「不得依賴截斷後的自動背景化」（工具 timeout 600000 截斷後子行程不會被
#        殺掉，殘留會與下一輪 xcodebuild 搶模擬器；來源 LS-166／LS-217，stale-xcodebuild-check.sh 機械擋殘留）----
reset; expect 0 '㉑ 三份正文含不得依賴截斷後自動背景化句 → 印「正文含」' 'ios-dev.md：正文含「不得依賴截斷後的自動背景化」' 'qa.md：正文含「不得依賴截斷後的自動背景化」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE} ${QAGATE}"; expect 1 '㉑ ios-dev 缺該句 → exit 1，其餘句子齊全不救' 'ios-dev.md：正文缺「不得依賴截斷後的自動背景化」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${LOCK_BODY} ${E2E} ${SIMCTLUI} ${EVIDENCE_ITEM} ${EVIDENCE_RUN} ${BGGATE}"; expect 1 '㉑ qa 缺該句 → exit 1' 'qa.md：正文缺「不得依賴截斷後的自動背景化」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI} ${REPLAYRULE} ${EVIDENCE_ITEM} ${EVIDENCE_RUN} ${BGGATE}"; expect 1 '㉑ merge-reviewer 缺該句 → exit 1' 'merge-reviewer.md：正文缺「不得依賴截斷後的自動背景化」'
reset
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '不得依賴截斷後的自動背景化' <<<"$out"; then
  ok '㉑ mutant：拿掉規則後「缺不得依賴截斷後自動背景化句」的負樣本變綠'
else
  echo "✗ ㉑ mutant（不得依賴截斷後自動背景化句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ㉒ LS-254：五份正文須含「禁派 fork」（fork 繼承整份派工單並平行執行整項任務——LS-234 R7 同一 .pen／branch 雙寫、
#        LS-188／LS-192 越權改檔；PreToolUse fork-guard.sh 機械擋非主 session 的 subagent_type: fork，這句是規約層前饋）----
reset; expect 0 '㉒ 五份正文含禁派 fork 句 → 印「正文含」（ui-designer／visual-reviewer）' 'ui-designer.md：正文含「禁派 fork」' 'visual-reviewer.md：正文含「禁派 fork」'
reset; expect 0 '㉒ 五份正文含禁派 fork 句 → 印「正文含」（ios-dev／qa）' 'ios-dev.md：正文含「禁派 fork」' 'qa.md：正文含「禁派 fork」'
reset; expect 0 '㉒ 五份正文含禁派 fork 句 → 印「正文含」（merge-reviewer）' 'merge-reviewer.md：正文含「禁派 fork」'
reset; mk ui-designer NONE "${KILL} ${STAY}"; expect 1 '㉒ ui-designer 缺該句 → exit 1，LS-180 兩句齊全不救' 'ui-designer.md：正文缺「禁派 fork」' '' 'ui-designer.md：正文缺「收工 Pen 停在票檔」'
reset; mk visual-reviewer NONE "$KILL"; expect 1 '㉒ visual-reviewer 缺該句 → exit 1' 'visual-reviewer.md：正文缺「禁派 fork」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE} ${QAGATE} ${NOBGXC}"; expect 1 '㉒ ios-dev 缺該句 → exit 1（LS-209 舊句「不得派 fork／subagent 改動任何檔案」在也不救——字樣不同）' 'ios-dev.md：正文缺「禁派 fork」' '' 'ios-dev.md：正文缺「不得派 fork／subagent 改動任何檔案」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${LOCK_BODY} ${E2E} ${SIMCTLUI} ${EVIDENCE_ITEM} ${EVIDENCE_RUN} ${BGGATE} ${NOBGXC}"; expect 1 '㉒ qa 缺該句 → exit 1' 'qa.md：正文缺「禁派 fork」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI} ${REPLAYRULE} ${EVIDENCE_ITEM} ${EVIDENCE_RUN} ${BGGATE} ${NOBGXC}"; expect 1 '㉒ merge-reviewer 缺該句 → exit 1' 'merge-reviewer.md：正文缺「禁派 fork」'
reset; mk visual-reviewer NONE "${KILL} 禁派fork（無空白）"; expect 1 '㉒ 字樣須整句「禁派 fork」（含空白），「禁派fork」不算 → exit 1' 'visual-reviewer.md：正文缺「禁派 fork」'
reset; mk visual-reviewer NONE "$KILL"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '禁派 fork' <<<"$out"; then
  ok '㉒ mutant：拿掉規則後「缺禁派 fork 句」的負樣本變綠'
else
  echo "✗ ㉒ mutant（禁派 fork 句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ㉓ LS-256（LS-96 池項 a7e9e910 i1／e4155ed8(1)）：dead-code-sweeper 是六份定義中原唯一未釘「禁派 fork」的（LS-254 票文只列五份）
#        ——補釘同一條規則；tools 白名單無 Agent，與 merge-reviewer／qa 同型（需要並行回報 orchestrator 拆派）。----
reset; expect 0 '㉓ dead-code-sweeper 正文含禁派 fork 句 → 印「正文含」（總數 67 條）' 'dead-code-sweeper.md：正文含「禁派 fork」' '正文必含字樣 67 條）'
reset; mk dead-code-sweeper "Bash, Read, Grep, Glob, ${LINEAR3}"; expect 1 '㉓ dead-code-sweeper 缺該句 → exit 1，工具齊全不救（regression：LS-254 前這份無正文規則、任何正文都過）' 'dead-code-sweeper.md：正文缺「禁派 fork」' '' 'dead-code-sweeper.md：tools: 缺'
reset; mk dead-code-sweeper "Bash, Read, Grep, Glob, ${LINEAR3}" "禁派fork（無空白）"; expect 1 '㉓ 字樣須整句「禁派 fork」（含空白）→ exit 1' 'dead-code-sweeper.md：正文缺「禁派 fork」'
reset; mk dead-code-sweeper "Bash, Read, Grep, Glob, ${LINEAR3}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '禁派 fork' <<<"$out"; then
  ok '㉓ mutant：拿掉規則後「sweeper 缺禁派 fork 句」的負樣本變綠'
else
  echo "✗ ㉓ mutant（sweeper 禁派 fork 句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ㉔ LS-264（LS-96 池項 `c1b67f93`）：ui-designer／visual-reviewer 正文須含「editId 成功套用後即失效」
#      （Pencil `execute` 的 `edits`／`editId` 成功後即失效，分批掃描每批都要重送 snippet 全文；LS-247 VR R3 實測）
reset; mk ui-designer NONE "${KILL} ${STAY} ${NOFORK254}"; expect 1 '㉔ ui-designer 缺 editId 句 → exit 1（其他必含字樣齊全不救）' 'ui-designer.md：正文缺「editId 成功套用後即失效」'
reset; mk visual-reviewer NONE "${KILL} ${NOFORK254}"; expect 1 '㉔ visual-reviewer 缺 editId 句 → exit 1' 'visual-reviewer.md：正文缺「editId 成功套用後即失效」'
reset; mk ui-designer NONE "${KILL} ${STAY} ${NOFORK254}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'editId 成功套用後即失效' <<<"$out"; then
  ok '㉔ mutant：拿掉 BODY_RULES 區塊後「ui-designer 缺 editId 句」的負樣本變綠'
else
  echo "✗ ㉔ mutant（ui-designer editId 句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
reset

# ---- ㉕ LS-270（LS-96 池項 `d4c1add5`(c)）：merge-reviewer 正文須含「shell 自測在 ubuntu:24.04 通道跑 ≥10 次」
#      （BSD-GNU 差異有一整類是機率性的——LS-267 R2 B1 的 pipefail ＋ grep -q 管線在 ubuntu 20 次紅 14 次、
#      macOS 永遠綠，跑 1 次很可能剛好抽到綠）。「≥10 次」是規則的重點，只寫「跑一次」不算。----
MR_BASE="${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI} ${REPLAYRULE} ${EVIDENCE_ITEM} ${EVIDENCE_RUN} ${BGGATE} ${NOBGXC} ${NOFORK254}"
MR_NO_UBUNTU="${MR_BASE} ${UITESTMUT} ${NOTIMEOUT}"
reset; expect 0 '㉕ merge-reviewer 正文含 ubuntu ≥10 次句 → 印「正文含」（總數 67 條）' 'merge-reviewer.md：正文含「shell 自測在 ubuntu:24.04 通道跑 ≥10 次」' '正文必含字樣 67 條）'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "$MR_NO_UBUNTU"; expect 1 '㉕ merge-reviewer 缺該句 → exit 1（其餘必含字樣齊全不救）' 'merge-reviewer.md：正文缺「shell 自測在 ubuntu:24.04 通道跑 ≥10 次」' '' 'merge-reviewer.md：正文缺「禁派 fork」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${MR_NO_UBUNTU} ${UBUNTU1}"; expect 1 '㉕ 只寫「跑一次確認」不算（次數是規則的重點）→ exit 1' 'merge-reviewer.md：正文缺「shell 自測在 ubuntu:24.04 通道跑 ≥10 次」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "$MR_NO_UBUNTU"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'shell 自測在 ubuntu:24.04 通道跑 ≥10 次' <<<"$out"; then
  ok '㉕ mutant：拿掉 BODY_RULES 區塊後「merge-reviewer 缺 ubuntu ≥10 次句」的負樣本變綠'
else
  echo "✗ ㉕ mutant（merge-reviewer ubuntu ≥10 次句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
reset

# ---- ㉖ LS-270（LS-96 池項 `3e9347c4`(5)／`8a946ea2`(3)）：merge-reviewer 的 mutation 段須含兩句——
#      「UITest mutation 重放要看失敗點／時間軸是否隨 mutation 改變」（xcodebuild 可能沒把改動編進 UITest
#      bundle，只看 exit code 會把舊 bundle 的紅或假綠當成重放結果）與「macOS 沒有 timeout 指令」
#      （`timeout 600 xcodebuild …` exit 127＝整個測試沒跑過，LS-266 R2 實際發生）。兩句各自獨立缺席都要紅。----
reset; expect 0 '㉖ merge-reviewer 正文含兩句 → 印「正文含」（總數 67 條）' 'merge-reviewer.md：正文含「UITest mutation 重放要看失敗點／時間軸是否隨 mutation 改變」' '正文必含字樣 67 條）'
reset; expect 0 '㉖ merge-reviewer 正文含 macOS 無 timeout 句 → 印「正文含」' 'merge-reviewer.md：正文含「macOS 沒有 timeout 指令」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${MR_BASE} ${UBUNTU10} ${NOTIMEOUT}"; expect 1 '㉖ 缺 UITest mutation 判準句 → exit 1（LS-209 舊的「一律自己重放」句在也不救）' 'merge-reviewer.md：正文缺「UITest mutation 重放要看失敗點／時間軸是否隨 mutation 改變」' '' 'merge-reviewer.md：正文缺「handoff 申報的 mutation 一律自己重放，對不上列 major」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${MR_BASE} ${UBUNTU10} ${UITESTMUT}"; expect 1 '㉖ 缺 macOS 無 timeout 句 → exit 1（另一句在也不救）' 'merge-reviewer.md：正文缺「macOS 沒有 timeout 指令」' '' 'merge-reviewer.md：正文缺「UITest mutation 重放要看失敗點／時間軸是否隨 mutation 改變」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${MR_BASE} ${UBUNTU10}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'macOS 沒有 timeout 指令' <<<"$out"; then
  ok '㉖ mutant：拿掉 BODY_RULES 區塊後「merge-reviewer 缺兩句」的負樣本變綠'
else
  echo "✗ ㉖ mutant（merge-reviewer mutation 段兩句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
reset

# ---- ㉗ LS-299（源自 LS-96 池項 26bbff68）：三份正文須含 `scripts/ops/ci-wait.sh`（等 CI 一律前景分段
#        輪詢，取代 `gh run watch`，09-15 三次事故：LS-286／287／295）----
reset; expect 0 '㉗ 三份正文含 scripts/ops/ci-wait.sh → 印「正文含」（總數 67 條）' 'ios-dev.md：正文含「scripts/ops/ci-wait.sh」' '正文必含字樣 67 條）'
reset; expect 0 '㉗ qa／merge-reviewer 正文含 scripts/ops/ci-wait.sh → 印「正文含」' 'qa.md：正文含「scripts/ops/ci-wait.sh」' 'merge-reviewer.md：正文含「scripts/ops/ci-wait.sh」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE} ${QAGATE} ${NOBGXC} ${NOFORK254}"; expect 1 '㉗ ios-dev 缺該句 → exit 1，其餘句子齊全不救' 'ios-dev.md：正文缺「scripts/ops/ci-wait.sh」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${LOCK_BODY} ${E2E} ${SIMCTLUI} ${EVIDENCE_ITEM} ${EVIDENCE_RUN} ${BGGATE} ${NOBGXC} ${NOFORK254}"; expect 1 '㉗ qa 缺該句 → exit 1' 'qa.md：正文缺「scripts/ops/ci-wait.sh」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI} ${REPLAYRULE} ${EVIDENCE_ITEM} ${EVIDENCE_RUN} ${BGGATE} ${NOBGXC} ${NOFORK254} ${UBUNTU10} ${UITESTMUT} ${NOTIMEOUT}"; expect 1 '㉗ merge-reviewer 缺該句 → exit 1' 'merge-reviewer.md：正文缺「scripts/ops/ci-wait.sh」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE} ${QAGATE} ${NOBGXC} ${NOFORK254} 只提 gh run watch 而沒有 ci-wait.sh 不算"; expect 1 '㉗ 只提 gh run watch 字面、無 ci-wait.sh → 紅' 'ios-dev.md：正文缺「scripts/ops/ci-wait.sh」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE} ${QAGATE} ${NOBGXC} ${NOFORK254}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'scripts/ops/ci-wait.sh' <<<"$out"; then
  ok '㉗ mutant：拿掉規則後「缺 scripts/ops/ci-wait.sh」的負樣本變綠'
else
  echo "✗ ㉗ mutant（scripts/ops/ci-wait.sh）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ㉘ LS-300（LS-96 池項 3aa46c78）：ios-dev 正文須含「實作新畫面必逐條對 Notes「畫面級屬性」並在
#        handoff 勾選」、merge-reviewer 正文須含「對 handoff 勾選表抽兩列重放」（LS-125／126 QA 視覺 FAIL
#        四項全是「稿有、實作漏」，設計稿 Notes 板有寫、ios-dev 沒逐條對、merge-reviewer 沒查）----
reset; expect 0 '㉘ ios-dev 正文含「實作新畫面必逐條對 Notes「畫面級屬性」並在 handoff 勾選」→ 印「正文含」（總數 67 條）' 'ios-dev.md：正文含「實作新畫面必逐條對 Notes「畫面級屬性」並在 handoff 勾選」' '正文必含字樣 67 條）'
reset; expect 0 '㉘ merge-reviewer 正文含「對 handoff 勾選表抽兩列重放」→ 印「正文含」' 'merge-reviewer.md：正文含「對 handoff 勾選表抽兩列重放」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE} ${QAGATE} ${NOBGXC} ${NOFORK254} ${CIWAIT}"; expect 1 '㉘ ios-dev 缺該句 → exit 1，其餘句子齊全不救' 'ios-dev.md：正文缺「實作新畫面必逐條對 Notes「畫面級屬性」並在 handoff 勾選」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI} ${REPLAYRULE} ${EVIDENCE_ITEM} ${EVIDENCE_RUN} ${BGGATE} ${NOBGXC} ${NOFORK254} ${UBUNTU10} ${UITESTMUT} ${NOTIMEOUT} ${CIWAIT}"; expect 1 '㉘ merge-reviewer 缺該句 → exit 1，其餘句子齊全不救' 'merge-reviewer.md：正文缺「對 handoff 勾選表抽兩列重放」' '' 'merge-reviewer.md：正文缺「scripts/ops/ci-wait.sh」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE} ${QAGATE} ${NOBGXC} ${NOFORK254} ${CIWAIT}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '實作新畫面必逐條對 Notes「畫面級屬性」並在 handoff 勾選' <<<"$out"; then
  ok '㉘ mutant（ios-dev）：拿掉規則後「缺畫面級屬性句」的負樣本變綠'
else
  echo "✗ ㉘ mutant（ios-dev 畫面級屬性句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI} ${REPLAYRULE} ${EVIDENCE_ITEM} ${EVIDENCE_RUN} ${BGGATE} ${NOBGXC} ${NOFORK254} ${UBUNTU10} ${UITESTMUT} ${NOTIMEOUT} ${CIWAIT}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '對 handoff 勾選表抽兩列重放' <<<"$out"; then
  ok '㉘ mutant（merge-reviewer）：拿掉規則後「缺抽兩列重放句」的負樣本變綠'
else
  echo "✗ ㉘ mutant（merge-reviewer 抽兩列重放句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ㉙ LS-306 A2：ios-dev 正文須含 push-gate.sh 開始前的進度句（含「逾時被背景化就前景重跑 push，
#      快取秒過」——push-gate.sh 步驟 2 的實際 echo 同句）----
reset; expect 0 '㉙ ios-dev 正文含 push-gate 進度句 → 印「正文含」（總數 67 條）' 'ios-dev.md：正文含「逾時被背景化就前景重跑 push，快取秒過」' '正文必含字樣 67 條）'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE} ${QAGATE} ${NOBGXC} ${NOFORK254} ${CIWAIT} ${SCREENATTR}"; expect 1 '㉙ ios-dev 缺該句 → exit 1，其餘句子齊全不救' 'ios-dev.md：正文缺「逾時被背景化就前景重跑 push，快取秒過」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE} ${QAGATE} ${NOBGXC} ${NOFORK254} ${CIWAIT} ${SCREENATTR}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '逾時被背景化就前景重跑 push，快取秒過' <<<"$out"; then
  ok '㉙ mutant：拿掉規則後「ios-dev 缺 push-gate 進度句」的負樣本變綠'
else
  echo "✗ ㉙ mutant（ios-dev push-gate 進度句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
reset

# ---- ㉚ LS-306 B1：ui-designer／visual-reviewer 正文須含 `scripts/ops/ci-wait.sh`（同 ios-dev／qa／
#      merge-reviewer 既有 CIWAIT 句）----
reset; expect 0 '㉚ ui-designer／visual-reviewer 正文含 scripts/ops/ci-wait.sh → 印「正文含」' 'ui-designer.md：正文含「scripts/ops/ci-wait.sh」' 'visual-reviewer.md：正文含「scripts/ops/ci-wait.sh」'
reset; mk ui-designer NONE "${KILL} ${STAY} ${NOFORK254} ${EDITID}"; expect 1 '㉚ ui-designer 缺該句 → exit 1，其餘句子齊全不救' 'ui-designer.md：正文缺「scripts/ops/ci-wait.sh」' '' 'ui-designer.md：正文缺「editId 成功套用後即失效」'
reset; mk visual-reviewer NONE "${KILL} ${NOFORK254} ${EDITID}"; expect 1 '㉚ visual-reviewer 缺該句 → exit 1' 'visual-reviewer.md：正文缺「scripts/ops/ci-wait.sh」'
reset; mk ui-designer NONE "${KILL} ${STAY} ${NOFORK254} ${EDITID}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'scripts/ops/ci-wait.sh' <<<"$out"; then
  ok '㉚ mutant（ui-designer）：拿掉規則後「缺 ci-wait.sh 句」的負樣本變綠'
else
  echo "✗ ㉚ mutant（ui-designer ci-wait.sh 句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
reset; mk visual-reviewer NONE "${KILL} ${NOFORK254} ${EDITID}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF 'scripts/ops/ci-wait.sh' <<<"$out"; then
  ok '㉚ mutant（visual-reviewer）：拿掉規則後「缺 ci-wait.sh 句」的負樣本變綠'
else
  echo "✗ ㉚ mutant（visual-reviewer ci-wait.sh 句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
reset

# ---- ㉛ LS-308 B2：六份 agent 定義正文皆須含 mcp__linear__* 備援句（Linear MCP token 過期時改用
#      bash scripts/ops/linear-post.sh get|comment|state，並在 handoff 註明走備援）——各自缺即紅、其餘句子
#      齊全不救；同一 mutant 下負樣本變綠；正文必含字樣總數 61→67 ----
reset; expect 0 '㉛ 六份正文含 mcp__linear__* 備援句 → 印「正文含」（總數 67 條）' 'ios-dev.md：正文含「並在 handoff 註明走備援」' '正文必含字樣 67 條）'
reset; expect 0 '㉛ 其餘五份也印「正文含」' 'qa.md：正文含「並在 handoff 註明走備援」' 'dead-code-sweeper.md：正文含「並在 handoff 註明走備援」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE} ${QAGATE} ${NOBGXC} ${NOFORK254} ${CIWAIT} ${SCREENATTR} ${PUSHCACHE}"; expect 1 '㉛ ios-dev 缺該句 → exit 1，其餘句子齊全不救' 'ios-dev.md：正文缺「並在 handoff 註明走備援」' '' 'ios-dev.md：正文缺「supabase-lock.sh --hold」'
reset; mk merge-reviewer "Bash, Read, Grep, Glob, ${LINEAR3}" "${LOCK_BODY} ${DBCHAN} ${SHEETUI} ${SIMCTLUI} ${REPLAYRULE} ${EVIDENCE_ITEM} ${EVIDENCE_RUN} ${BGGATE} ${NOBGXC} ${NOFORK254} ${UBUNTU10} ${UITESTMUT} ${NOTIMEOUT} ${CIWAIT} ${REPLAYSCREENATTR}"; expect 1 '㉛ merge-reviewer 缺該句 → exit 1' 'merge-reviewer.md：正文缺「並在 handoff 註明走備援」'
reset; mk qa "Bash, Read, Grep, Glob, ${LINEAR3}, mcp__pencil__get_app_state, mcp__pencil__execute, mcp__pencil__read_skill" "${LOCK_BODY} ${E2E} ${SIMCTLUI} ${EVIDENCE_ITEM} ${EVIDENCE_RUN} ${BGGATE} ${NOBGXC} ${NOFORK254} ${CIWAIT}"; expect 1 '㉛ qa 缺該句 → exit 1' 'qa.md：正文缺「並在 handoff 註明走備援」'
reset; mk dead-code-sweeper "Bash, Read, Grep, Glob, ${LINEAR3}" "$NOFORK254"; expect 1 '㉛ dead-code-sweeper 只有禁派 fork 句、缺備援句 → exit 1' 'dead-code-sweeper.md：正文缺「並在 handoff 註明走備援」' '' 'dead-code-sweeper.md：正文缺「禁派 fork」'
reset; mk ui-designer NONE "${KILL} ${STAY} ${NOFORK254} ${EDITID} ${CIWAIT}"; expect 1 '㉛ ui-designer 缺該句 → exit 1，其餘句子齊全不救' 'ui-designer.md：正文缺「並在 handoff 註明走備援」' '' 'ui-designer.md：正文缺「scripts/ops/ci-wait.sh」'
reset; mk visual-reviewer NONE "${KILL} ${NOFORK254} ${EDITID} ${CIWAIT}"; expect 1 '㉛ visual-reviewer 缺該句 → exit 1' 'visual-reviewer.md：正文缺「並在 handoff 註明走備援」'
reset; mk ios-dev "$IOS_TOOLS" "${IOS_BODY} 只提 mcp__linear__* 字面、沒有 linear-post.sh 備援句不算"
out="$(bash "$checker" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ]; then ok '㉛ 已含完整句子時多餘贅字不影響通過'; else echo "✗ ㉛ 應仍 exit 0（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE} ${QAGATE} ${NOBGXC} ${NOFORK254} ${CIWAIT} ${SCREENATTR} ${PUSHCACHE} 只提 mcp__linear__* 字面、沒有那句規約不算"; expect 1 '㉛ 只有 mcp__linear__* 字面、無「並在 handoff 註明走備援」→ 紅' 'ios-dev.md：正文缺「並在 handoff 註明走備援」'
reset; mk ios-dev "$IOS_TOOLS" "${LOCK_BODY} ${PRBODY} ${DBCHAN} ${SHEETUI} ${NOFORK} ${MUTPLAY} ${EVIDENCE_ITEM} ${BGGATE} ${QAGATE} ${NOBGXC} ${NOFORK254} ${CIWAIT} ${SCREENATTR} ${PUSHCACHE}"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '並在 handoff 註明走備援' <<<"$out"; then
  ok '㉛ mutant：拿掉規則後「ios-dev 缺備援句」的負樣本變綠'
else
  echo "✗ ㉛ mutant（ios-dev 備援句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
reset; mk dead-code-sweeper "Bash, Read, Grep, Glob, ${LINEAR3}" "$NOFORK254"
out="$(bash "$mut" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && ! grep -qF '並在 handoff 註明走備援' <<<"$out"; then
  ok '㉛ mutant：拿掉規則後「dead-code-sweeper 缺備援句」的負樣本變綠'
else
  echo "✗ ㉛ mutant（dead-code-sweeper 備援句）應 exit 0 且不印該字樣（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
reset


# R1 I-3：正文規則表多一個不在工具表的 agent（mutant 在 BODY_RULES 首行後插 `nobody|x`）→ exit 2 fail closed，不得靜默跳過
mut3="$work/agent-tools-check.body-not-subset.sh"
awk '{ print } /^BODY_RULES="ios-dev\|/ { print "nobody|x" }' "$checker" > "$mut3"
if grep -q '^nobody|x$' "$mut3"; then ok '⑤ I-3 mutant 已插入不在工具表的 agent'; else echo "✗ ⑤ I-3 mutant 插入失敗（負控本身無效）" >&2; fail=1; fi
reset
out="$(bash "$mut3" "$agents" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && grep -qF 'nobody 不在工具規則表' <<<"$out"; then ok '⑤ I-3：正文規則表 ⊄ 工具表 → exit 2 並點名'; else echo "✗ ⑤ I-3 應 exit 2 並點名 nobody（實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

# ---- ④ 參數 ----
out="$(bash "$checker" "$work/nope" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && grep -qF '找不到目錄' <<<"$out"; then ok '④ 目錄不存在 → exit 2'; else echo "✗ ④ 目錄不存在應 exit 2（實得 ${got}）" >&2; fail=1; fi
out="$(bash "$checker" "$agents" extra 2>&1)"; got=$?
if [ "$got" -eq 2 ] && grep -qF '只接受一個' <<<"$out"; then ok '④ 多參數 → exit 2'; else echo "✗ ④ 多參數應 exit 2（實得 ${got}）" >&2; fail=1; fi

if [ "$fail" -ne 0 ]; then
  echo "✗ agent-tools-check 自測失敗" >&2
  exit 1
fi
echo "✓ agent-tools-check 自測通過（${n} 組樣本）"
