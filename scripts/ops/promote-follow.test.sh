#!/bin/bash
# promote-follow.sh 的自測（LS-257）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對這支腳本也適用：若退化成 conclusion=success 卻不 promote、cancelled 但步驟未全綠
# 也自動 rerun（把真壞的誤判成逾時假紅）、真的有失敗步驟卻還 rerun（浪費一輪 CI）、rerun 後仍未綠卻
# 還是呼叫 promote.sh、或用參數解析忘記檢查數量——這裡會紅。
#
# PATH 前置一支假 bin 目錄覆蓋 gh／git／sleep／promote.sh 四個外部呼叫：
#   - git：只需支援 `rev-parse --git-dir`（回報「在 git repo 內」）與 `rev-parse origin/<from>`
#     （回固定 SHA，三情境都不需要模擬 tip 前進）、`fetch`（no-op）。
#   - gh：`run list --jq <expr>` 真的把 expr 交給 jq 對罐頭 JSON 跑（驗的是腳本自己的 jq 表達式，
#     同 promote.test.sh 既有手法）；`run view <id> --json status,conclusion,jobs` 依「該 id 是否已被
#     rerun 過」（`run rerun` 會在 $GH_STATE_DIR 留一個記號檔）回傳 before／after 兩份罐頭之一；
#     `run view <id> --job <j> --log-failed` 回罐頭 log 文字。
#   - sleep：no-op——三情境的 gh 罐頭都設計成第一次 poll 就 completed，不需要真的等，但仍樁掉以防
#     腳本任何分支不小心多繞一圈時測試被拖慢。
#   - promote.sh：記錄呼叫參數到 log 檔、exit code 由 $PROMOTE_EXIT 控制。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/promote-follow.sh"
fail=0
command -v jq >/dev/null 2>&1 || { echo "✗ promote-follow 自測需要 jq（stub gh 用它跑 --jq）" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---- 假 bin ----
bin="$work/bin"
mkdir -p "$bin" "$work/state"

cat > "$bin/git" <<'EOF'
#!/bin/bash
case "$1" in
  rev-parse)
    if [ "${2:-}" = "--git-dir" ]; then echo ".git"; exit 0; fi
    echo "${GIT_FAKE_SHA:?}"
    exit 0
    ;;
  fetch) exit 0 ;;
  *) exit 0 ;;
esac
EOF

cat > "$bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$bin/promote.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${PROMOTE_LOG:?}"
exit "${PROMOTE_EXIT:-0}"
EOF

cat > "$bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
case "$1 $2" in
  "run list")
    expr=""; prev=""
    for a in "$@"; do
      [ "$prev" = "--jq" ] && expr="$a"
      prev="$a"
    done
    if [ -n "$expr" ]; then jq -r "$expr" "${GH_RUN_LIST_JSON:?}"; else cat "${GH_RUN_LIST_JSON:?}"; fi
    ;;
  "run view")
    if printf '%s\n' "$*" | grep -q -- '--log-failed'; then
      cat "${GH_LOG_FAILED_FILE:-/dev/null}"
      exit 0
    fi
    id="$3"
    src="${GH_RUN_JSON_BEFORE:?}"
    if [ -f "${GH_STATE_DIR:?}/reran-${id}" ] && [ -n "${GH_RUN_JSON_AFTER:-}" ]; then
      src="${GH_RUN_JSON_AFTER}"
    fi
    cat "$src"
    ;;
  "run rerun")
    id="$3"
    touch "${GH_STATE_DIR:?}/reran-${id}"
    exit "${GH_RERUN_EXIT:-0}"
    ;;
esac
EOF
chmod +x "$bin/git" "$bin/sleep" "$bin/promote.sh" "$bin/gh"
export PATH="$bin:$PATH"
export GH_LOG="$work/gh.log" PROMOTE_LOG="$work/promote.log" GH_STATE_DIR="$work/state"
export GIT_FAKE_SHA="feedbee0f00dfeedbee0f00dfeedbee0f00dfeed"

has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
reset_all() {
  : > "$GH_LOG"; : > "$PROMOTE_LOG"; rm -rf "$GH_STATE_DIR"; mkdir -p "$GH_STATE_DIR"
  unset PROMOTE_EXIT GH_RERUN_EXIT GH_RUN_JSON_AFTER GH_LOG_FAILED_FILE
}

# ---- ① 缺參數 → exit 2、不呼叫 gh／git ----
reset_all
out="$(bash "$script" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -s "$GH_LOG" ]; then
  echo "✓ ① 缺參數 → exit 2、不呼叫 gh"
else
  echo "✗ ① 缺參數應 exit 2 且不呼叫 gh（實得 exit ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ② run success → 直接 promote，不 rerun ----
reset_all
printf '[{"databaseId":1001,"event":"push","createdAt":"2026-09-13T00:00:00Z"}]' > "$work/list-a.json"
printf '{"status":"completed","conclusion":"success","jobs":[{"databaseId":1,"conclusion":"success","steps":[{"conclusion":"success"},{"conclusion":"success"}]}]}' > "$work/run-a.json"
out="$(GH_RUN_LIST_JSON="$work/list-a.json" GH_RUN_JSON_BEFORE="$work/run-a.json" bash "$script" development test 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ② run success → exit 0"; else echo "✗ ② run success 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
has '② 有呼叫 promote.sh development test' "$(cat "$PROMOTE_LOG")" 'development test'
if grep -q '^run rerun' "$GH_LOG"; then echo "✗ ② 不應呼叫 gh run rerun（但 log 有）" >&2; fail=1; else echo "✓ ② 不呼叫 gh run rerun"; fi
has '② 摘要印 promoted' "$out" '✓ promoted development→test'

# ---- ③ run cancelled 且所有步驟 success/skipped → 自動 rerun 一次 → 轉 success → promote ----
reset_all
printf '[{"databaseId":1002,"event":"push","createdAt":"2026-09-13T00:00:00Z"}]' > "$work/list-b.json"
printf '{"status":"completed","conclusion":"cancelled","jobs":[{"databaseId":2,"conclusion":"cancelled","steps":[{"conclusion":"success"},{"conclusion":"success"},{"conclusion":"success"}]}]}' > "$work/run-b-before.json"
printf '{"status":"completed","conclusion":"success","jobs":[{"databaseId":2,"conclusion":"success","steps":[{"conclusion":"success"},{"conclusion":"success"},{"conclusion":"success"}]}]}' > "$work/run-b-after.json"
out="$(GH_RUN_LIST_JSON="$work/list-b.json" GH_RUN_JSON_BEFORE="$work/run-b-before.json" GH_RUN_JSON_AFTER="$work/run-b-after.json" bash "$script" development test 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ③ cancelled 全綠 → rerun 後 success → exit 0"; else echo "✗ ③ 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
has '③ 有呼叫 gh run rerun 1002 --failed' "$(cat "$GH_LOG")" 'run rerun 1002 --failed'
has '③ rerun 後有呼叫 promote.sh' "$(cat "$PROMOTE_LOG")" 'development test'
has '③ 摘要印「假紅」rerun 說明' "$out" 'timeout-minutes 的假紅'

# ---- ④ 真紅（有 failure 步驟）→ 不 rerun，直接印摘要退出、不呼叫 promote.sh ----
reset_all
printf '[{"databaseId":1003,"event":"push","createdAt":"2026-09-13T00:00:00Z"}]' > "$work/list-c.json"
printf '{"status":"completed","conclusion":"failure","jobs":[{"databaseId":3,"conclusion":"failure","steps":[{"conclusion":"success"},{"conclusion":"failure"}]}]}' > "$work/run-c.json"
printf "/repo/LittleSproutTests/FooTests.swift:12: error: -[LittleSproutTests.FooTests testBar] : failed - 斷言不符\nTest Case '-[LittleSproutTests.FooTests testBar]' failed (0.3 seconds).\n" > "$work/log-c.txt"
out="$(GH_RUN_LIST_JSON="$work/list-c.json" GH_RUN_JSON_BEFORE="$work/run-c.json" GH_LOG_FAILED_FILE="$work/log-c.txt" bash "$script" development test 2>&1)"; rc=$?
if [ "$rc" -eq 3 ]; then echo "✓ ④ 真紅 → exit 3"; else echo "✗ ④ 真紅應 exit 3（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
if grep -q '^run rerun' "$GH_LOG"; then echo "✗ ④ 不應呼叫 gh run rerun（但 log 有）" >&2; fail=1; else echo "✓ ④ 不呼叫 gh run rerun"; fi
if [ -s "$PROMOTE_LOG" ]; then echo "✗ ④ 真紅不應呼叫 promote.sh（但 log 非空）" >&2; cat "$PROMOTE_LOG" >&2; fail=1; else echo "✓ ④ 真紅不呼叫 promote.sh"; fi
has '④ 印失敗 job' "$out" '失敗 job：3'
has '④ 印 Test Case failed 摘要' "$out" "Test Case '-[LittleSproutTests.FooTests testBar]' failed"

# ---- ⑤ cancelled 但步驟不是全綠（例如最後一步真的被腰斬、conclusion 是 null／cancelled，不是
#    success）→ 不符合「純逾時假紅」的形狀，不 rerun，直接退出（對應 LS-257 來源 comment
#    d9e71952 的第 3 次事故：test push run「最後一步『點擊目標 gate』未完成」，當時是人工判斷
#    不能盲目 rerun）。
reset_all
printf '[{"databaseId":1004,"event":"push","createdAt":"2026-09-13T00:00:00Z"}]' > "$work/list-d.json"
printf '{"status":"completed","conclusion":"cancelled","jobs":[{"databaseId":4,"conclusion":"cancelled","steps":[{"conclusion":"success"},{"conclusion":null}]}]}' > "$work/run-d.json"
out="$(GH_RUN_LIST_JSON="$work/list-d.json" GH_RUN_JSON_BEFORE="$work/run-d.json" bash "$script" development test 2>&1)"; rc=$?
if [ "$rc" -eq 3 ]; then echo "✓ ⑤ cancelled 但步驟未全綠 → exit 3"; else echo "✗ ⑤ 應 exit 3（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
if grep -q '^run rerun' "$GH_LOG"; then echo "✗ ⑤ 不應呼叫 gh run rerun（步驟未全綠不符合假紅資格，但 log 有）" >&2; fail=1; else echo "✓ ⑤ 不呼叫 gh run rerun（未全綠不自動 rerun）"; fi
if [ -s "$PROMOTE_LOG" ]; then echo "✗ ⑤ 不應呼叫 promote.sh（但 log 非空）" >&2; cat "$PROMOTE_LOG" >&2; fail=1; else echo "✓ ⑤ 不呼叫 promote.sh"; fi

if [ "$fail" -eq 0 ]; then
  echo "✓ promote-follow.test.sh 全部通過"
else
  echo "✗ promote-follow.test.sh 有案例失敗" >&2
fi
exit "$fail"
