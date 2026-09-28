#!/bin/bash
# db-start-retry.sh 的自測（LS-351 追加）。CI rules job 跑。不碰真容器：PATH 前置假 `supabase`／`sleep`——假 supabase 把每次
# 呼叫追加到 $FAKE_LOG、依 $FAKE_MODE 與「第幾次 db start」決定輸出與 exit code；假 sleep 只記錄秒數不等待。
# 覆蓋：成功不重試；限流一次後成功（印「→ 映像限流（toomanyrequests），第 1 次重試」、sleep 30）；限流持續 → 恰 4 次重試
# （30／60／120／240，LS-392）後紅、exit code 保留、印「⚠ db-start-retry：疑似映像限流（toomanyrequests）」；非限流錯誤立即紅
# 不重試、exit code 保留、不印 ⚠ 限流行；成功時「映像來源」行區分有無拉取（LS-392）；非 CI 且無放行變數 → exit 2 不呼叫
# supabase；mutation：拿掉「只有 toomanyrequests 才重試」的判斷 → 非限流錯誤也被重試；拿掉退避 sleep → 無間隔；
# 拿掉 ⚠ 限流行 → 用盡時不印（LS-392）。
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
  ok_pull) echo '17.6.1.159: Pulling from supabase/postgres'; echo 'Started supabase local development setup.'; exit 0 ;;
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
expect_has "$(cat "$work/out")" '→ 映像限流（toomanyrequests），第 1 次重試' '② 印「→ 映像限流（toomanyrequests），第 1 次重試」'
expect_has "$(calls)" 'db start|sleep 30|db start' '② 序列 db start → sleep 30 → db start'

run limit_always; rc=$?
expect_exit 4 "$rc" '③ 限流持續 → 保留原 exit code 4'
expect_has "$(calls)" 'db start|sleep 30|db start|sleep 60|db start|sleep 120|db start|sleep 240|db start' '③ 恰 4 次重試、間隔 30／60／120／240（LS-392）'
[ "$(grep -c '^db start$' "$work/calls")" -eq 5 ] && ok '③ 最多 4 次重試（db start 共 5 次，不會第 6 次）' || fail "③ db start 次數不是 5（實得 $(grep -c '^db start$' "$work/calls")）"
expect_has "$(cat "$work/out")" '→ 映像限流（toomanyrequests），第 4 次重試' '③ 印到第 4 次重試'
expect_has "$(cat "$work/out")" '重試 4 次後 supabase db start 仍失敗' '③ 最後印 ✗ 重試用盡'
expect_has "$(cat "$work/out")" '⚠ db-start-retry：疑似映像限流（toomanyrequests）' '③ 用盡時印 ⚠ 限流判定行（patrol 同類紅簽章，LS-392）'

run other_error; rc=$?
expect_exit 5 "$rc" '④ 非限流錯誤 → 保留原 exit code 5'
[ "$(grep -c '^db start$' "$work/calls")" -eq 1 ] && ok '④ 非限流錯誤不重試（db start 恰 1 次）' || fail '④ 非限流錯誤不應重試'
expect_not_has "$(calls)" 'sleep' '④ 非限流錯誤不 sleep'
expect_has "$(cat "$work/out")" 'failed to create docker network' '④ 原錯誤訊息保留在輸出'
expect_not_has "$(cat "$work/out")" '疑似映像限流' '④ 非限流錯誤不印 ⚠ 限流判定行（不讓 patrol 誤計成限流）'

# ④b 映像來源行（LS-392）：本次沒拉 → 「本機既有映像」；有拉（輸出含 `Pulling from`）→ 「<registry>（本次…有拉取）」
run ok
expect_has "$(cat "$work/out")" '映像來源＝本機既有映像（本次 db start 未拉取任何映像）' '④b 未拉取 → 印「映像來源＝本機既有映像」'
: > "$work/calls"
FAKE_LOG="$work/calls" FAKE_MODE=ok_pull PATH="$work/bin:$PATH" GITHUB_ACTIONS= CI= LS_DB_START_RETRY_ALLOW_LOCAL=1 \
  SUPABASE_INTERNAL_IMAGE_REGISTRY=public.ecr.aws bash "$script" > "$work/out" 2>&1; rc=$?
expect_exit 0 "$rc" '④b 有拉取仍成功 → exit 0'
expect_has "$(cat "$work/out")" '映像來源＝public.ecr.aws（本次 db start 有拉取映像）' '④b 有拉取 → 印「映像來源＝public.ecr.aws（…有拉取）」'
expect_not_has "$(cat "$work/out")" '本機既有映像' '④b 有拉取時不得說成本機既有'

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

# ⑦ mutation（LS-392）：拿掉退避 sleep → 限流持續時連打不間隔（呼叫序列不再含 sleep）
mut_b="$work/mut-backoff.sh"
grep -v '# DB-START-BACKOFF$' "$script" > "$mut_b"
if cmp -s "$script" "$mut_b"; then
  fail '⑦ mutant 沒被正確合成（DB-START-BACKOFF 行未刪到）'
else
  run limit_always "$mut_b"
  if grep -q '^sleep' "$work/calls"; then fail '⑦ mutant（拿掉退避）仍有 sleep——③ 的間隔斷言沒咬住 sleep 那行'; else ok '⑦ mutant（拿掉退避）：限流重試之間沒有 sleep——③ 的「間隔 30／60／120／240」斷言會紅'; fi
fi

# ⑧ mutation（LS-392）：拿掉 ⚠ 限流判定行 → 重試用盡時不印（③ 的 ⚠ 斷言會紅、patrol 抓不到簽章）
mut_w="$work/mut-warn.sh"
grep -v '# DB-START-LIMIT-WARN$' "$script" > "$mut_w"
if cmp -s "$script" "$mut_w"; then
  fail '⑧ mutant 沒被正確合成（DB-START-LIMIT-WARN 行未刪到）'
else
  run limit_always "$mut_w"
  if grep -qF '疑似映像限流' "$work/out"; then fail '⑧ mutant（拿掉 ⚠ 行）仍印出——③ 的 ⚠ 斷言沒咬住那行'; else ok '⑧ mutant（拿掉 ⚠ 行）：用盡時不再印「疑似映像限流」——③ 的 ⚠ 斷言會紅'; fi
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ db-start-retry 自測失敗" >&2
  exit 1
fi
echo "✓ db-start-retry 自測通過"
