#!/bin/bash
# pr-body-check.sh 的自測（LS-63；LS-140 加申報可驗證段）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成全文子字串比對（第二段有票號就放行、LS-630 滿足 LS-63）、
# 模板形狀「## Ticket／空行／LS-<n>」被誤擋、缺檔／非工作分支時靜默放行、或失敗輸出丟掉「CI 不會自動重跑」止血指示，這裡會紅。
# LS-140：LS-96／入池／待辦池 行缺 comment id、「已修」行缺 SHA 若放行（拿掉規則 (a)／(b) 即紅）、--verify 反查退化
#   （id 不在 LS-96／SHA 不在 PR 內卻綠、分頁只讀第一頁、token 進 curl argv、curl／GraphQL 失敗靜默放行）這裡也會紅。
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
expect 0 '⑤ 表格列（單行）帶 SHA' '皆帶 SHA' "${H}| m1 | minor | **已修**：補一句 | \`5727b65\` |"$'\n' --branch "$B"
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
vexpect 1 '⑥a 無 key 時 git 半段仍擋（SHA 不存在）' '不在 PR commits 內' '' "${H}- m1：已修 \`abcdef1\`"$'\n'

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

if [ "$fail" -eq 0 ]; then
  echo "✓ pr-body-check 自測通過（66 組樣本）"
fi
exit "$fail"
