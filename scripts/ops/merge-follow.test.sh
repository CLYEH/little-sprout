#!/bin/bash
# merge-follow.sh 的自測（LS-291）。CI rules job 跑。掛 selftest-wiring-check.sh。
# 「前饋必有反饋」對這支腳本也適用：若 RED 仍 merge、cancelled 真的有失敗步驟卻還 rerun、
# rerun 只做一次的上限被拿掉、DIRTY 仍往下等而不是直接退出、base tip 不核對 mergeCommit 就貼
# status、或 `--backmerge` 沒開出第二支 PR 就當完成——這裡會紅。
#
# PATH 前置一支假 bin 覆蓋 gh／git／sleep；`post-status.sh`／`pr-body-check.sh`／`promote-follow.sh`
# 三個外部呼叫改用環境變數 seam（`POST_STATUS_SH`／`PR_BODY_CHECK_SH`／`PROMOTE_FOLLOW_SH`，同
# `promote-follow.sh` 的 `PROMOTE_SH` 手法，不劫持 PATH 上的同名腳本）指向假腳本：
#   - `gh pr view <pr> --json …`：依「這是第幾次呼叫」從 `GH_PR_VIEW_SEQUENCE`（空白分隔的罐頭 JSON
#     路徑清單）回對應一份，序列用完後停在最後一份（同 promote-follow.test.sh 的 GH_RUN_JSON_SEQUENCE
#     手法，一次驗證一段時序）。
#   - `gh pr checks <pr> --json name,bucket`：同手法，`GH_PR_CHECKS_SEQUENCE`。
#   - `gh pr merge <pr> --merge`：記一筆 log，exit `${GH_PR_MERGE_EXIT:-0}`。
#   - `gh run list … --jq <expr>`：真的把 expr 交給 jq 對 `GH_RUN_LIST_JSON` 跑（驗腳本自己的 jq 運算式）。
#   - `gh run view <id> --json …`：回 `GH_RUN_VIEW_JSON`。
#   - `gh run rerun <id> --failed`：記一筆 log，exit `${GH_RUN_RERUN_EXIT:-0}`。
#   - `gh pr list --head main --base development …`：回 `GH_PR_LIST_JSON`（`--backmerge` 沿用既有 PR 用）。
#   - `gh pr create …`：記一筆 log，印 `GH_PR_CREATE_OUTPUT`（含 PR 號好讓腳本 grep 出來），exit
#     `${GH_PR_CREATE_EXIT:-0}`。
#   - `git rev-parse --git-dir`／`origin/<branch>`（回 `GIT_FAKE_TIP`）／`fetch`（no-op）／
#     `log -1 --format=%P <tip>`（回 `GIT_FAKE_PARENTS`，「parent1 parent2」）。
#   - `sleep`：no-op（所有情境的罐頭序列都設計成有限次數內收斂）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/merge-follow.sh"
fail=0

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP merge-follow 自測（無 jq）：stub gh 需要 jq 跑 --jq 表達式與罐頭 JSON 解析，整支未跑"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

bin="$work/bin"
mkdir -p "$bin" "$work/state" "$work/fixtures"

cat > "$bin/git" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "rev-parse --git-dir") echo ".git"; exit 0 ;;
esac
case "$1" in
  rev-parse)
    case "${2:-}" in
      origin/*) echo "${GIT_FAKE_TIP:?}"; exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  fetch) exit 0 ;;
  log) echo "${GIT_FAKE_PARENTS:?}"; exit 0 ;;
  *) exit 0 ;;
esac
EOF

cat > "$bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$work/post-status.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${POST_STATUS_LOG:?}"
exit "${POST_STATUS_EXIT:-0}"
EOF
chmod +x "$work/post-status.sh"

cat > "$work/pr-body-check.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${PR_BODY_CHECK_LOG:?}"
exit "${PR_BODY_CHECK_EXIT:-2}"
EOF
chmod +x "$work/pr-body-check.sh"

cat > "$work/promote-follow.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${PROMOTE_FOLLOW_LOG:?}"
exit "${PROMOTE_FOLLOW_EXIT:-0}"
EOF
chmod +x "$work/promote-follow.sh"

cat > "$bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
seq_pick_file() {  # $1=狀態檔名（在 GH_STATE_DIR 下） $2=罐頭清單（空白分隔）→ 印選中的檔案路徑
  local cnt_file="${GH_STATE_DIR:?}/$1" seqvar=$2 n chosen i
  n=0
  [ -f "$cnt_file" ] && n=$(cat "$cnt_file")
  n=$((n + 1))
  echo "$n" > "$cnt_file"
  chosen=""
  i=0
  for f in $seqvar; do
    i=$((i + 1))
    chosen="$f"
    [ "$i" -ge "$n" ] && break
  done
  printf '%s' "$chosen"
}
apply_q() {  # $1=罐頭檔 "$@"=原始呼叫參數 → 有 -q <expr> 就 jq -r 之，否則整份 cat
  local file=$1; shift
  local expr="" prev=""
  for a in "$@"; do
    [ "$prev" = "-q" ] && expr="$a"
    prev="$a"
  done
  if [ -n "$expr" ]; then jq -r "$expr" "$file"; else cat "$file"; fi
}
case "$1 $2" in
  "pr view")
    f=$(seq_pick_file viewcount "${GH_PR_VIEW_SEQUENCE:?}")
    apply_q "$f" "$@"
    ;;
  "pr checks")
    f=$(seq_pick_file checkscount "${GH_PR_CHECKS_SEQUENCE:?}")
    cat "$f"
    ;;
  "pr merge")
    exit "${GH_PR_MERGE_EXIT:-0}"
    ;;
  "pr list")
    apply_q "${GH_PR_LIST_JSON:?}" "$@"
    ;;
  "pr create")
    echo "${GH_PR_CREATE_OUTPUT:-https://github.com/o/r/pull/999}"
    exit "${GH_PR_CREATE_EXIT:-0}"
    ;;
  "run list")
    expr=""; prev=""
    for a in "$@"; do
      [ "$prev" = "--jq" ] && expr="$a"
      prev="$a"
    done
    if [ -n "$expr" ]; then jq -r "$expr" "${GH_RUN_LIST_JSON:?}"; else cat "${GH_RUN_LIST_JSON:?}"; fi
    ;;
  "run view")
    cat "${GH_RUN_VIEW_JSON:?}"
    ;;
  "run rerun")
    id="$3"
    touch "${GH_STATE_DIR:?}/reran-${id}"
    exit "${GH_RUN_RERUN_EXIT:-0}"
    ;;
esac
EOF
chmod +x "$bin/git" "$bin/sleep" "$bin/gh"
export PATH="$bin:$PATH"

has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
empty() { if [ -s "$2" ]; then echo "✗ ${1}（${2} 應為空但非空）" >&2; cat "$2" >&2; fail=1; else echo "✓ $1"; fi; }

reset_all() {
  : > "$GH_LOG"; : > "$POST_STATUS_LOG"; : > "$PR_BODY_CHECK_LOG"; : > "$PROMOTE_FOLLOW_LOG"
  rm -rf "$GH_STATE_DIR"; mkdir -p "$GH_STATE_DIR"
  unset GH_PR_VIEW_SEQUENCE GH_PR_CHECKS_SEQUENCE GH_PR_MERGE_EXIT GH_RUN_LIST_JSON GH_RUN_VIEW_JSON \
        GH_RUN_RERUN_EXIT GH_PR_LIST_JSON GH_PR_CREATE_OUTPUT GH_PR_CREATE_EXIT POST_STATUS_EXIT \
        PR_BODY_CHECK_EXIT PROMOTE_FOLLOW_EXIT
}
fx() { printf '%s' "$2" > "$work/fixtures/$1.json"; echo "$work/fixtures/$1.json"; }

export GH_LOG="$work/gh.log" POST_STATUS_LOG="$work/post-status.log" PR_BODY_CHECK_LOG="$work/pr-body-check.log" \
       PROMOTE_FOLLOW_LOG="$work/promote-follow.log" GH_STATE_DIR="$work/state" \
       POST_STATUS_SH="$work/post-status.sh" PR_BODY_CHECK_SH="$work/pr-body-check.sh" PROMOTE_FOLLOW_SH="$work/promote-follow.sh" \
       GIT_FAKE_TIP="1111111111111111111111111111111111aaaa" \
       GIT_FAKE_PARENTS="0000000000000000000000000000000000base 2222222222222222222222222222222222head"

# ---- ① 缺參數 → exit 2、不呼叫 gh ----
reset_all
out="$(bash "$script" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -s "$GH_LOG" ]; then echo "✓ ① 缺參數 → exit 2、不呼叫 gh"
else echo "✗ ① 缺參數應 exit 2 且不呼叫 gh（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

# ---- (a) checks 綠 → CLEAN → merge → 核對 mergeCommit → 貼 status ----
reset_all
v_open=$(fx a-view-open '{"state":"OPEN","mergeStateStatus":"BLOCKED","baseRefName":"development","headRefName":"feature/LS-1-x","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mergeCommit":null}')
v_clean=$(fx a-view-clean '{"state":"OPEN","mergeStateStatus":"CLEAN","baseRefName":"development","headRefName":"feature/LS-1-x","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mergeCommit":null}')
v_after=$(fx a-view-after '{"state":"MERGED","mergeStateStatus":"CLEAN","baseRefName":"development","headRefName":"feature/LS-1-x","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mergeCommit":{"oid":"1111111111111111111111111111111111aaaa"}}')
c_pass=$(fx a-checks-pass '[{"name":"ci","bucket":"pass"},{"name":"lint","bucket":"pass"}]')
out="$(GH_PR_VIEW_SEQUENCE="$v_open $v_open $v_clean $v_after" GH_PR_CHECKS_SEQUENCE="$c_pass" \
      bash "$script" 501 --rid abcd1234ef 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ (a) checks 綠 → exit 0"; else echo "✗ (a) 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
has '(a) 有呼叫 gh pr merge 501 --merge' "$(cat "$GH_LOG")" 'pr merge 501 --merge'
has '(a) post-status 貼在 GIT_FAKE_TIP、context merge-review success' "$(cat "$POST_STATUS_LOG")" "${GIT_FAKE_TIP} merge-review success"
has '(a) desc 含 PR 號與 rid 前 8 碼' "$(cat "$POST_STATUS_LOG")" '#501'
has '(a) desc 含 rid 前 8 碼' "$(cat "$POST_STATUS_LOG")" 'abcd1234'
has '(a) --expect 帶 GIT_FAKE_TIP' "$(cat "$POST_STATUS_LOG")" "--expect ${GIT_FAKE_TIP}"
if grep -q '^run rerun' "$GH_LOG"; then echo "✗ (a) 不應呼叫 gh run rerun" >&2; fail=1; else echo "✓ (a) 不呼叫 gh run rerun"; fi
has '(a) 摘要印 merged' "$out" "✓ merged #501 → development"

# ---- (b) cancelled 無 failure 步驟 → rerun 一次 → 轉綠 → merge ----
reset_all
v_open=$(fx b-view-open '{"state":"OPEN","mergeStateStatus":"BLOCKED","baseRefName":"development","headRefName":"fix/LS-2-y","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","mergeCommit":null}')
v_clean=$(fx b-view-clean '{"state":"OPEN","mergeStateStatus":"CLEAN","baseRefName":"development","headRefName":"fix/LS-2-y","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","mergeCommit":null}')
v_after=$(fx b-view-after '{"state":"MERGED","mergeStateStatus":"CLEAN","baseRefName":"development","headRefName":"fix/LS-2-y","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","mergeCommit":{"oid":"1111111111111111111111111111111111aaaa"}}')
c_cancel=$(fx b-checks-cancel '[{"name":"ci","bucket":"cancel"},{"name":"lint","bucket":"pass"}]')
c_pass=$(fx b-checks-pass '[{"name":"ci","bucket":"pass"},{"name":"lint","bucket":"pass"}]')
list_run=$(fx b-run-list '[{"databaseId":7001,"event":"pull_request","createdAt":"2026-09-15T00:00:00Z"}]')
run_cancel=$(fx b-run-cancel '{"status":"completed","conclusion":"cancelled","attempt":1,"jobs":[{"databaseId":1,"conclusion":"cancelled","steps":[{"conclusion":"success"},{"conclusion":"cancelled"}]}]}')
out="$(GH_PR_VIEW_SEQUENCE="$v_open $v_open $v_open $v_clean $v_after" GH_PR_CHECKS_SEQUENCE="$c_cancel" \
      GH_RUN_LIST_JSON="$list_run" GH_RUN_VIEW_JSON="$run_cancel" \
      bash "$script" 502 --note "手動 note" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ (b) cancelled 無 failure 步驟 → rerun 後綠 → exit 0"; else echo "✗ (b) 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
has '(b) 有呼叫 gh run rerun 7001 --failed' "$(cat "$GH_LOG")" 'run rerun 7001 --failed'
has '(b) rerun 後有呼叫 gh pr merge 502' "$(cat "$GH_LOG")" 'pr merge 502 --merge'
has '(b) 摘要印「假紅」rerun 說明' "$out" 'LS-257 判準的假紅'
has '(b) post-status 貼上手動 note' "$(cat "$POST_STATUS_LOG")" '手動 note'

# ---- (c) 真紅（fail bucket）→ 不 rerun，直接退出、不 merge ----
reset_all
v_open=$(fx c-view-open '{"state":"OPEN","mergeStateStatus":"BLOCKED","baseRefName":"development","headRefName":"fix/LS-3-z","headRefOid":"cccccccccccccccccccccccccccccccccccccc","mergeCommit":null}')
c_fail=$(fx c-checks-fail '[{"name":"ci","bucket":"fail"},{"name":"lint","bucket":"pass"}]')
out="$(GH_PR_VIEW_SEQUENCE="$v_open" GH_PR_CHECKS_SEQUENCE="$c_fail" bash "$script" 503 --note x 2>&1)"; rc=$?
if [ "$rc" -eq 3 ]; then echo "✓ (c) 真紅 → exit 3"; else echo "✗ (c) 真紅應 exit 3（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
if grep -q '^run rerun' "$GH_LOG"; then echo "✗ (c) 不應呼叫 gh run rerun" >&2; fail=1; else echo "✓ (c) 不呼叫 gh run rerun"; fi
if grep -q '^pr merge' "$GH_LOG"; then echo "✗ (c) 真紅不應呼叫 gh pr merge" >&2; fail=1; else echo "✓ (c) 真紅不呼叫 gh pr merge"; fi
empty '(c) post-status 未被呼叫' "$POST_STATUS_LOG"
has '(c) 印失敗 check 名稱' "$out" 'checks 紅：ci'
has '(c) 印續接指令' "$out" '續接：bash scripts/ops/merge-follow.sh 503 --note x'

# ---- (c2) DIRTY → exit 4，不查 checks、不 merge ----
reset_all
v_dirty=$(fx c2-view-dirty '{"state":"OPEN","mergeStateStatus":"DIRTY","baseRefName":"development","headRefName":"fix/LS-4-w","headRefOid":"dddddddddddddddddddddddddddddddddddddddd","mergeCommit":null}')
out="$(GH_PR_VIEW_SEQUENCE="$v_dirty" bash "$script" 504 --note x 2>&1)"; rc=$?
if [ "$rc" -eq 4 ]; then echo "✓ (c2) DIRTY → exit 4"; else echo "✗ (c2) 應 exit 4（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
if grep -q 'pr checks' "$GH_LOG"; then echo "✗ (c2) DIRTY 不應查 checks" >&2; fail=1; else echo "✓ (c2) DIRTY 不查 checks"; fi

# ---- (d) --backmerge：主 PR 併入 main → 開／併 back-merge main→development ----
reset_all
v_open=$(fx d-view-open '{"state":"OPEN","mergeStateStatus":"BLOCKED","baseRefName":"main","headRefName":"hotfix/LS-291-merge-follow-script","headRefOid":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","mergeCommit":null}')
v_clean=$(fx d-view-clean '{"state":"OPEN","mergeStateStatus":"CLEAN","baseRefName":"main","headRefName":"hotfix/LS-291-merge-follow-script","headRefOid":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","mergeCommit":null}')
v_after=$(fx d-view-after '{"state":"MERGED","mergeStateStatus":"CLEAN","baseRefName":"main","headRefName":"hotfix/LS-291-merge-follow-script","headRefOid":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","mergeCommit":{"oid":"1111111111111111111111111111111111aaaa"}}')
bm_open=$(fx d-bm-view-open '{"state":"OPEN","mergeStateStatus":"BLOCKED","baseRefName":"development","headRefName":"main","headRefOid":"ffffffffffffffffffffffffffffffffffffffff","mergeCommit":null}')
bm_clean=$(fx d-bm-view-clean '{"state":"OPEN","mergeStateStatus":"CLEAN","baseRefName":"development","headRefName":"main","headRefOid":"ffffffffffffffffffffffffffffffffffffffff","mergeCommit":null}')
bm_after=$(fx d-bm-view-after '{"state":"MERGED","mergeStateStatus":"CLEAN","baseRefName":"development","headRefName":"main","headRefOid":"ffffffffffffffffffffffffffffffffffffffff","mergeCommit":{"oid":"1111111111111111111111111111111111aaaa"}}')
c_pass=$(fx d-checks-pass '[{"name":"ci","bucket":"pass"}]')
pr_list_empty=$(fx d-pr-list-empty '[]')
out="$(GH_PR_VIEW_SEQUENCE="$v_open $v_open $v_clean $v_after $bm_open $bm_clean $bm_after" \
      GH_PR_CHECKS_SEQUENCE="$c_pass" GH_PR_LIST_JSON="$pr_list_empty" \
      GH_PR_CREATE_OUTPUT="https://github.com/o/r/pull/601" \
      bash "$script" 505 --backmerge --note "hotfix note" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ (d) --backmerge 全程綠 → exit 0"; else echo "✗ (d) 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
has '(d) 有開 back-merge PR（head=main base=development）' "$(cat "$GH_LOG")" 'pr create --head main --base development'
has '(d) 有呼叫 pr-body-check --branch main' "$(cat "$PR_BODY_CHECK_LOG")" '--branch main'
has '(d) 有記 pr-body-check exit 2 不擋的說明' "$out" 'pr-body-check --branch main exit 2'
has '(d) 有呼叫 gh pr merge 601 --merge（back-merge PR）' "$(cat "$GH_LOG")" 'pr merge 601 --merge'
has '(d) 主 PR 505 也被 merge' "$(cat "$GH_LOG")" 'pr merge 505 --merge'
lines_status=$(wc -l < "$POST_STATUS_LOG" | tr -d ' ')
if [ "$lines_status" -eq 2 ]; then echo "✓ (d) post-status 貼了兩次（main tip、development tip）"; else echo "✗ (d) post-status 應貼兩次（實得 ${lines_status}）" >&2; cat "$POST_STATUS_LOG" >&2; fail=1; fi
has '(d) back-merge status desc 提到 back-merge main→development' "$(cat "$POST_STATUS_LOG")" 'back-merge main→development'
has '(d) 摘要印 back-merge 完成' "$out" '✓ back-merge #601 → development'

# ---- (d2) --backmerge 續接：head=main base=development 已有 open PR → 沿用、不重開 ----
reset_all
out="$(GH_PR_VIEW_SEQUENCE="$v_open $v_open $v_clean $v_after $bm_open $bm_clean $bm_after" \
      GH_PR_CHECKS_SEQUENCE="$c_pass" \
      GH_PR_LIST_JSON="$(fx d2-pr-list '[{"number":602}]')" \
      bash "$script" 505 --backmerge --note "hotfix note" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ (d2) 沿用既有 back-merge PR → exit 0"; else echo "✗ (d2) 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
if grep -q '^pr create' "$GH_LOG"; then echo "✗ (d2) 不應重開 back-merge PR（應沿用 #602）" >&2; fail=1; else echo "✓ (d2) 不重開 back-merge PR"; fi
has '(d2) 沿用 #602 併入' "$(cat "$GH_LOG")" 'pr merge 602 --merge'
has '(d2) 摘要印沿用既有 PR' "$out" '沿用既有 back-merge PR #602'

# ---- (e) --then-promote：兩支併入完成後 exec promote-follow.sh ----
reset_all
out="$(GH_PR_VIEW_SEQUENCE="$v_open $v_open $v_clean $v_after" GH_PR_CHECKS_SEQUENCE="$c_pass" \
      bash "$script" 506 --note x --then-promote development test 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "✓ (e) --then-promote → exit 0（假 promote-follow.sh 回 0）"; else echo "✗ (e) 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
has '(e) 有呼叫 promote-follow.sh development test' "$(cat "$PROMOTE_FOLLOW_LOG")" 'development test'

if [ "$fail" -eq 0 ]; then
  echo "✓ merge-follow.test.sh 全部通過"
else
  echo "✗ merge-follow.test.sh 有案例失敗" >&2
fi
exit "$fail"
