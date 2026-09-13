#!/bin/bash
# promote-follow.sh 的自測（LS-257）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對這支腳本也適用：若退化成 conclusion=success 卻不 promote、有 failure 步驟也自動
# rerun（把真壞的誤判成逾時假紅）、cancelled 且真的有 failure 步驟卻還 rerun、rerun 後在新 attempt
# 尚未出現前就對舊 attempt 的 completed／cancelled 下判決、rerun 後仍未綠卻還是呼叫 promote.sh、或用
# 參數解析忘記檢查數量——這裡會紅。
#
# R1 merge-review 訂正（M1／M2／m3）：
#   - M1：資格判準原為「所有 job 的所有 steps 皆 success／skipped」，對本票三次真實事故裡的兩次
#     （main `34755219511`／test `34757987069`，撞 timeout 當下「點擊目標 gate」正在跑、被 GitHub 記成
#     `cancelled`）誤判為不合格，票要解決的主場景反而漏了 2/3。腳本已訂正為「沒有任何 failure／
#     timed_out 步驟」，本檔案的 ⑤ 直接用三次事故其中一次（main/test 同形狀）的真實 step conclusion
#     序列當 fixture，斷言**會**自動 rerun。
#   - M2：rerun 後第一次 poll 沒有等待、也沒有辨識 attempt，可能讀到舊 attempt 的結論就誤判。腳本已
#     訂正為先等 `attempt` 前進且 status≠completed；⑥ 用「舊 attempt 仍 cancelled、新 attempt 才
#     success」的三段序列驗證不會提早誤判 exit 3。
#   - m3：`promote_sh()` 原本用 `command -v promote.sh`（PATH 劫持風險），改用 `PROMOTE_SH` 環境變數
#     seam；本檔案改設該變數指向假腳本，不再把假 promote.sh 放進 PATH。
#
# PATH 前置一支假 bin 目錄覆蓋 gh／git／sleep 三個外部呼叫：
#   - git：只需支援 `rev-parse --git-dir`（回報「在 git repo 內」）與 `rev-parse origin/<from>`
#     （回固定 SHA，各情境都不需要模擬 tip 前進）、`fetch`（no-op）。
#   - gh：`run list --jq <expr>` 真的把 expr 交給 jq 對罐頭 JSON 跑（驗的是腳本自己的 jq 表達式，同
#     promote.test.sh 既有手法）；`run view <id> --json … --attempt` 用 `$GH_RUN_JSON_SEQUENCE`
#     （空白分隔的罐頭 JSON 檔案路徑清單）依「這是第幾次呼叫」回對應的一份，序列用完後停在最後一份
#     （模擬狀態隨時間推進、一次驗證一個時序而非只驗證單一快照）；`run view <id> --job <j>
#     --log-failed` 回罐頭 log 文字；`run rerun <id> --failed` 記一筆 log。
#   - sleep：no-op——所有情境的 gh 罐頭序列都設計成有限次數內收斂，不需要真的等，但仍樁掉以防任何
#     分支不小心多繞一圈時測試被拖慢。
# promote.sh 用 `$PROMOTE_SH` 環境變數指向假腳本（見 m3），不經 PATH。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/promote-follow.sh"
fail=0
command -v jq >/dev/null 2>&1 || { echo "✗ promote-follow 自測需要 jq（stub gh 用它跑 --jq）" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---- 假 bin（不含 promote.sh——見 m3，改用 PROMOTE_SH 環境變數）----
bin="$work/bin"
mkdir -p "$bin" "$work/state" "$work/fixtures"

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

cat > "$work/promote.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${PROMOTE_LOG:?}"
exit "${PROMOTE_EXIT:-0}"
EOF
chmod +x "$work/promote.sh"

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
    cnt_file="${GH_STATE_DIR:?}/viewcount"
    n=0
    [ -f "$cnt_file" ] && n=$(cat "$cnt_file")
    n=$((n + 1))
    echo "$n" > "$cnt_file"
    chosen=""
    i=0
    for f in ${GH_RUN_JSON_SEQUENCE:?}; do
      i=$((i + 1))
      chosen="$f"
      [ "$i" -ge "$n" ] && break
    done
    cat "$chosen"
    ;;
  "run rerun")
    id="$3"
    touch "${GH_STATE_DIR:?}/reran-${id}"
    exit "${GH_RERUN_EXIT:-0}"
    ;;
esac
EOF
chmod +x "$bin/git" "$bin/sleep" "$bin/gh"
export PATH="$bin:$PATH"
export GH_LOG="$work/gh.log" PROMOTE_LOG="$work/promote.log" GH_STATE_DIR="$work/state" PROMOTE_SH="$work/promote.sh"
export GIT_FAKE_SHA="feedbee0f00dfeedbee0f00dfeedbee0f00dfeed"

has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
reset_all() {
  : > "$GH_LOG"; : > "$PROMOTE_LOG"; rm -rf "$GH_STATE_DIR"; mkdir -p "$GH_STATE_DIR"
  unset PROMOTE_EXIT GH_RERUN_EXIT GH_LOG_FAILED_FILE GH_RUN_JSON_SEQUENCE
}
# fx <名稱> <JSON> → 落一個罐頭檔到 $work/fixtures/<名稱>.json，印路徑（供組 GH_RUN_JSON_SEQUENCE 用）
fx() {
  printf '%s' "$2" > "$work/fixtures/$1.json"
  echo "$work/fixtures/$1.json"
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
a=$(fx a-success '{"status":"completed","conclusion":"success","attempt":1,"jobs":[{"databaseId":1,"conclusion":"success","steps":[{"conclusion":"success"},{"conclusion":"success"}]}]}')
out="$(GH_RUN_LIST_JSON="$work/list-a.json" GH_RUN_JSON_SEQUENCE="$a" bash "$script" development test 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ② run success → exit 0"; else echo "✗ ② run success 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
has '② 有呼叫 promote.sh development test' "$(cat "$PROMOTE_LOG")" 'development test'
if grep -q '^run rerun' "$GH_LOG"; then echo "✗ ② 不應呼叫 gh run rerun（但 log 有）" >&2; fail=1; else echo "✓ ② 不呼叫 gh run rerun"; fi
has '② 摘要印 promoted' "$out" '✓ promoted development→test'

# ---- ③ run cancelled 且無 failure 步驟 → 自動 rerun 一次 → 轉 success → promote ----
reset_all
printf '[{"databaseId":1002,"event":"push","createdAt":"2026-09-13T00:00:00Z"}]' > "$work/list-b.json"
b1=$(fx b-cancelled '{"status":"completed","conclusion":"cancelled","attempt":1,"jobs":[{"databaseId":2,"conclusion":"cancelled","steps":[{"conclusion":"success"},{"conclusion":"success"},{"conclusion":"success"}]}]}')
b2=$(fx b-success '{"status":"completed","conclusion":"success","attempt":2,"jobs":[{"databaseId":2,"conclusion":"success","steps":[{"conclusion":"success"},{"conclusion":"success"},{"conclusion":"success"}]}]}')
out="$(GH_RUN_LIST_JSON="$work/list-b.json" GH_RUN_JSON_SEQUENCE="$b1 $b2" bash "$script" development test 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ③ cancelled 無 failure 步驟 → rerun 後 success → exit 0"; else echo "✗ ③ 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
has '③ 有呼叫 gh run rerun 1002 --failed' "$(cat "$GH_LOG")" 'run rerun 1002 --failed'
has '③ rerun 後有呼叫 promote.sh' "$(cat "$PROMOTE_LOG")" 'development test'
has '③ 摘要印「假紅」rerun 說明' "$out" 'timeout-minutes 的假紅'

# ---- ④ 真紅（有 failure 步驟）→ 不 rerun，直接印摘要退出、不呼叫 promote.sh ----
reset_all
printf '[{"databaseId":1003,"event":"push","createdAt":"2026-09-13T00:00:00Z"}]' > "$work/list-c.json"
c=$(fx c-failure '{"status":"completed","conclusion":"failure","attempt":1,"jobs":[{"databaseId":3,"conclusion":"failure","steps":[{"conclusion":"success"},{"conclusion":"failure"}]}]}')
printf "/repo/LittleSproutTests/FooTests.swift:12: error: -[LittleSproutTests.FooTests testBar] : failed - 斷言不符\nTest Case '-[LittleSproutTests.FooTests testBar]' failed (0.3 seconds).\n" > "$work/log-c.txt"
out="$(GH_RUN_LIST_JSON="$work/list-c.json" GH_RUN_JSON_SEQUENCE="$c" GH_LOG_FAILED_FILE="$work/log-c.txt" bash "$script" development test 2>&1)"; rc=$?
if [ "$rc" -eq 3 ]; then echo "✓ ④ 真紅 → exit 3"; else echo "✗ ④ 真紅應 exit 3（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
if grep -q '^run rerun' "$GH_LOG"; then echo "✗ ④ 不應呼叫 gh run rerun（但 log 有）" >&2; fail=1; else echo "✓ ④ 不呼叫 gh run rerun"; fi
if [ -s "$PROMOTE_LOG" ]; then echo "✗ ④ 真紅不應呼叫 promote.sh（但 log 非空）" >&2; cat "$PROMOTE_LOG" >&2; fail=1; else echo "✓ ④ 真紅不呼叫 promote.sh"; fi
has '④ 印失敗 job' "$out" '失敗 job：3'
has '④ 印 Test Case failed 摘要' "$out" "Test Case '-[LittleSproutTests.FooTests testBar]' failed"

# ---- ⑤ M1：本票真實事故形狀（main `34755219511`／test `34757987069` attempt 1 的 ci job steps；
#    `gh api repos/CLYEH/little-sprout/actions/runs/34755219511/attempts/1/jobs` 實測取得：9 個步驟中
#    第 8 個「點擊目標 gate」＝cancelled、其餘 success／skipped，沒有任何 failure）→ 仍應自動 rerun ----
reset_all
printf '[{"databaseId":1004,"event":"push","createdAt":"2026-09-13T00:00:00Z"}]' > "$work/list-d.json"
d1=$(fx d-incident '{
  "status": "completed", "conclusion": "cancelled", "attempt": 1,
  "jobs": [{"databaseId": 4, "conclusion": "cancelled", "steps": [
    {"number": 1, "name": "Set up job", "conclusion": "success"},
    {"number": 2, "name": "Run actions/checkout@v4", "conclusion": "success"},
    {"number": 3, "name": "xcode-select", "conclusion": "success"},
    {"number": 4, "name": "XcodeGen 漂移檢查", "conclusion": "success"},
    {"number": 5, "name": "Build & Test", "conclusion": "success"},
    {"number": 6, "name": "上傳測試失敗 xcresult（Build & Test）", "conclusion": "skipped"},
    {"number": 7, "name": "Release 組態編譯 gate", "conclusion": "success"},
    {"number": 8, "name": "點擊目標 gate", "conclusion": "cancelled"},
    {"number": 9, "name": "上傳測試失敗 xcresult（點擊目標 gate）", "conclusion": "skipped"}
  ]}]
}')
d2=$(fx d-success '{"status":"completed","conclusion":"success","attempt":2,"jobs":[{"databaseId":4,"conclusion":"success","steps":[{"conclusion":"success"}]}]}')
out="$(GH_RUN_LIST_JSON="$work/list-d.json" GH_RUN_JSON_SEQUENCE="$d1 $d2" bash "$script" development test 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ⑤ 真實事故形狀（cancelled，「點擊目標 gate」步驟本身也是 cancelled、其餘皆綠）→ 自動 rerun → success → exit 0"; else echo "✗ ⑤ 應 exit 0（實得 ${rc}）——M1 訂正未生效" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
has '⑤ 有呼叫 gh run rerun 1004 --failed（本票主場景：M1 訂正前這裡會誤判不 rerun）' "$(cat "$GH_LOG")" 'run rerun 1004 --failed'
has '⑤ rerun 後有呼叫 promote.sh' "$(cat "$PROMOTE_LOG")" 'development test'

# ---- ⑥ M2：rerun 後第一次讀到的仍是舊 attempt 的 completed／cancelled（stale），要等新 attempt
#    真的出現且 status≠completed 才開始跟完成輪詢，不能提早把 stale 讀值當成「rerun 後仍未綠」誤判
#    exit 3。序列：call1＝舊 attempt cancelled（觸發 rerun）→ call2＝仍是舊 attempt cancelled
#    （stale，M2 訂正前會被誤判）→ call3＝新 attempt in_progress（等待迴圈在這裡才該判「已開始」）
#    → call4＝新 attempt completed success ----
reset_all
printf '[{"databaseId":1005,"event":"push","createdAt":"2026-09-13T00:00:00Z"}]' > "$work/list-e.json"
e_stale=$(fx e-stale '{"status":"completed","conclusion":"cancelled","attempt":1,"jobs":[{"databaseId":5,"conclusion":"cancelled","steps":[{"conclusion":"success"}]}]}')
e_inprogress=$(fx e-inprogress '{"status":"in_progress","conclusion":null,"attempt":2,"jobs":[{"databaseId":5,"conclusion":null,"steps":[{"conclusion":"success"}]}]}')
e_success=$(fx e-success '{"status":"completed","conclusion":"success","attempt":2,"jobs":[{"databaseId":5,"conclusion":"success","steps":[{"conclusion":"success"}]}]}')
out="$(GH_RUN_LIST_JSON="$work/list-e.json" GH_RUN_JSON_SEQUENCE="$e_stale $e_stale $e_inprogress $e_success" bash "$script" development test 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ ⑥ rerun 後 stale attempt 讀值不誤判，等到新 attempt 才判定 → exit 0"; else echo "✗ ⑥ 應 exit 0（實得 ${rc}）——M2 訂正未生效，可能提早誤判 exit 3" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
has '⑥ 有呼叫 gh run rerun 1005 --failed' "$(cat "$GH_LOG")" 'run rerun 1005 --failed'
has '⑥ 摘要印「新 attempt」已開始的訊息（證明真的等到了才往下跟，不是巧合綠）' "$out" 'rerun 後新 attempt=2'
has '⑥ 最終有呼叫 promote.sh（沒有卡在中途 exit 3）' "$(cat "$PROMOTE_LOG")" 'development test'

if [ "$fail" -eq 0 ]; then
  echo "✓ promote-follow.test.sh 全部通過"
else
  echo "✗ promote-follow.test.sh 有案例失敗" >&2
fi
exit "$fail"
