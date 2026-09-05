#!/bin/bash
# CI `db` job 的 `supabase db reset` 包裝：54322 port 綁定競態重試一次（LS-186；來源 LS-96 池項 305a9279／LS-184 CI 查因 b8b4e7f1）。
#
# 症狀：`.github/workflows/ci.yml` db job 在 `supabase db start` 之後裸跑 `supabase db reset`，reset 重建 db 容器時 runner 的 docker
#   對 54322 的舊綁定偶爾尚未釋放 → 「failed to bind host port for 0.0.0.0:54322:… address already in use」→「failed to start
#   containers」（run 33934840343），`gh run rerun --failed` 即綠——純 docker networking 競態，與 diff 無關。
# 做法：先跑一次 `supabase db reset`（stdout／stderr 原樣串流到 CI log、同時側錄到暫存檔）。**只有**失敗且輸出含
#   `address already in use` 時才重試、且只重試一次：`supabase stop --no-backup || true`（把半掛的容器連同綁定一起拆掉；stop 失敗不影響）
#   → `sleep 10`（等 docker 釋放 port）→ `supabase db start`（reset 的前置是 db 容器在——CLI 先 AssertSupabaseDbIsRunning，容器被
#   stop 拆掉後不重起就會紅在「supabase start is not running」）→ `supabase db reset`。其他錯誤不重試、以原 exit code 結束（錯誤已
#   原樣印出）；重試仍失敗也以其 exit code 結束、不再重試。
# 與票文的差異（reviewer 請覆核）：票文寫「reset 前先 `supabase stop --no-backup || true`」——不採為第一步：前一步 `supabase db start`
#   剛把 db 起好，無條件先 stop 會讓每一次 reset 都紅在「not running」（非 port 錯誤、不會走重試），等於把 db job 打死；stop 只放在
#   重試路徑清失敗殘留。sleep 10／只重試一次／其他錯誤不重試皆照票文。
# 用法：bash scripts/ci/db-reset-retry.sh（cwd＝repo root，與 ci.yml 其他步驟相同；step 名稱不變）。自測 db-reset-retry.test.sh 以
#   PATH 前置的假 `supabase`／`sleep` 驗呼叫序列與 exit code，不碰真容器。**本機不要裸跑這支**——本機容器一律經
#   `scripts/ops/supabase-lock.sh -- <命令>`（COLLABORATION §6 LS-70；PreToolUse H3／H3b 也會擋）。
# exit：0＝reset 成功（首次或重試）；非 0＝reset／db start 的原 exit code；2＝mktemp 失敗。
set -uo pipefail

PORT_RACE='address already in use'

# 串流＋側錄；回傳 reset 自己的 exit code（不是 tee 的）
run_reset() {
  supabase db reset 2>&1 | tee "$1"
  return "${PIPESTATUS[0]}"
}

log=$(mktemp) || { echo "✗ db-reset-retry：mktemp 失敗" >&2; exit 2; }
trap 'rm -f "$log"' EXIT

run_reset "$log"; rc=$?
if [ "$rc" -eq 0 ]; then
  exit 0
fi
if ! grep -qF -- "$PORT_RACE" "$log"; then
  echo "✗ db-reset-retry：supabase db reset 失敗（exit ${rc}）且不是 54322 port 綁定競態——不重試，錯誤見上（LS-186）" >&2
  exit "$rc"
fi
echo "db-reset-retry：偵測到「${PORT_RACE}」（54322 port 綁定競態，LS-96 305a9279）——supabase stop --no-backup → sleep 10 → supabase db start → 重試一次 supabase db reset"
supabase stop --no-backup || true
sleep 10
# 不用 `if ! cmd; then rc=$?`——`!` 之後 $? 是否定後的 0，原 exit code 會丟（自測 ⑥ 抓到）
supabase db start; rc=$?
if [ "$rc" -ne 0 ]; then
  echo "✗ db-reset-retry：重試前 supabase db start 失敗（exit ${rc}）——不重試 reset（LS-186）" >&2
  exit "$rc"
fi
run_reset "$log"; rc=$?
if [ "$rc" -ne 0 ]; then
  echo "✗ db-reset-retry：重試一次後 supabase db reset 仍失敗（exit ${rc}）——不再重試，請查 runner docker 狀態（LS-186）" >&2
fi
exit "$rc"
