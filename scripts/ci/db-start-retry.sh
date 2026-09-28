#!/bin/bash
# db-start-retry.sh — CI `db` job 的 `supabase db start` 包一層映像限流重試（LS-351 追加；LS-354 池項 76ed9a99；LS-392 加長退避）。
#
# 來源：PR #519 的 `db` job 連四次（run 35897884534 attempt 1–4，含 20 分鐘退避後 rerun）撞
# `failed to pull docker image from all registries: ghcr.io/supabase/postgres … toomanyrequests`，擋住併入。
# ci.yml 在這一步之前把 SUPABASE_INTERNAL_IMAGE_REGISTRY 改成 public.ecr.aws（改拉 Supabase 官方 ECR Public 鏡像，
# 避開 ghcr 共享出口限流）；docker login ghcr.io 對 CLI 內部 pull 無效（run 35904976443 Login Succeeded 仍撞限流，
# 反證），不再使用。限流時這支再退避重試。
# LS-392：ECR Public 匿名拉取另有資料量上限（09-28 一日三次 `toomanyrequests: Data limit exceeded`，3 次重試全紅）——
# ci.yml 改為先由 actions/cache 載入映像（scripts/ci/db-image-cache.sh），這支的退避同時拉長為 4 次重試。
#
# 行為：跑 `supabase db start`；失敗且輸出含 `toomanyrequests` 才重試，最多 4 次（共 5 次嘗試）、間隔 30／60／120／240 秒，
# 每次重試前印「→ 映像限流（toomanyrequests），第 n 次重試」；其他錯誤原樣立即失敗（exit code 不改寫）。重試用盡仍限流
# → 印 ✗ 與一行「⚠ db-start-retry：疑似映像限流（toomanyrequests）…」（patrol.sh 近 7 日同類紅段以這行當簽章計數），
# 並以最後一次的 exit code 結束。成功時印「映像來源」一行：這次 db start 有沒有從 registry 拉映像（cache hit 應為未拉取）。
# 只給 CI runner（本機容器是所有 worktree 共用的，起停要經 supabase-lock，LS-70／LS-184）；本機自測以
# LS_DB_START_RETRY_ALLOW_LOCAL=1 明示放行。DB_START_RETRY_BACKOFF（逗號分隔秒數）可覆寫間隔，供自測用。
# 自測：scripts/ci/db-start-retry.test.sh（PATH 前置假 supabase／sleep，掛 CI rules job）。
set -uo pipefail

if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] && [ "${LS_DB_START_RETRY_ALLOW_LOCAL:-}" != 1 ]; then
  echo "✗ db-start-retry：只給 CI runner；本機請用 bash scripts/ops/supabase-lock.sh -- supabase db start（明示放行：LS_DB_START_RETRY_ALLOW_LOCAL=1）" >&2
  exit 2
fi

RATE_LIMIT='toomanyrequests'
IFS=',' read -r -a backoff <<< "${DB_START_RETRY_BACKOFF:-30,60,120,240}"
registry=${SUPABASE_INTERNAL_IMAGE_REGISTRY:-（未設，CLI 預設）}

log=$(mktemp) || { echo "✗ db-start-retry：mktemp 失敗" >&2; exit 2; }
trap 'rm -f "$log"' EXIT

pulled=0   # 任一次嘗試出現 docker pull 進度（`Pulling from`）即記下——$log 每次嘗試會被覆寫
run_start() {
  supabase db start 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  grep -qF -- 'Pulling from' "$log" && pulled=1
  return "$rc"
}

echo "db-start-retry：SUPABASE_INTERNAL_IMAGE_REGISTRY=${registry}"
run_start; rc=$?
attempt=0
while [ "$rc" -ne 0 ]; do
  if ! grep -qF -- "$RATE_LIMIT" "$log"; then
    echo "✗ db-start-retry：supabase db start 失敗（exit ${rc}）且不是映像限流——不重試，錯誤見上" >&2
    exit "$rc"
  fi
  if [ "$attempt" -ge "${#backoff[@]}" ]; then
    echo "✗ db-start-retry：映像限流，重試 ${attempt} 次後 supabase db start 仍失敗（exit ${rc}）" >&2
    echo "⚠ db-start-retry：疑似映像限流（toomanyrequests）——registry ${registry}，退避 ${DB_START_RETRY_BACKOFF:-30,60,120,240} 秒用盡；查映像快取是否命中（LS-392）" >&2   # DB-START-LIMIT-WARN
    exit "$rc"
  fi
  attempt=$((attempt + 1))
  echo "→ 映像限流（toomanyrequests），第 ${attempt} 次重試（${backoff[$((attempt - 1))]} 秒後）"
  sleep "${backoff[$((attempt - 1))]}"   # DB-START-BACKOFF
  run_start; rc=$?
done
if [ "$pulled" -eq 1 ]; then
  echo "db-start-retry：映像來源＝${registry}（本次 db start 有拉取映像）"
else
  echo "db-start-retry：映像來源＝本機既有映像（本次 db start 未拉取任何映像）"
fi
exit 0
