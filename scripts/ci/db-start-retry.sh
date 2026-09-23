#!/bin/bash
# db-start-retry.sh — CI `db` job 的 `supabase db start` 包一層 ghcr 限流重試（LS-351 追加；LS-354 池項 76ed9a99）。
#
# 來源：PR #519 的 `db` job 連四次（run 35897884534 attempt 1–4，含 20 分鐘退避後 rerun）撞
# `failed to pull docker image from all registries: ghcr.io/supabase/postgres … toomanyrequests`，擋住併入。
# ci.yml 在這一步之前先 `docker login ghcr.io`（GITHUB_TOKEN，認證後限流額度遠高於匿名）；這支再補退避重試。
#
# 行為：跑 `supabase db start`；失敗且輸出含 `toomanyrequests` 才重試，最多 3 次、間隔 30／60／120 秒，每次重試前印
# 「→ ghcr 限流，第 n 次重試」；其他錯誤原樣立即失敗（exit code 不改寫）。3 次重試後仍限流 → 印 ✗ 並以最後一次的
# exit code 結束。
# 只給 CI runner（本機容器是所有 worktree 共用的，起停要經 supabase-lock，LS-70／LS-184）；本機自測以
# LS_DB_START_RETRY_ALLOW_LOCAL=1 明示放行。DB_START_RETRY_BACKOFF（逗號分隔秒數）可覆寫間隔，供自測用。
# 自測：scripts/ci/db-start-retry.test.sh（PATH 前置假 supabase／sleep，掛 CI rules job）。
set -uo pipefail

if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] && [ "${LS_DB_START_RETRY_ALLOW_LOCAL:-}" != 1 ]; then
  echo "✗ db-start-retry：只給 CI runner；本機請用 bash scripts/ops/supabase-lock.sh -- supabase db start（明示放行：LS_DB_START_RETRY_ALLOW_LOCAL=1）" >&2
  exit 2
fi

RATE_LIMIT='toomanyrequests'
IFS=',' read -r -a backoff <<< "${DB_START_RETRY_BACKOFF:-30,60,120}"

log=$(mktemp) || { echo "✗ db-start-retry：mktemp 失敗" >&2; exit 2; }
trap 'rm -f "$log"' EXIT

run_start() {
  supabase db start 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}

run_start; rc=$?
attempt=0
while [ "$rc" -ne 0 ]; do
  if ! grep -qF -- "$RATE_LIMIT" "$log"; then
    echo "✗ db-start-retry：supabase db start 失敗（exit ${rc}）且不是 ghcr 限流——不重試，錯誤見上" >&2
    exit "$rc"
  fi
  if [ "$attempt" -ge "${#backoff[@]}" ]; then
    echo "✗ db-start-retry：ghcr 限流，重試 ${attempt} 次後 supabase db start 仍失敗（exit ${rc}）" >&2
    exit "$rc"
  fi
  attempt=$((attempt + 1))
  echo "→ ghcr 限流，第 ${attempt} 次重試（${backoff[$((attempt - 1))]} 秒後）"
  sleep "${backoff[$((attempt - 1))]}"
  run_start; rc=$?
done
exit 0
