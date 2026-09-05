#!/bin/bash
# pr-body-check.sh 的自測（LS-63；LS-140 加申報可驗證段）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成全文子字串比對（第二段有票號就放行、LS-630 滿足 LS-63）、
# 模板形狀「## Ticket／空行／LS-<n>」被誤擋、缺檔／非工作分支時靜默放行、或失敗輸出丟掉「CI 不會自動重跑」止血指示，這裡會紅。
# LS-140：LS-96／入池／待辦池 行缺 comment id、「已修」行缺 SHA 若放行（拿掉規則 (a)／(b) 即紅）、--verify 反查退化
#   （id 不在 LS-96／SHA 不在 PR 內卻綠、分頁只讀第一頁、token 進 curl argv、curl／GraphQL 失敗靜默放行）這裡也會紅。
# LS-186（⑦）：「已修」SHA 候選只認同一行「已修」之後的第一個 hex——退回「行內任一 hex」時 LS-185 回歸案（標題行 comment id 在「皆已修」
#   之前）會被當成有 SHA 而綠、--verify 又把 comment id 報成「不在 PR commits 內」；改成「之後全部 hex 任一」時「第一個是 comment id、
#   真 SHA 在其後」會綠——這裡都會紅；紅時 stdout 最後一行不是 ✗ 也會紅。R2（merge-review R1 minor-1）自「緊鄰」放寬：冒號／
#   `（commit `sha`）`／逗號句／表格別欄四種 repo 常見形狀為正樣本。
# LS-198（⑧）：格式模式對「已修」後第一個 hex 為純數字（migration 檔名前綴／CI run id）印 ⚠ 警告、exit 仍 0——拿掉警告即紅；非純數字不得印警告；
#   --verify 紅「不是本 repo 的 commit」時 deny 訊息須含「檔名／行號裡的數字也算 hex token」——刪掉那半句即紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/pr-body-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# expect <期望 exit code> <樣本名稱> <輸出必含字串|''> <body 內容> [<checker 參數…>]
# body 內容寫進 $work/body 後，以檔案路徑當最後一個參數傳給 checker。
expect() {
  local want=$1 name=$2 must=$3 body=$4 out got
  shift 4
  printf '%s' "$body" > "$work/body"
  out="$(bash "$check" "$@" "$work/body" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

B=hotfix/LS-63-scratchpad

# ① 應放行：三種實際 PR body 形狀
expect 0 '① Ticket: 行在第一行（PR #90 形狀）' 'LS-63' $'Ticket: LS-63 — Harness：暫存檔名帶票號\n\n## 變更\n- 東西\n' --branch "$B"
expect 0 '① 模板形狀：## Ticket／空行／LS-<n>（標題行不算內容段落）' 'LS-63' $'## Ticket\n\nLS-63\n\n## 變更摘要\n\n說明\n' --branch "$B"
expect 0 '① ## Ticket 下一行接票號（PR #78 形狀）' 'LS-63' $'## Ticket\nLS-63 — 說明。hotfix-from-main。\n\n## 變更\n' --branch "$B"
expect 0 '① 開頭空行＋CRLF（web UI 貼上）' 'LS-63' $'\r\n\r\n  Ticket: LS-63  \r\n\r\n## 變更\r\n' --branch "$B"
expect 0 '① 票號在 Linear URL 內' 'LS-63' $'Ticket: https://linear.app/x/issue/LS-63/harness-slug\n\n說明\n' --branch "$B"
expect 0 '① 檔頭段同時提到他票（承 LS-50）' 'LS-63' $'Ticket: LS-63（承 LS-50 的 --pr-body，補票號半邊）\n\n說明\n' --branch "$B"
expect 0 '① 末行無結尾換行（printf %s 的實際形狀）' 'LS-63' 'Ticket: LS-63' --branch "$B"

# ② 不得放行：事故原形與退化方向
expect 1 '② 事故原形：檔頭段是他票的 body → 紅並點名 LS-56' 'LS-56' $'## Ticket\nLS-56 — error-codes-check 抽取規則硬化\n\n## 變更\n提到 LS-63 也沒用\n' --branch "$B"
expect 1 '② 票號只在第二個內容段落（全文子字串比對會放行）' '沒有本票票號 LS-63' $'## 變更摘要\n做了很多事\n\nTicket: LS-63\n' --branch "$B"
expect 1 '② 相似票號 LS-630 不算（整字比對）' 'LS-630' $'Ticket: LS-630\n' --branch "$B"
expect 1 '② 小寫 ls-63 不算' '沒有本票票號' $'Ticket: ls-63\n' --branch "$B"
expect 1 '② 模板未填（LS- 沒有數字）' 'LS-」還沒填' $'## Ticket\n\nLS-\n\n## 變更摘要\n' --branch "$B"
expect 1 '② 紅時附止血指示：修 body 後 CI 不會自動重跑（PR #93 review F1）' 'close/reopen' $'Ticket: LS-\n' --branch "$B"
expect 1 '② 空 body' '空的' '' --branch "$B"
expect 1 '② 只有空白與空行' '空的' $'\n  \r\n\n' --branch "$B"

# ③ 參數／分支錯誤：fail closed（exit 2）
expect 2 '③ --branch 是保護分支（promote PR 不該呼叫）' '沒有本票票號可比' $'Ticket: LS-63\n' --branch development
expect 2 '③ 未知參數' '未知參數' $'Ticket: LS-63\n' --branch "$B" --pr-body
if out="$(bash "$check" --branch "$B" 2>&1)"; then
  echo "✗ ③ 缺 body 檔 → 應 exit 2（實得 0）" >&2; fail=1
elif [ $? -eq 2 ] && printf '%s' "$out" | grep -qF '缺 PR body 檔'; then
  echo "✓ ③ 缺 body 檔 → exit 2"
else
  echo "✗ ③ 缺 body 檔（期望 exit 2、輸出含「缺 PR body 檔」）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi
if out="$(bash "$check" --branch "$B" "$work/nope.md" 2>&1)"; then
  echo "✗ ③ 讀不到 body 檔 → 應 exit 2（實得 0）" >&2; fail=1
elif [ $? -eq 2 ] && printf '%s' "$out" | grep -qF '讀不到'; then
  echo "✓ ③ 讀不到 body 檔 → exit 2"
else
  echo "✗ ③ 讀不到 body 檔（期望 exit 2、輸出含「讀不到」）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ④ 未傳 --branch：票號取自當前分支（agent 本機用法）。臨時 repo 與本機 git 設定隔離，結果不因人而異。
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
R="$work/repo"; mkdir -p "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q -b feature/LS-7-inferred
g commit -q --allow-empty -m 'chore: LS-7 init'
printf 'Ticket: LS-7\n' > "$work/body7"
printf 'Ticket: LS-63\n' > "$work/body63"
run_in_repo() { (cd "$R" && bash "$check" "$@" 2>&1); }
out="$(run_in_repo "$work/body7")"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF 'LS-7'; then echo "✓ ④ 未傳 --branch：從當前分支 feature/LS-7 推得票號 → 綠"; else echo "✗ ④ 未傳 --branch 推票號（期望 exit 0，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
out="$(run_in_repo "$work/body63")"; got=$?
if [ "$got" -eq 1 ] && printf '%s' "$out" | grep -qF 'LS-63'; then echo "✓ ④ 未傳 --branch：body 是 LS-63 但分支是 LS-7 → 紅"; else echo "✗ ④ 未傳 --branch 他票 body（期望 exit 1，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
g checkout -q --detach
out="$(run_in_repo "$work/body7")"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF 'DETACHED'; then echo "✓ ④ detached HEAD 且未傳 --branch → exit 2"; else echo "✗ ④ detached HEAD（期望 exit 2，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

# ⑤ LS-140 申報可驗證（格式，全 body 逐行；不帶 --verify）：含 LS-96／入池／待辦池 的行要 ≥8 位 hex comment id，
#   含「已修」的行要 7–40 位 hex SHA。H 佔 3 行，申報從第 4 行起。
H=$'Ticket: LS-63\n\n## 未完成\n'
sha40="7c2ff80$(printf '%033d' 0 | tr 0 a)"   # 7＋33＝40 位（用產生的、不用手數的字面）
expect 0 '⑤a 記入 LS-96 帶 8 位 hex id → 綠' '皆帶 comment id' "${H}- i1：記入 LS-96 \`9f348e36\`"$'\n' --branch "$B"
expect 0 '⑤a 完整 UUID（含連字號）也算' '皆帶 comment id' "${H}- i1：記入待辦池 LS-96（comment \`9f348e36-82b6-4926-931b-5bfe1637e1f1\`）"$'\n' --branch "$B"
expect 1 '⑤a 記入 LS-96 缺 id → 紅並指示先 save_comment 取 id' 'save_comment' "${H}- i1：記入 LS-96 待辦池"$'\n' --branch "$B"
expect 1 '⑤a 同義詞「入池」缺 id → 紅' '必附 comment id' "${H}- i2：入池，不擴大本票範圍"$'\n' --branch "$B"
expect 1 '⑤a 同義詞「待辦池」缺 id → 紅' '必附 comment id' "${H}- i3：記入待辦池"$'\n' --branch "$B"
expect 1 '⑤a 只有 7 位 hex 不夠（LS-96 行要 ≥8）' '第 4 行' "${H}- i1：記入 LS-96 \`9f348e3\`"$'\n' --branch "$B"
expect 1 '⑤a hex 嵌在更長英數串裡不算獨立 token' '沒有 comment id' "${H}- i1：記入 LS-96 x9f348e36y"$'\n' --branch "$B"
expect 1 '⑤a 大寫 hex 不算（Linear id／git SHA 皆小寫）' '沒有 comment id' "${H}- i1：記入 LS-96 9F348E36"$'\n' --branch "$B"
expect 0 '⑤a LS-960 不是 LS-96（整字比對），無 id 也綠' 'LS-96 行 0 條' "${H}- 承 LS-960 的做法"$'\n' --branch "$B"
expect 1 '⑤a 紅時點名行號並回顯該行' '    | - i1：記入 LS-96 待辦池' "${H}- i1：記入 LS-96 待辦池"$'\n' --branch "$B"
expect 1 '⑤a 負向提及也會中（全 body 掃取捨）→ 提示改寫措辭＋止血指示' '改寫措辭' "${H}- 不另立 LS-96 池項"$'\n' --branch "$B"
expect 1 '⑤a 紅時附「CI 不會自動重跑」止血指示' 'close/reopen' "${H}- 不另立 LS-96 池項"$'\n' --branch "$B"
expect 0 '⑤b 已修帶 7 位 SHA → 綠' '皆帶 SHA' "${H}- m1：已修 \`7c2ff80\` \`Foo.swift:12\`"$'\n' --branch "$B"
expect 0 '⑤b 已修帶 40 位 SHA → 綠' '皆帶 SHA' "${H}- m1：已修 ${sha40}"$'\n' --branch "$B"
expect 1 '⑤b 已修缺 SHA → 紅並指示附 SHA' '必附 commit SHA' "${H}- m1：已修——改用 label closure"$'\n' --branch "$B"
expect 1 '⑤b 只有 6 位 hex 不夠' '沒有 commit SHA' "${H}- m1：已修 \`7c2ff8\`"$'\n' --branch "$B"
expect 1 '⑤b 41 位 hex 超過 SHA 長度不算' '沒有 commit SHA' "${H}- m1：已修 ${sha40}a"$'\n' --branch "$B"
expect 1 '⑤b 「已修正」含「已修」子字串也要 SHA' '沒有 commit SHA' "${H}- R2 已修正（M2）"$'\n' --branch "$B"
expect 1 '⑤b 引用他票的「LS-138 已修」也會中（全 body 掃取捨）' '改寫措辭' "${H}不做：Swift 程式碼（LS-138 已修）"$'\n' --branch "$B"
expect 0 '⑤ 同一行同時寫 SHA 與 comment id' '「已修」行 1 條皆帶 SHA' "${H}- m3：已修 \`7c2ff80\`；殘餘記入 LS-96 \`c2ee062d\`"$'\n' --branch "$B"
expect 0 '⑤ 表格列（單行）帶 SHA：SHA 在別欄、仍在「已修」之後（LS-186 R2 恢復為綠）' '皆帶 SHA' "${H}| m1 | minor | **已修**：補一句 | \`5727b65\` |"$'\n' --branch "$B"
expect 0 '⑤ CRLF 行尾不影響 token 抽取' '皆帶 SHA' "${H}- m1：已修 \`7c2ff80\`"$'\r\n' --branch "$B"
expect 1 '⑤ 多處違規一次全點名（不只報第一條）' '第 5 行' "${H}- 已修——沒 SHA"$'\n'"- 記入 LS-96 沒 id"$'\n' --branch "$B"
expect 1 '⑤ 檔頭段紅時仍先報檔頭、不跑申報掃描' '沒有本票票號 LS-63' $'Ticket: LS-56\n\n- 已修——沒 SHA\n' --branch "$B"

# ⑥ --verify 反查：(a) stub curl（PATH 前置、記錄 argv、依 --data 分頁回 fixture；不打真 API）列 LS-96 comment id 做前綴比對；
#   (b) SHA 用臨時 repo 驗 cat-file＋is-ancestor。
mkdir -p "$work/bin" "$work/fx"
cat > "$work/fx/page1.json" <<'EOF'
{"data":{"issue":{"identifier":"LS-96","comments":{"pageInfo":{"hasNextPage":true,"endCursor":"CURSOR1"},"nodes":[{"id":"c2ee062d-8d25-4628-88a5-73a6c750b2f3"},{"id":"d16f363b-91e0-4ca5-8d13-2194650393b0"}]}}}}
EOF
cat > "$work/fx/page2.json" <<'EOF'
{"data":{"issue":{"identifier":"LS-96","comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"9f348e36-82b6-4926-931b-5bfe1637e1f1"},{"id":"fd2fe81e-5592-443c-8b5b-1d518214c650"}]}}}}
EOF
cat > "$work/bin/curl" <<EOF
#!/bin/bash
log="\${CURL_STUB_LOG:?}"
fx="${work}/fx"
printf '%s\n' "\$*" >> "\$log"
cat >/dev/null   # 吃掉 -K - 的 stdin config
case "\${CURL_FAIL_MODE:-}" in
  exit) echo 'stub curl: connection refused' >&2; exit 7 ;;
  badjson) echo 'not json'; exit 0 ;;
  gqlerror) echo '{"errors":[{"message":"Authentication required"}],"data":null}'; exit 0 ;;
  timeout) echo 'stub curl: (28) Operation timed out after 25000 milliseconds' >&2; exit 28 ;;
  timeout_once)
    cf="\${CURL_STUB_COUNT_FILE:?}"
    n=\$(( \$(cat "\$cf" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "\$n" > "\$cf"
    if [ "\$n" -eq 1 ]; then echo 'stub curl: (28) Operation timed out after 25000 milliseconds' >&2; exit 28; fi
    ;;
  budget_cross_page)
    # LS-207 R2 F1：page1 用掉全部 3 次重試名額才成功（call 1-3 逾時、call 4 成功回 page1.json）；page2 的第一次
    # 呼叫（call 5）就撞上「共用預算已用完」直接 die——若退回舊版「每頁各自 3 次重試」，page2 會有自己全新的
    # 3 次額度，這裡不會失敗。呼叫次數上限剛好卡在 5（不會有 call 6），證明跨頁共用、總等待不隨頁數疊加。
    cf="\${CURL_STUB_COUNT_FILE:?}"
    n=\$(( \$(cat "\$cf" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "\$n" > "\$cf"
    if [ "\$n" -le 3 ] || [ "\$n" -ge 5 ]; then echo 'stub curl: (28) Operation timed out after 25000 milliseconds' >&2; exit 28; fi
    ;;
esac
data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --data) data=\$2; shift ;;
  esac
  shift
done
case "\$data" in
  *'CURSOR1'*) cat "\$fx/page2.json" ;;
  *'"after": null'*) cat "\$fx/page1.json" ;;
  *) echo '{"errors":[{"message":"stub curl：認不出的 query"}]}' ;;
esac
EOF
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH"
export CURL_STUB_LOG="$work/curl.log"
unset LINEAR_API_KEY

V="$work/vrepo"; mkdir -p "$V"
gv() { git -C "$V" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
gv init -q -b "$B"
gv commit -q --allow-empty -m 'chore: LS-63 base'
gv commit -q --allow-empty -m 'fix: LS-63 m1'
sha_in=$(gv rev-parse --short=7 HEAD)
sha_full=$(gv rev-parse HEAD)
gv checkout -q -b other
gv commit -q --allow-empty -m 'chore: LS-63 elsewhere'
sha_out=$(gv rev-parse --short=7 HEAD)
gv checkout -q "$B"
# run_v <LINEAR_API_KEY 值|''> <checker 參數…>：在臨時 repo 內跑（票號從當前分支推得）。
run_v() { local key=$1; shift; (cd "$V" && LINEAR_API_KEY="$key" bash "$check" "$@" 2>&1); }
# vexpect <期望 exit> <名稱> <輸出必含> <key> <body>
vexpect() {
  local want=$1 name=$2 must=$3 key=$4 body=$5 out got
  printf '%s' "$body" > "$work/vbody"
  out="$(run_v "$key" --verify "$work/vbody")"; got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}
both="${H}- m1：已修 \`${sha_in}\`"$'\n'"- i1：記入 LS-96 \`9f348e36\`"$'\n'

: > "$CURL_STUB_LOG"
vexpect 0 '⑥a 無 LINEAR_API_KEY → 反查略過、exit 0' '反查略過（無 LINEAR_API_KEY）' '' "$both"
if [ -s "$CURL_STUB_LOG" ]; then echo "✗ ⑥a 略過時不應呼叫 curl" >&2; sed 's/^/    /' "$CURL_STUB_LOG" >&2; fail=1; else echo "✓ ⑥a 略過時不呼叫 curl"; fi
vexpect 0 '⑥a 無 key 時 git 半段仍跑（SHA 在 PR 內）' "SHA ${sha_in} 在 PR commits 內" '' "$both"
vexpect 1 '⑥a 無 key 時 git 半段仍擋（SHA 不存在——LS-186 起與「非祖先」分開講：不是 commit object）' '不是本 repo 的 commit（候選：abcdef1）' '' "${H}- m1：已修 \`abcdef1\`"$'\n'

: > "$CURL_STUB_LOG"
vexpect 0 '⑥b 有 key：id 只在第 2 頁 → 綠（分頁到底）' '9f348e36 存在（9f348e36-82b6-4926-931b-5bfe1637e1f1）' 'test-token-not-real' "$both"
if [ "$(grep -cF '"after": null' "$CURL_STUB_LOG")" -eq 1 ] && [ "$(grep -cF 'CURSOR1' "$CURL_STUB_LOG")" -eq 1 ]; then
  echo "✓ ⑥b curl 兩次：第 1 頁 after=null、第 2 頁帶 endCursor"
else
  echo "✗ ⑥b 分頁呼叫形狀不對" >&2; sed 's/^/    /' "$CURL_STUB_LOG" >&2; fail=1
fi
if grep -qF 'test-token-not-real' "$CURL_STUB_LOG"; then
  echo "✗ ⑥b token 出現在 curl argv（應只走 stdin --config）" >&2; sed 's/^/    /' "$CURL_STUB_LOG" >&2; fail=1
else
  echo "✓ ⑥b token 沒有出現在 curl argv"
fi
vexpect 0 '⑥b id 在第 1 頁（前綴比對）' 'c2ee062d 存在' 'test-token-not-real' "${H}- i1：記入 LS-96 \`c2ee062d\`"$'\n'
vexpect 0 '⑥b 完整 UUID 也能比對' 'fd2fe81e 存在' 'test-token-not-real' "${H}- i1：記入 LS-96 \`fd2fe81e-5592-443c-8b5b-1d518214c650\`"$'\n'
vexpect 1 '⑥c id 不在 LS-96 → 紅 exit 1' '在 LS-96 找不到' 'test-token-not-real' "${H}- i1：記入 LS-96 \`deadbeef00\`"$'\n'
vexpect 1 '⑥c 找不到時列出候選與 LS-96 comment 總數' '候選：deadbeef00；LS-96 現有 4 則' 'test-token-not-real' "${H}- i1：記入 LS-96 \`deadbeef00\`"$'\n'
: > "$CURL_STUB_LOG"
vexpect 0 '⑥d body 沒有 LS-96 行 → 不打 Linear' '「已修」行 1 條' 'test-token-not-real' "${H}- m1：已修 \`${sha_in}\`"$'\n'
if [ -s "$CURL_STUB_LOG" ]; then echo "✗ ⑥d 沒有 LS-96 行不應呼叫 curl" >&2; sed 's/^/    /' "$CURL_STUB_LOG" >&2; fail=1; else echo "✓ ⑥d 沒有 LS-96 行不呼叫 curl"; fi
vexpect 0 '⑥e 完整 40 位 SHA → 綠' '在 PR commits 內' '' "${H}- m1：已修 ${sha_full}"$'\n'
vexpect 1 '⑥e SHA 存在但不是 HEAD 祖先（他分支）→ 紅' "候選：${sha_out}" '' "${H}- m1：已修 \`${sha_out}\`"$'\n'
vexpect 0 '⑥e 同行多 token：SHA 與 comment id 並列，任一可驗即過' '在 PR commits 內' '' "${H}- m1：已修 \`${sha_in}\`（殘餘 \`c2ee062d\`）"$'\n'
vexpect 1 '⑥e 同行多 token 但沒有一個是 PR 內的 commit → 紅' '不在 PR commits 內' '' "${H}- m1：已修 \`${sha_out}\` \`c2ee062d\`"$'\n'
CURL_FAIL_MODE=exit vexpect 2 '⑥f curl 非 0 → exit 2（fail closed）' 'curl 失敗（exit 7）' 'test-token-not-real' "$both"
CURL_FAIL_MODE=badjson vexpect 2 '⑥f 回應非 JSON → exit 2' '不是合法 JSON' 'test-token-not-real' "$both"
CURL_FAIL_MODE=gqlerror vexpect 2 '⑥f GraphQL errors（如 401）→ exit 2' 'Authentication required' 'test-token-not-real' "$both"

# ⑥g LS-207（7902dc20）：Linear curl 逾時／連不上先重試（退避可覆寫成極短秒數跑自測，不真的等 5/15/30s）才 fail-closed。
export PR_BODY_CHECK_LINEAR_BACKOFF='0.01,0.01,0.01'
export CURL_STUB_COUNT_FILE="$work/curl_count"
: > "$CURL_STUB_COUNT_FILE"
CURL_FAIL_MODE=timeout_once vexpect 0 '⑥g 首次逾時、第二次成功 → 綠' '9f348e36 存在' 'test-token-not-real' "${H}- i1：記入 LS-96 \`9f348e36\`"$'\n'
if [ "$(cat "$CURL_STUB_COUNT_FILE" 2>/dev/null)" -ge 2 ] 2>/dev/null; then echo "✓ ⑥g curl 確實被重試（呼叫 $(cat "$CURL_STUB_COUNT_FILE") 次）"; else echo "✗ ⑥g curl 呼叫次數異常（$(cat "$CURL_STUB_COUNT_FILE" 2>/dev/null)）——應至少重試一次" >&2; fail=1; fi
: > "$CURL_STUB_COUNT_FILE"
: > "$CURL_STUB_LOG"
CURL_FAIL_MODE=timeout vexpect 2 '⑥g 三次皆逾時 → 紅（fail closed），訊息含「非 body 問題」' '非 body 問題' 'test-token-not-real' "${H}- i1：記入 LS-96 \`9f348e36\`"$'\n'
log6g="$(cat "$CURL_STUB_LOG")"
if [ "$(printf '%s\n' "$log6g" | grep -c .)" -eq 4 ]; then echo "✓ ⑥g 三次皆逾時：總共只呼叫 4 次（1 次初次＋3 次重試），不因為之後可能還有分頁而多試"; else echo "✗ ⑥g 呼叫次數應為 4（實得 $(printf '%s\n' "$log6g" | grep -c .)）" >&2; printf '%s\n' "$log6g" | sed 's/^/    /' >&2; fail=1; fi

# ⑥h LS-207 R2（merge-review R1 fd783f6c F1）：重試預算跨分頁共用，不是每頁各一份——LS-96 目前 >250 則 comment
# 需要 ≥3 頁，R1 版每頁各自 3 次重試在間歇性逾時下最壞可疊加到數百秒、撞上 CI rules job 的 timeout-minutes。
: > "$CURL_STUB_COUNT_FILE"
: > "$CURL_STUB_LOG"
CURL_FAIL_MODE=budget_cross_page vexpect 2 '⑥h page1 用光全部 3 次共用重試名額才成功、page2 第一次呼叫就撞上預算已用完 → 紅（若退回「每頁各自 3 次」會綠，不會來到這裡）' '跨分頁共用重試預算已用完' 'test-token-not-real' "${H}- i1：記入 LS-96 \`9f348e36\`"$'\n'
log6h="$(cat "$CURL_STUB_LOG")"
n6h=$(printf '%s\n' "$log6h" | grep -c .)
if [ "$n6h" -eq 5 ]; then
  echo "✓ ⑥h 總共只呼叫 5 次（page1 用掉 4 次含 3 次重試才成功、page2 第 1 次呼叫後預算歸零直接 die，不會有第 6 次）"
else
  echo "✗ ⑥h 呼叫次數應為 5（page1 4 次＋page2 1 次），實得 ${n6h}" >&2; printf '%s\n' "$log6h" | sed 's/^/    /' >&2; fail=1
fi
if printf '%s\n' "$log6h" | grep -qF 'CURSOR1'; then echo "✓ ⑥h page2 確實有被嘗試過（cursor=CURSOR1 出現在呼叫紀錄裡），不是卡在 page1 就結束"; else echo "✗ ⑥h 沒看到 page2 的呼叫（cursor=CURSOR1），這個案例不能證明跨頁共用" >&2; printf '%s\n' "$log6h" | sed 's/^/    /' >&2; fail=1; fi

# ⑥i LS-207 R2（merge-review R1 fd783f6c I6）：PR_BODY_CHECK_LINEAR_BACKOFF="" 只有空白／被濾光時退回預設
# 5/15/30（不是變成空陣列、讓重試名額悄悄變成 0 次，die 訊息印出無意義的「重試 0 次」）。用預設值跑會真的等
# 5 秒——只驗「不是 0 次重試就死」，不驗確切秒數，故用 timeout_once（一次逾時後成功）快速驗證仍會重試。
: > "$CURL_STUB_COUNT_FILE"
PR_BODY_CHECK_LINEAR_BACKOFF='   ' CURL_FAIL_MODE=timeout_once vexpect 0 '⑥i LINEAR_BACKOFF 只有空白 → 退回預設仍重試成功（不是 0 次重試直接死）' '9f348e36 存在' 'test-token-not-real' "${H}- i1：記入 LS-96 \`9f348e36\`"$'\n'
if [ "$(cat "$CURL_STUB_COUNT_FILE" 2>/dev/null)" -ge 2 ] 2>/dev/null; then echo "✓ ⑥i 確實重試過（呼叫 $(cat "$CURL_STUB_COUNT_FILE") 次），證明沒有退化成 0 次重試預算"; else echo "✗ ⑥i 呼叫次數異常，可能退化成 0 次重試" >&2; fail=1; fi
unset PR_BODY_CHECK_LINEAR_BACKOFF CURL_STUB_COUNT_FILE

# ⑦ LS-186：「已修」SHA 候選只認同一行「已修」之後的第一個 7–40 hex token（R2；R1 曾要求緊鄰），--verify 另須為 commit object；
#   紅時最後一行在 stdout 印 ✗。來源：LS-185 PR body 標題行「## R2（merge-review R1 `d87d4334` … 皆已修）」的 review comment id
#   被當 SHA 反查、CI 紅兩次；實作者本機 `| tail -1` 吃掉 exit code 沒發現。d87d4334 在臨時 repo $V 內不是任何 object。
# absent <名稱> <輸出不得含> <body> [<checker 參數…>]：只驗輸出不含該字串（exit code 由對應的 expect 驗）。
absent() {
  local name=$1 mustnot=$2 body=$3 out
  shift 3
  printf '%s' "$body" > "$work/body"
  out="$(bash "$check" "$@" "$work/body" 2>&1)"
  if printf '%s' "$out" | grep -qF -- "$mustnot"; then
    echo "✗ ${name}（輸出不得含「${mustnot}」）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
  else
    echo "✓ ${name}"
  fi
}
LS185_RED='## R2（merge-review R1 `d87d4334` APPROVE 帶 2 minor，皆已修）'
expect 1 '⑦ LS-185 回歸（格式）：標題行含 comment id＋「皆已修」、無緊鄰 SHA → 紅並指示「需附 commit SHA 於『已修』之後」' '已修行需附 commit SHA 於『已修』之後' "${H}${LS185_RED}"$'\n' --branch "$B"
absent '⑦ LS-185 回歸（格式）：行內的 comment id 不被列為 SHA 候選' '候選：d87d4334' "${H}${LS185_RED}"$'\n' --branch "$B"
expect 0 '⑦ 已修 `<sha>`（comment `<id>`）→ 綠（LS-185 修正後的寫法）' '「已修」行 1 條皆帶 SHA' "${H}## R2：merge-review R1 APPROVE 帶 2 minor，已修 \`73fa7e1\`（review comment \`d87d4334\`）"$'\n' --branch "$B"
expect 0 '⑦ 已修（<sha>）：全形左括號可隔' '皆帶 SHA' "${H}- m1：已修（7c2ff80）"$'\n' --branch "$B"
expect 0 '⑦ 已修：`<sha>`（冒號隔開，PR #256 形狀）→ 綠（R2：不再要求緊鄰）' '皆帶 SHA' "${H}- m1：已修：\`7c2ff80\`"$'\n' --branch "$B"
expect 0 '⑦ **已修**（commit `<sha>`）（PR #286 形狀：括號後先寫 commit）→ 綠' '皆帶 SHA' "${H}- m1：**已修**（commit \`7bed50a\`）"$'\n' --branch "$B"
expect 0 '⑦ 已修，…。commit `<sha>`。（PR #270 形狀：句尾才給 SHA）→ 綠' '皆帶 SHA' "${H}- m1：已修，改用 label closure 取代 delegate。commit \`d2df2ef\`。"$'\n' --branch "$B"
expect 0 '⑦ 表格別欄 | 已修：… | `<sha>` |（PR #251／#254 形狀）→ 綠' '皆帶 SHA' "${H}| m2 | minor | 已修：補一句 | \`5727b65\` |"$'\n' --branch "$B"
expect 1 '⑦ `<sha>` 已修：hex 在「已修」之前不算' '沒有 commit SHA' "${H}- m1：\`7c2ff80\` 已修"$'\n' --branch "$B"
expect 1 '⑦ 已修 x<sha>y：截出的 hex 不算獨立 token' '沒有 commit SHA' "${H}- m1：已修 x7c2ff80y"$'\n' --branch "$B"
expect 0 '⑦ 已修（<8 hex>）：格式模式分不出 comment id 與短 SHA → 綠（--verify 才紅，見下）' '皆帶 SHA' "${H}- minor-1 已修（d87d4334）"$'\n' --branch "$B"
expect 0 '⑦ 一行兩個「已修」：只看第一個「已修」之後的第一個 hex' '「已修」行 1 條皆帶 SHA' "${H}- m1 已修 \`7c2ff80\`；m2 已修 \`5727b65\`"$'\n' --branch "$B"
# 紅時最後一行在 stdout（不是 stderr）印 ✗：模擬 LS-185 的 `| tail -1` 用法——只接 stdout 也要看得到 ✗；三條 exit 1 出口都驗
last_stdout() { printf '%s' "$1" > "$work/body"; bash "$check" --branch "$B" "$work/body" 2>/dev/null | tail -n 1; }
last="$(last_stdout "${H}${LS185_RED}"$'\n')"
case "$last" in '✗ pr-body-check：未通過'*) echo '✓ ⑦ 申報紅：stdout 最後一行是「✗ pr-body-check：未通過…」（| tail -1 也看得到）' ;; *) echo "✗ ⑦ 申報紅：stdout 最後一行應為 ✗ pr-body-check：未通過…（實得「${last}」）" >&2; fail=1 ;; esac
last="$(last_stdout $'Ticket: LS-56\n')"
case "$last" in '✗ pr-body-check：未通過'*) echo '✓ ⑦ 檔頭段紅：stdout 最後一行也是 ✗' ;; *) echo "✗ ⑦ 檔頭段紅：stdout 最後一行應為 ✗（實得「${last}」）" >&2; fail=1 ;; esac
last="$(last_stdout '')"
case "$last" in '✗ pr-body-check：未通過'*) echo '✓ ⑦ 空 body 紅：stdout 最後一行也是 ✗' ;; *) echo "✗ ⑦ 空 body 紅：stdout 最後一行應為 ✗（實得「${last}」）" >&2; fail=1 ;; esac
last="$(last_stdout "${H}- m1：已修 \`7c2ff80\`"$'\n')"
case "$last" in '✓ '*) echo '✓ ⑦ 綠時 stdout 最後一行是 ✓（不印「未通過」）' ;; *) echo "✗ ⑦ 綠時 stdout 最後一行應為 ✓（實得「${last}」）" >&2; fail=1 ;; esac
# --verify：緊鄰候選須為 commit object（臨時 repo $V）
vexpect 1 '⑦ --verify LS-185 回歸：「皆已修」無 SHA → 紅、訊息是「需附 commit SHA」' '已修行需附 commit SHA 於『已修』之後' '' "${H}${LS185_RED}"$'\n'
vexpect 0 '⑦ --verify 已修 `<PR 內 sha>`（review comment `d87d4334`）→ 綠' "SHA ${sha_in} 在 PR commits 內" '' "${H}## R2：merge-review R1 APPROVE 帶 2 minor，已修 \`${sha_in}\`（review comment \`d87d4334\`）"$'\n'
vexpect 1 '⑦ --verify 已修（<comment id>）：「已修」後第一個 hex 不是 commit object → 紅「不是本 repo 的 commit」＋「需附 commit SHA」' '不是本 repo 的 commit（候選：d87d4334）' '' "${H}- minor-1 已修（d87d4334）"$'\n'
vexpect 1 '⑦ --verify 「已修」後第一個 hex 是 comment id、真 SHA 在其後 → 仍紅（只看第一個，不是「之後任一 hex 即過」）' '不是本 repo 的 commit（候選：d87d4334）' '' "${H}- 已修（comment \`d87d4334\`，commit \`${sha_in}\`）"$'\n'
printf '%s' "${H}- minor-1 已修（d87d4334）"$'\n' > "$work/vbody"
out="$(run_v '' --verify "$work/vbody")"
if printf '%s' "$out" | grep -qF '不在 PR commits 內'; then
  echo "✗ ⑦ --verify comment id 形狀不得再報成「不在 PR commits 內」（LS-185 的誤導訊息）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
else
  echo "✓ ⑦ --verify comment id 形狀不再報成「不在 PR commits 內」（與「非祖先」分開講）"
fi

# ⑧ LS-198（LS-186 R2 info-1／2）：格式模式對純數字候選印警告不紅；deny 訊息補「檔名／行號裡的數字也算 hex token」。
#   20260904212530 是 migration 檔名前綴：14 位 [0-9] 落在 7–40 hex 內，格式模式無法與短 SHA 區分（只有 --verify 的 git cat-file 裁得出來）。
expect 0 '⑧-a 已修 `20260904212530_x.sql` `<sha>`：格式模式仍綠、但對純數字候選印 ⚠ 警告（mutation：拿掉警告即紅）' '是純數字' "${H}- m1：已修 \`20260904212530_suspension.sql\` \`7c2ff80\`"$'\n' --branch "$B"
absent '⑧-a 已修 `<sha>` `20260904212530_x.sql`（SHA 在前）→ 不印純數字警告' '是純數字' "${H}- m1：已修 \`7c2ff80\` \`20260904212530_suspension.sql\`"$'\n' --branch "$B"
vexpect 1 '⑧-b --verify：migration 檔名前綴排在 SHA 之前 → 紅，deny 訊息指出檔名／行號裡的數字也算 hex token、把 SHA 放『已修』後第一個' '檔名／行號裡的數字也算 hex token' '' "${H}- m1：已修 \`20260904212530_suspension.sql\` \`${sha_in}\`"$'\n'

if [ "$fail" -eq 0 ]; then
  echo "✓ pr-body-check 自測通過（91 組樣本）"
fi
exit "$fail"
