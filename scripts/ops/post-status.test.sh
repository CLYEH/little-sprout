#!/bin/bash
# post-status.sh 的自測（LS-87）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對貼 status 的封裝也適用：若退化成短 SHA／錯 context／錯 state 照貼、空 description 照貼、貼的 endpoint 或
# 欄位不對（GitHub 收到的是另一個 SHA／context）、gh 失敗當成已貼、回讀不符當成已貼、--url 沒傳成 target_url——這裡會紅。
# gh 用 PATH 上的 stub：記錄整串參數、把 -f key=value 組回 JSON 當 GitHub 回應（--jq 交給真 jq 跑，驗的是腳本自己的表達式）；
# GH_STUB_FAIL=1 模擬 HTTP 失敗；GH_STUB_STATE=<x> 讓回應的 state 與送出的不同（驗回讀核對）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
post="${root}/scripts/ops/post-status.sh"
fail=0
command -v jq >/dev/null 2>&1 || { echo "✗ post-status 自測需要 jq（stub gh 用它跑 --jq）" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
repo="$work/repo"; git init -q -b main "$repo"

mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
[ "${GH_STUB_FAIL:-0}" = 1 ] && { echo "gh: HTTP 422 (stub)" >&2; exit 1; }
expr=; json='{"id":4242'
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) expr=$2; shift ;;
    -f) kv=$2; shift; k=${kv%%=*}; v=${kv#*=}
        [ "$k" = state ] && [ -n "${GH_STUB_STATE:-}" ] && v=$GH_STUB_STATE
        json="${json},\"${k}\":$(jq -Rn --arg v "$v" '$v')" ;;
  esac
  shift
done
json="${json}}"
if [ -n "$expr" ]; then printf '%s' "$json" | jq -r "$expr"; else printf '%s\n' "$json"; fi
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_STUB_LOG="$work/gh.log"

SHA=0123456789abcdef0123456789abcdef01234567
out=; rc=
# expect <期望 exit> <名稱> <輸出必含|''> <post-status 參數…>（在合成 repo 內執行）
expect() {
  local want=$1 name=$2 must=$3; shift 3
  : > "$GH_STUB_LOG"
  out="$(cd "$repo" && bash "$post" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then echo "✓ ${name}"
  else echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
}
has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✗ ${1}（不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else echo "✓ $1"; fi; }
no_gh() { if [ -s "$GH_STUB_LOG" ]; then echo "✗ ${1}（不該呼叫 gh）" >&2; sed 's/^/    /' "$GH_STUB_LOG" >&2; fail=1; else echo "✓ $1"; fi; }

# ---- ① 正常：merge-review success 帶 --url → exit 0、POST 到正確 endpoint、四個欄位都送出 ----
expect 0 '① merge-review success --url → exit 0' "✓ status merge-review=success 已貼到 ${SHA}" "$SHA" merge-review success 'APPROVE R2 · linear:abc-123' --url 'https://linear.app/x/issue/LS-1#comment-abc'
log=$(cat "$GH_STUB_LOG")
has   '① -X POST repos/{owner}/{repo}/statuses/<sha>' "$log" "-X POST repos/{owner}/{repo}/statuses/${SHA}"
has   '① state=success' "$log" '-f state=success'
has   '① context=merge-review' "$log" '-f context=merge-review'
has   '① description 原樣送出' "$log" '-f description=APPROVE R2 · linear:abc-123'
has   '① --url → target_url' "$log" '-f target_url=https://linear.app/x/issue/LS-1#comment-abc'
has   '① 輸出印 id' "$out" 'id 4242'

# ---- ② qa failure（BLOCKED）不帶 --url → 不送 target_url；--url 放在前面也認 ----
expect 0 '② qa failure 無 --url → exit 0' 'status qa=failure' "$SHA" qa failure 'BLOCKED: 缺實機 · linear:def-456'
hasnt '② 無 --url 不送 target_url' "$(cat "$GH_STUB_LOG")" '-f target_url='
expect 0 '② --url 在前 → 仍認得四個位置參數' 'status qa=success' --url 'http://x' "$SHA" qa success 'PASS R1 · linear:ghi'
has   '② --url 在前 → target_url 送出' "$(cat "$GH_STUB_LOG")" '-f target_url=http://x'
expect 0 '② pending 合法' 'status merge-review=pending' "$SHA" merge-review pending '審查中 R1'

# ---- ③ 參數驗證 fail closed（exit 2、不呼叫 gh）----
expect 2 '③ 短 SHA → exit 2' '長度 7≠40' 0123456 merge-review success 'x'; no_gh '③ 短 SHA 不呼叫 gh'
expect 2 '③ 大寫／非 hex SHA → exit 2' '不是小寫 40 位' 0123456789ABCDEF0123456789abcdef01234567 merge-review success 'x'; no_gh '③ 非 hex 不呼叫 gh'
expect 2 '③ context 不在白名單 → exit 2' '只允許 merge-review 或 qa' "$SHA" review success 'x'; no_gh '③ 錯 context 不呼叫 gh'
expect 2 '③ state=error → exit 2' '只允許 success／failure／pending' "$SHA" qa error 'x'; no_gh '③ 錯 state 不呼叫 gh'
expect 2 '③ state=APPROVE（裁決詞不是 state）→ exit 2' '只允許 success／failure／pending' "$SHA" merge-review APPROVE 'x'
expect 2 '③ description 空白 → exit 2' 'description 不得為空' "$SHA" qa success '   '; no_gh '③ 空 description 不呼叫 gh'
long=$(printf 'a%.0s' $(seq 1 141))
expect 2 '③ description 141 字 → exit 2' '超過 GitHub 上限 140' "$SHA" qa success "$long"; no_gh '③ 過長不呼叫 gh'
expect 2 '③ --url 缺值 → exit 2' '--url 缺值' "$SHA" qa success 'x' --url
expect 2 '③ --url 非 http(s) → exit 2' '須以 http(s):// 開頭' "$SHA" qa success 'x' --url 'linear.app/x'
expect 2 '③ 少一個位置參數 → exit 2' '用法' "$SHA" qa success
expect 2 '③ 多一個位置參數（description 沒加引號）→ exit 2' '參數過多' "$SHA" qa success APPROVE R2
expect 2 '③ 未知旗標 → exit 2' '未知參數' "$SHA" qa success 'x' --bogus
expect 2 '③ 無參數 → exit 2' '用法'

# ---- ④ 不在 git repo → exit 2（{owner}/{repo} 無從推）----
: > "$GH_STUB_LOG"
out="$(cd "$work" && bash "$post" "$SHA" qa success 'x' 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF '請在 repo 內執行'; then echo "✓ ④ 不在 git repo → exit 2"; else echo "✗ ④ 不在 git repo 應 exit 2（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
no_gh '④ 不在 repo 不呼叫 gh'

# ---- ⑤ gh 失敗 → exit 1、明說未貼 ----
: > "$GH_STUB_LOG"
out="$(cd "$repo" && GH_STUB_FAIL=1 bash "$post" "$SHA" merge-review success 'APPROVE R1' 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'status 未貼'; then echo "✓ ⑤ gh 失敗 → exit 1 並明說未貼"; else echo "✗ ⑤ gh 失敗應 exit 1 並明說未貼（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
hasnt '⑤ gh 失敗不印 ✓' "$out" '✓'

# ---- ⑥ 回讀不符（GitHub 回的 state 與送出的不同）→ exit 1 ----
out="$(cd "$repo" && GH_STUB_STATE=error bash "$post" "$SHA" merge-review success 'APPROVE R1' 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF '回讀不符'; then echo "✓ ⑥ 回讀 state 不符 → exit 1"; else echo "✗ ⑥ 回讀不符應 exit 1（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

# ---- ⑦ gh 未安裝 → exit 2 ----
# PATH 只留 nobin（裡面只有 bash／git 的 symlink），不能再掛 /usr/bin：Linux runner 的真 gh 就在 /usr/bin/gh，`command -v gh` 命中後
# 腳本走到 POST、因無 token 而 exit 1（非 2）→ CI rules 紅（R2 B1）；有 GH_TOKEN 的環境更會真的對假 SHA 發 POST——自測不得碰網路。
mkdir -p "$work/nobin"; ln -s "$(command -v bash)" "$work/nobin/bash"; ln -s "$(command -v git)" "$work/nobin/git"
out="$(cd "$repo" && env PATH="$work/nobin" "$work/nobin/bash" "$post" "$SHA" qa success 'x' 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF '需要 gh'; then echo "✓ ⑦ gh 未安裝 → exit 2"; else echo "✗ ⑦ gh 未安裝應 exit 2（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

if [ "$fail" -ne 0 ]; then
  echo "✗ post-status 自測失敗" >&2
  exit 1
fi
echo "✓ post-status 自測通過（7 組樣本）"
