#!/bin/bash
# approval-comment-check.sh 的自測（LS-123）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若退化成不看作者（非 owner 留言也放行）、不逐則送既有 gate（散文提及也
# 放行）、gh 失敗／非 JSON／缺 owner 靜默放行、分頁第二頁看不到、或 gate 命令根本沒被呼叫，這裡會紅。
# PATH 前置假 gh 回固定 JSON fixture（形狀照 PR #218 真實 comment 5503728612），不打真 API。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/approval-comment-check.sh"
gate="${root}/scripts/gates/destructive-approval-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/bin/bash
# 假 gh：記錄參數；`api …` 回 GH_STUB_FIXTURE 檔內容（GH_STUB_FAIL=1 則失敗）；`repo view` 回 GH_STUB_REPO_VIEW。
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
case "${1:-} ${2:-}" in
  'api '*)
    [ "${GH_STUB_FAIL:-0}" = 1 ] && { echo "gh: Not Found (HTTP 404) (stub)" >&2; exit 1; }
    cat "${GH_STUB_FIXTURE:?}" ;;
  'repo view')
    [ -n "${GH_STUB_REPO_VIEW:-}" ] || { echo "gh: not a git repository (stub)" >&2; exit 1; }
    printf '%s\n' "$GH_STUB_REPO_VIEW" ;;
  *) echo "stub gh: unexpected $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_STUB_LOG="$work/gh.log" GH_STUB_FIXTURE="$work/fixture.json"
export GITHUB_REPOSITORY=CLYEH/little-sprout GITHUB_REPOSITORY_OWNER=CLYEH

fixture() { printf '%s' "$1" > "$GH_STUB_FIXTURE"; }

# expect <期望 exit code> <樣本名稱> <輸出必含字串|''> <checker 參數…>
expect() {
  local want=$1 name=$2 must=$3 out got
  shift 3
  : > "$GH_STUB_LOG"
  out="$(bash "$check" "$@" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}
log_has() {   # log_has <名稱> <gh 呼叫記錄必含>
  if grep -qF -- "$2" "$GH_STUB_LOG"; then echo "✓ ${1}"; else echo "✗ ${1}（gh 呼叫記錄應含「${2}」）" >&2; sed 's/^/    /' "$GH_STUB_LOG" >&2; fail=1; fi
}
no_gh() {
  if [ ! -s "$GH_STUB_LOG" ]; then echo "✓ ${1}"; else echo "✗ ${1}（不應呼叫 gh）" >&2; sed 's/^/    /' "$GH_STUB_LOG" >&2; fail=1; fi
}

# 真實形狀：PR #218 comment 5503728612（2026-09-02T03:08:35Z，user CLYEH，body 恰為 DESTRUCTIVE-APPROVED）
OWNER_EXACT='{"id":5503728612,"created_at":"2026-09-02T03:08:35Z","user":{"login":"CLYEH","type":"User"},"body":"DESTRUCTIVE-APPROVED"}'
OTHER_EXACT='{"id":1,"created_at":"2026-09-02T03:00:00Z","user":{"login":"someone-else","type":"User"},"body":"DESTRUCTIVE-APPROVED"}'
OWNER_PROSE='{"id":2,"created_at":"2026-09-02T03:01:00Z","user":{"login":"CLYEH","type":"User"},"body":"等待我蓋 DESTRUCTIVE-APPROVED 後再合併"}'
OWNER_TICK='{"id":4,"created_at":"2026-09-02T03:02:00Z","user":{"login":"CLYEH","type":"User"},"body":"`DESTRUCTIVE-APPROVED`"}'
OWNER_CHAT='{"id":5,"created_at":"2026-09-02T03:03:00Z","user":{"login":"CLYEH","type":"User"},"body":"看起來沒問題"}'

# ① owner 留言獨佔行 → 綠，並印出命中的 comment id 供對照
fixture "[${OWNER_EXACT}]"
expect 0 '① owner 留言獨佔行（PR #218 真實形狀）→ exit 0' 'comment 5503728612 @ 2026-09-02T03:08:35Z' 218 bash "$gate"
log_has '① 打的是 issues comments endpoint＋--paginate' 'api repos/CLYEH/little-sprout/issues/218/comments --paginate'

# ② 非 owner 留言（即使獨佔行）→ 紅
fixture "[${OTHER_EXACT}]"
expect 1 '② 非 owner 留言獨佔行 → exit 1' '無一則命中' 218 bash "$gate"

# ③ owner 留言但散文提及／反引號包起 → 紅（規則由既有 gate 決定）
fixture "[${OWNER_PROSE}]"
expect 1 '③ owner 散文提及 → exit 1' '無一則命中' 218 bash "$gate"
fixture "[${OWNER_TICK}]"
expect 1 '③ owner 反引號包起 → exit 1' '無一則命中' 218 bash "$gate"

# ④ 多則其中一則命中 → 綠，命中的是 owner 那則
fixture "[${OTHER_EXACT},${OWNER_PROSE},${OWNER_EXACT},${OWNER_CHAT}]"
expect 0 '④ 多則其中一則 owner 獨佔行 → exit 0' 'comment 5503728612 @' 218 bash "$gate"

# ⑤ CRLF＋前後空白（web UI 貼上）→ 綠
fixture '[{"id":6,"created_at":"2026-09-02T03:04:00Z","user":{"login":"CLYEH","type":"User"},"body":"看過了\r\n  DESTRUCTIVE-APPROVED  \r\n謝謝"}]'
expect 0 '⑤ owner 留言 CRLF＋前後空白 → exit 0' 'comment 6 @' 218 bash "$gate"

# ⑥ gh 失敗 → exit 2（fail closed）
fixture "[${OWNER_EXACT}]"
export GH_STUB_FAIL=1
expect 2 '⑥ gh api 失敗 → exit 2（fail closed）' 'fail closed' 218 bash "$gate"
unset GH_STUB_FAIL

# ⑦ 回應非 JSON／錯誤物件／空回應 → exit 2
fixture '<html>oops</html>'
expect 2 '⑦ 回應非 JSON → exit 2' '不是 comment JSON 陣列' 218 bash "$gate"
fixture '{"message":"Not Found","documentation_url":"https://docs.github.com"}'
expect 2 '⑦ 回應是錯誤物件 → exit 2' 'Not Found' 218 bash "$gate"
fixture ''
expect 2 '⑦ 空回應 → exit 2' '空回應' 218 bash "$gate"
fixture '[1,2]'
expect 2 '⑦ 陣列內非物件 → exit 2' '非物件' 218 bash "$gate"

# ⑧ 零則 comment → 紅（不是 exit 2：API 正常、只是沒人核可）
fixture '[]'
expect 1 '⑧ 零則 comment → exit 1' '共 0 則' 218 bash "$gate"

# ⑨ 分頁：gh --paginate 逐頁串接（[…][…]），命中在第二頁 → 綠；--slurp 形狀（[[…],[…]]）也認得
fixture "[${OTHER_EXACT},${OWNER_PROSE}]"$'\n'"[{\"id\":9,\"created_at\":\"2026-09-02T03:05:00Z\",\"user\":{\"login\":\"CLYEH\",\"type\":\"User\"},\"body\":\"DESTRUCTIVE-APPROVED\"}]"
expect 0 '⑨ 分頁串接、命中在第二頁 → exit 0' 'comment 9 @' 218 bash "$gate"
fixture "[[${OTHER_EXACT}],[${OWNER_EXACT}]]"
expect 0 '⑨ --slurp 形狀（巢狀陣列）→ exit 0' 'comment 5503728612 @' 218 bash "$gate"

# ⑩ repo／owner 來源：環境變數缺時退回 gh repo view；兩邊都拿不到 → exit 2
unset GITHUB_REPOSITORY GITHUB_REPOSITORY_OWNER
fixture "[${OWNER_EXACT}]"
expect 2 '⑩ 缺 GITHUB_REPOSITORY(_OWNER) 且 gh repo view 失敗 → exit 2' '無法判定 repo／owner' 218 bash "$gate"
export GH_STUB_REPO_VIEW='CLYEH/little-sprout CLYEH'
expect 0 '⑩ 退回 gh repo view 取 repo／owner → exit 0' 'comment 5503728612 @' 218 bash "$gate"
log_has '⑩ 退回時用 repo view 的 repo 組 endpoint' 'api repos/CLYEH/little-sprout/issues/218/comments'
unset GH_STUB_REPO_VIEW
export GITHUB_REPOSITORY=CLYEH/little-sprout GITHUB_REPOSITORY_OWNER=CLYEH

# ⑪ login 精確比對（大小寫不同不算；GitHub 回的是正典大小寫）；user 為 null（帳號已刪）不炸、不算
fixture '[{"id":10,"created_at":"2026-09-02T03:06:00Z","user":{"login":"clyeh","type":"User"},"body":"DESTRUCTIVE-APPROVED"}]'
expect 1 '⑪ login 大小寫不同 → exit 1' '無一則命中' 218 bash "$gate"
fixture '[{"id":11,"created_at":"2026-09-02T03:07:00Z","user":null,"body":"DESTRUCTIVE-APPROVED"}]'
expect 1 '⑪ user 為 null → exit 1（不炸）' '共 0 則' 218 bash "$gate"
fixture '[{"id":12,"created_at":"2026-09-02T03:08:00Z","user":{"login":"CLYEH","type":"User"},"body":null}]'
expect 1 '⑪ owner body 為 null → exit 1（不炸）' '共 1 則' 218 bash "$gate"

# ⑫ gate 命令是通用 stdin 契約：migration-immutable-check 的逃生口 regex 也能直接傳
MIG_RE='^[[:space:]]*MIGRATION-REWRITE-APPROVED:[[:space:]]*LS-[1-9][0-9]*[[:space:]]*$'
fixture '[{"id":13,"created_at":"2026-09-02T03:09:00Z","user":{"login":"CLYEH","type":"User"},"body":"MIGRATION-REWRITE-APPROVED: LS-8\n理由：尚未部署"}]'
expect 0 '⑫ 通用 gate：MIGRATION-REWRITE-APPROVED 獨佔行 → exit 0' 'comment 13 @' 218 grep -qE "$MIG_RE"
fixture '[{"id":14,"created_at":"2026-09-02T03:10:00Z","user":{"login":"CLYEH","type":"User"},"body":"這次不需要 MIGRATION-REWRITE-APPROVED: LS-8"}]'
expect 1 '⑫ 通用 gate：散文提及 → exit 1' '無一則命中' 218 grep -qE "$MIG_RE"

# ⑬ mutation 負控：gate 真的被逐則呼叫（gate 永遠失敗 → 即使 owner 獨佔行也紅）；作者過濾在 gate 之前
#    （gate 永遠成功但只有非 owner 留言 → 仍紅）
fixture "[${OWNER_EXACT}]"
expect 1 '⑬ gate 永遠失敗 → exit 1（gate 確實被呼叫）' '無一則命中' 218 false
fixture "[${OTHER_EXACT}]"
expect 1 '⑬ gate 永遠成功但只有非 owner → exit 1（作者過濾先於 gate）' '共 0 則' 218 true

# ⑭ 參數錯 → exit 2、不呼叫 gh
expect 2 '⑭ 缺 pr-number → exit 2' '正整數'
no_gh '⑭ 缺 pr-number 不呼叫 gh'
expect 2 '⑭ pr-number 非正整數 → exit 2' '正整數' abc bash "$gate"
no_gh '⑭ pr-number 非正整數不呼叫 gh'
expect 2 '⑭ pr-number 為 0 → exit 2' '正整數' 0 bash "$gate"
expect 2 '⑭ 缺 gate 命令 → exit 2' '缺 <gate-command>' 218
no_gh '⑭ 缺 gate 命令不呼叫 gh'

if [ "$fail" -eq 0 ]; then
  echo "✓ approval-comment-check 自測通過"
fi
exit "$fail"
