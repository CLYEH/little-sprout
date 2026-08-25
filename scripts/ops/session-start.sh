#!/bin/bash
# SessionStart hook（LS-71）：session startup／resume／clear／compact 後跑巡檢，把摘要與兩條指示注入 context。
# 掛在專案層 .claude/settings.json（入版控；與使用者層的 SessionStart hook 並存、不覆蓋）。規約 docs/COLLABORATION.md §4-b。
# 輸出（stdout）：{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}}；不讀 stdin。
# fail-soft：patrol 失敗／repo 找不到／本檔任何內部錯誤都仍輸出合法 JSON 且 exit 0——巡檢壞了不能擋 session，
# 但錯誤要寫進 context（fail loud 在訊息、不在 exit code）。
# 環境：CLAUDE_PROJECT_DIR（Claude Code 注入的專案根；沒有就用 cwd）、PATROL_STALE（停滯分鐘，預設 45）。
# 驗法（update-config skill 的 pipe-test）：echo '{}' | bash scripts/ops/session-start.sh | jq -e '.hookSpecificOutput.additionalContext'
# 注意：改 .claude/settings.json 後 settings watcher 要 /hooks 或重啟 session 才載入。自測：scripts/ops/patrol.test.sh ⑥⑦⑨。
set -uo pipefail
cat >/dev/null 2>&1 || true   # 吞掉 hook 的 stdin payload（本 hook 用不到）

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
stale="${PATROL_STALE:-45}"
printed=0
# 任何沒預期到的中途死亡（set -u 撞到未定義變數之類）都由 EXIT trap 補一份合法 JSON，且 exit 0
fallback() {
  [ "$printed" -eq 1 ] || printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"⚠ 巡檢 hook 內部錯誤（scripts/ops/session-start.sh），本次略過；請手動跑 bash scripts/ops/patrol.sh，並依 docs/COLLABORATION.md §4-b 建巡檢 cron。"}}'
  exit 0
}
trap fallback EXIT

json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}
  printf '"%s"' "$s"
}

out=$(bash "${here}/patrol.sh" --brief --repo "$root" "$stale" 2>&1); rc=$?
ctx="## 巡檢（SessionStart hook → scripts/ops/patrol.sh --brief；規約 docs/COLLABORATION.md §4-b）"$'\n'
if [ "$rc" -ne 0 ]; then
  ctx="${ctx}⚠ 巡檢腳本失敗（exit ${rc}），本次略過，請手動跑 bash scripts/ops/patrol.sh 看原因："$'\n'
fi
ctx="${ctx}${out}"$'\n\n'
if printf '%s' "$out" | grep -q '主 checkout 落後 origin/main'; then
  ctx="${ctx}⚠ 主 checkout 落後 origin/main：先 \`git pull --ff-only origin main\` 再派工（agent 定義與 harness 讀自主 checkout，COLLABORATION §2）。"$'\n'
fi
if printf '%s' "$out" | grep -q '^\[hooks\]'; then
  ctx="${ctx}⚠ gate hooks 未裝好（上列 [hooks] 行）：本機 commit／push gate 靜默不跑、只剩 CI 攔——先照指示修（\`git config core.hooksPath .githooks\`／\`chmod +x .githooks/*\`）再 commit／push 或派工（COLLABORATION §2，LS-87）。"$'\n'
fi
ctx="${ctx}若本 session 尚未建立巡檢 cron，立即用 CronCreate 建 \`*/26 * * * *\`，prompt 模板見 docs/COLLABORATION.md §4-b。"
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$(json_str "$ctx")"
printed=1
exit 0
