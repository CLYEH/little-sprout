#!/bin/bash
# db-start-retry.sh 的自測（LS-351 追加）。CI rules job 跑。不碰真容器：PATH 前置假 `supabase`／`sleep`——假 supabase 把每次
# 呼叫追加到 $FAKE_LOG、依 $FAKE_MODE 與「第幾次 db start」決定輸出與 exit code；假 sleep 只記錄秒數不等待。
# 覆蓋：成功不重試；限流一次後成功（印「→ ghcr 限流，第 1 次重試」、sleep 30）；限流持續 → 恰 3 次重試（30／60／120）後紅、
# exit code 保留；非限流錯誤立即紅不重試、exit code 保留；非 CI 且無放行變數 → exit 2 不呼叫 supabase；
# mutation：拿掉「只有 toomanyrequests 才重試」的判斷 → 非限流錯誤也被重試。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ci/db-start-retry.sh"
fail=0
source "${root}/scripts/gates/lib/selftest-helpers.sh"
fail() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat > "$work/bin/supabase" <<'EOF'
#!/bin/bash
log="${FAKE_LOG:?}"
printf '%s\n' "$*" >> "$log"
k=$(grep -c '^db start$' "$log")
case "${FAKE_MODE:?}" in
  ok) echo 'Started supabase local development setup.'; exit 0 ;;
  limit_once)
    if [ "$k" -eq 1 ]; then echo 'failed to pull docker image from all registries: ghcr.io/supabase/postgres:17: toomanyrequests: retry-after: 1s' >&2; exit 1; fi
    echo 'Started supabase local development setup.'; exit 0 ;;
  limit_always) echo 'Error response from daemon: toomanyrequests: rate limit exceeded' >&2; exit 4 ;;
  other_error) echo 'Error: failed to create docker network' >&2; exit 5 ;;
esac
EOF
cat > "$work/bin/sleep" <<'EOF'
#!/bin/bash
printf 'sleep %s\n' "$1" >> "${FAKE_LOG:?}"
EOF
chmod +x "$work/bin/supabase" "$work/bin/sleep"

# run <mode> [<script>]：放行本機、清 CI 變數，輸出到 $work/out、呼叫紀錄到 $FAKE_LOG
run() {
  : > "$work/calls"
  FAKE_LOG="$work/calls" FAKE_MODE="$1" PATH="$work/bin:$PATH" GITHUB_ACTIONS= CI= LS_DB_START_RETRY_ALLOW_LOCAL=1 \
    bash "${2:-$script}" > "$work/out" 2>&1
}
calls() { paste -s -d '|' "$work/calls"; }

run ok; rc=$?
expect_exit 0 "$rc" '① 成功 → exit 0'
expect_has "$(calls)" 'db start' '① 呼叫 db start 一次'
[ "$(grep -c '^db start$' "$work/calls")" -eq 1 ] && ok '① 成功不重試（db start 恰 1 次）' || fail '① 成功不應重試'

run limit_once; rc=$?
expect_exit 0 "$rc" '② 限流一次後成功 → exit 0'
expect_has "$(cat "$work/out")" '→ ghcr 限流，第 1 次重試' '② 印「→ ghcr 限流，第 1 次重試」'
expect_has "$(calls)" 'db start|sleep 30|db start' '② 序列 db start → sleep 30 → db start'

run limit_always; rc=$?
expect_exit 4 "$rc" '③ 限流持續 → 保留原 exit code 4'
expect_has "$(calls)" 'db start|sleep 30|db start|sleep 60|db start|sleep 120|db start' '③ 恰 3 次重試、間隔 30／60／120'
[ "$(grep -c '^db start$' "$work/calls")" -eq 4 ] && ok '③ 最多 3 次重試（db start 共 4 次，不會第 5 次）' || fail '③ db start 次數不是 4'
expect_has "$(cat "$work/out")" '→ ghcr 限流，第 3 次重試' '③ 印到第 3 次重試'
expect_has "$(cat "$work/out")" '重試 3 次後 supabase db start 仍失敗' '③ 最後印 ✗ 重試用盡'

run other_error; rc=$?
expect_exit 5 "$rc" '④ 非限流錯誤 → 保留原 exit code 5'
[ "$(grep -c '^db start$' "$work/calls")" -eq 1 ] && ok '④ 非限流錯誤不重試（db start 恰 1 次）' || fail '④ 非限流錯誤不應重試'
expect_not_has "$(calls)" 'sleep' '④ 非限流錯誤不 sleep'
expect_has "$(cat "$work/out")" 'failed to create docker network' '④ 原錯誤訊息保留在輸出'

: > "$work/calls"
FAKE_LOG="$work/calls" FAKE_MODE=ok PATH="$work/bin:$PATH" GITHUB_ACTIONS= CI= LS_DB_START_RETRY_ALLOW_LOCAL= bash "$script" > "$work/out" 2>&1; rc=$?
expect_exit 2 "$rc" '⑤ 非 CI 且無放行變數 → exit 2'
[ -s "$work/calls" ] && fail '⑤ 守門擋下時不應呼叫 supabase' || ok '⑤ 守門擋下時完全不呼叫 supabase'

# ⑥ mutation：拿掉「只有 toomanyrequests 才重試」→ 非限流錯誤也被重試（db start 次數 > 1）
mut="$work/mut.sh"
sed 's/^  if ! grep -qF -- "\$RATE_LIMIT" "\$log"; then$/  if false; then  # LS-351 mutation/' "$script" > "$mut"
if ! grep -q 'LS-351 mutation' "$mut"; then
  fail '⑥ mutant 沒被正確合成'
else
  run other_error "$mut"
  [ "$(grep -c '^db start$' "$work/calls")" -gt 1 ] && ok '⑥ mutant（拿掉限流判斷）：非限流錯誤也被重試——證明 ④ 的綠來自這個判斷' || fail '⑥ mutant 未如預期重試'
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ db-start-retry 自測失敗" >&2
  exit 1
fi
echo "✓ db-start-retry 自測通過"
