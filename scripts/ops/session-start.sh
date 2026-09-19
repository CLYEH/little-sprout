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

# LS-209（push 韌性）：pre-push hook 跑 push gate 8–10 分鐘期間 SSH 閒置，GitHub 會斷線（LS-191 R4 三次 push 才成功；
# push-gate.sh 檔頭同一則說明）。設 repo 層 `git config core.sshCommand`（帶 keepalive），不改使用者全域
# `~/.gitconfig`。`core.*` 這類設定在本 repo（`extensions.worktreeConfig` 未開）是**全 repo 共用**的單一
# `.git/config`——從任一 worktree 執行 `git config` 寫的就是同一份檔案，對主 checkout 與所有現存、未來的
# worktree 立即生效，不需要另外掛「建立 worktree 時的包裝」（實測見 handoff）。這裡每次 SessionStart 冪等
# 檢查一次：已是目標值就跳過、不重複寫入；設定失敗只印警告、不擋 session（fail-soft，同本檔其餘邏輯一致）。
# LS-333 R2（源自 LS-313 R2／R3，池項 f99a2749；merge-review R1 m1 訂正）：`ServerAliveCountMax` 只計算「送出
# keepalive 後伺服器沒回應」的次數、一收到回覆就歸零——實測（`GIT_TRACE=1 git ls-remote` 對 GitHub 開連線閒置
# 12 秒）證明 GitHub 每次都正常回應 keepalive（type 81 REQUEST_SUCCESS），連 CountMax=1 都不會斷線。LS-313
# R2／R3 的 `Connection reset by peer` 是在 keepalive 正常往返的情況下被對端重置，**不是** CountMax 不夠大——
# 拉高這個值對那次斷線沒有作用（PLAUSIBLE：GitHub 對 receive-pack 的閒置等待時間本身有上限）。真正有效的修法
# 是 ios-dev.md 的規約 (a)：push 前先跑 push-gate.sh 暖 tree-hash 快取，讓 `git push` 觸發的 pre-push hook 只是
# 重放快取、秒過，把 SSH 連線閒置的時間從 20–40 分鐘收斂到幾秒。這裡把 CountMax 由 20 拉高到 120 純粹當「伺服器
# 真的不回應 keepalive」時的第二道防線（如：對端行程掛掉、極端網路狀況）——`ServerAliveInterval=30` 仍保留，
# 用來防 NAT／中間設備對閒置連線的斷線，與 GitHub 端主動 reset 是兩回事。`scripts/ops/patrol.sh` 對這個值另有
# 機械檢查（同 core.hooksPath 慣例），兩處常數各自一份，改這裡務必同步改那邊。
ssh_note=
# LS209-SSH-KEEPALIVE-START
SSH_KEEPALIVE_CMD='ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=120'
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  cur_ssh_cmd=$(git -C "$root" config --get core.sshCommand 2>/dev/null || true)
  if [ "$cur_ssh_cmd" != "$SSH_KEEPALIVE_CMD" ]; then
    if git -C "$root" config core.sshCommand "$SSH_KEEPALIVE_CMD" 2>/dev/null; then
      ssh_note="✓ 已設定 git core.sshCommand（SSH keepalive：ServerAliveInterval=30／ServerAliveCountMax=120）——push gate 執行期間 SSH 閒置不再被斷線（LS-191／LS-209／LS-333）。"
    else
      ssh_note="⚠ 無法設定 git core.sshCommand（SSH keepalive）——push gate 執行期間可能因 SSH 閒置斷線，需要時手動 \`git config core.sshCommand \"${SSH_KEEPALIVE_CMD}\"\`（LS-191）。"
    fi
  fi
fi
# LS209-SSH-KEEPALIVE-END

# LS-311：statusline-command.sh 若沒掛用量快取寫入段（grep 不到 usage-cache 字面），巡檢「用量」段讀不到
# <config dir>/usage-cache.json，週用量門檻偵測會退化成「探針無資料」（不擋，但等於這段沒巡到）。這裡只偵測
# 並提示，不代寫、不改 config dir（不是本 repo 管得到的檔案；見硬規則）。config dir 跟本 session 的
# CLAUDE_CONFIG_DIR 走（多帳號各自一份；LS-314），未設才退回 ~/.claude。
usage_snippet_note=
usage_cfg_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
statusline_sh="${usage_cfg_dir}/statusline-command.sh"
if [ ! -f "$statusline_sh" ] || ! grep -q 'usage-cache' "$statusline_sh" 2>/dev/null; then
  usage_snippet_note="⚠ ${usage_cfg_dir}/statusline-command.sh 未掛用量快取寫入段——巡檢「用量」段讀不到 ${usage_cfg_dir}/usage-cache.json，週用量門檻偵測會印「探針無資料」（不擋，但等於沒巡到）。安裝方式見 scripts/ops/usage-cache-snippet.sh 檔頭（LS-311）。"
fi

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
[ -n "$ssh_note" ] && ctx="${ctx}${ssh_note}"$'\n'
[ -n "$usage_snippet_note" ] && ctx="${ctx}${usage_snippet_note}"$'\n'
ctx="${ctx}先 CronList 確認本 session 是否已有巡檢 cron（compact／resume 後 session 仍在，cron 不會消失），沒有才用 CronCreate 建 \`*/26 * * * *\`（模板見 docs/COLLABORATION.md §4-b）；已有就不要重建。"
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$(json_str "$ctx")"
printed=1
exit 0
