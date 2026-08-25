#!/bin/bash
# pr-body-check.sh 的自測（LS-63）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成全文子字串比對（第二段有票號就放行、LS-630 滿足 LS-63）、
# 模板形狀「## Ticket／空行／LS-<n>」被誤擋、缺檔／非工作分支時靜默放行、或失敗輸出丟掉「CI 不會自動重跑」止血指示，這裡會紅。
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

if [ "$fail" -eq 0 ]; then
  echo "✓ pr-body-check 自測通過（22 組樣本）"
fi
exit "$fail"
