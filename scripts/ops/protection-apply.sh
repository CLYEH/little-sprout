#!/bin/bash
# 分支保護套用（LS-85 G1）：test／main 改成「required status checks＋禁 force push／刪除＋enforce_admins」、關閉 require PR——
# 晉升改 fast-forward push（scripts/ops/promote.sh）後，PR 只剩 feature→development 與 hotfix→main；每個進到 test／main 的 SHA
# 仍須四個 check（ci／db／lint／rules）全綠才推得上去（server-side：沒有綠 check 的 SHA 被 GH006 拒收）。development 不動
# （feature 仍走 PR）→ 給 development 直接 exit 2。冪等：重跑結果相同。
#
# 用法：protection-apply.sh <test|main> [--dry-run] [--out <dir>]
#   --dry-run  只 GET 現況＋印將套用的 JSON，不 PUT
#   --out      證據目錄（預設 mktemp -d）：<dir>/protection-<b>-before.json、-request.json、-after.json（套用前後各 GET 一次，附 PR body）
# restrictions（限制推送者）：GitHub 只對 organization repo 開放，本 repo 為 user-owned（PUT 帶 users 會 422）→ 一律 null；
#   「僅使用者本人可推」由 collaborators 清單承載，本腳本印出有 push 權限者供核對。
# required checks 的 app_id 四個都明寫 15368（GitHub Actions）——原設定 lint／rules 為 null（任何 app 都能滿足），四個 check 都只來自
#   Actions，寫死是收緊、不是改變。
# exit 0＝套用且 GET 回讀與預期一致（或 dry-run）；1＝套用後回讀不符；2＝參數／gh／jq 錯誤。規約：docs/COLLABORATION.md §2、§7。
set -uo pipefail

branch=; DRY=0; OUT=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --out) [ -n "${2:-}" ] || { echo "✗ protection-apply：--out 缺值" >&2; exit 2; }; OUT=$2; shift ;;
    -h|--help) echo "用法：protection-apply.sh <test|main> [--dry-run] [--out <dir>]（說明見檔頭）"; exit 0 ;;
    -*) echo "✗ protection-apply：未知參數 $1" >&2; exit 2 ;;
    *) [ -z "$branch" ] || { echo "✗ protection-apply：只接受一個分支（多給了 $1）" >&2; exit 2; }; branch=$1 ;;
  esac
  shift
done
case "$branch" in
  test|main) ;;
  development) echo "✗ protection-apply：development 維持 require PR（feature 仍走 PR），本腳本不動它。" >&2; exit 2 ;;
  *) echo "用法：protection-apply.sh <test|main> [--dry-run] [--out <dir>]" >&2; exit 2 ;;
esac
command -v gh >/dev/null 2>&1 || { echo "✗ protection-apply：需要 gh。" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "✗ protection-apply：需要 jq。" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ protection-apply：請在 repo 內執行（gh 由 origin 推 {owner}/{repo}）。" >&2; exit 2; }
if [ -z "$OUT" ]; then OUT=$(mktemp -d) || exit 2; fi
mkdir -p "$OUT" || exit 2

EP="repos/{owner}/{repo}/branches/${branch}/protection"
before="$OUT/protection-${branch}-before.json"
request="$OUT/protection-${branch}-request.json"
after="$OUT/protection-${branch}-after.json"

summary() {  # 一行摘要：require_pr／checks／enforce_admins／force_push／deletions／linear／restrictions
  jq -r '"require_pr=\(.required_pull_request_reviews != null) checks=\([.required_status_checks.checks[]? | "\(.context)@\(.app_id // "any")"] | join(",")) strict=\(.required_status_checks.strict) enforce_admins=\(.enforce_admins.enabled) force_push=\(.allow_force_pushes.enabled) deletions=\(.allow_deletions.enabled) linear_history=\(.required_linear_history.enabled) restrictions=\(.restrictions != null)"' "$1"
}
verify() {  # 回讀是否等於目標狀態
  jq -e '(.required_pull_request_reviews == null)
    and .enforce_admins.enabled
    and (.allow_force_pushes.enabled | not)
    and (.allow_deletions.enabled | not)
    and (.required_linear_history.enabled | not)
    and (.required_status_checks.strict | not)
    and ([.required_status_checks.checks[].context] | sort == ["ci","db","lint","rules"])
    and ([.required_status_checks.checks[].app_id] | all(. == 15368))
    and (.restrictions == null)' "$1" >/dev/null
}

gh api "$EP" > "$before" || { echo "✗ protection-apply：GET ${EP} 失敗（未登入？分支沒有保護規則？）" >&2; exit 2; }
echo "== branch protection ${branch}"
echo "  before: $(summary "$before")"

cat > "$request" <<'EOF'
{
  "required_status_checks": {
    "strict": false,
    "checks": [
      {"context": "ci",    "app_id": 15368},
      {"context": "db",    "app_id": 15368},
      {"context": "lint",  "app_id": 15368},
      {"context": "rules", "app_id": 15368}
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
EOF
echo "  request: PUT ${EP}"
sed 's/^/    /' "$request"
echo "  可推送者（collaborators 有 push 權限；user-owned repo 無 restrictions 可設）："
gh api "repos/{owner}/{repo}/collaborators" --jq '.[] | select(.permissions.push) | "    \(.login) admin=\(.permissions.admin)"' 2>/dev/null || echo "    （collaborators 讀取失敗）"

if verify "$before"; then echo "  現況已等於目標（冪等：重跑不改變）"; fi
if [ "$DRY" -eq 1 ]; then
  echo "  --dry-run：未套用。證據：${before}、${request}"
  exit 0
fi

gh api -X PUT "$EP" --input "$request" > "$OUT/protection-${branch}-put-response.json" || {
  echo "✗ protection-apply：PUT ${EP} 失敗（回應見 ${OUT}/protection-${branch}-put-response.json）。若是 auto-mode 分類器擋住，交 orchestrator 執行本指令。" >&2
  exit 2
}
gh api "$EP" > "$after" || { echo "✗ protection-apply：套用後 GET 失敗。" >&2; exit 2; }
echo "  after:  $(summary "$after")"
if verify "$after"; then
  echo "✓ ${branch} 分支保護已套用並回讀一致。證據：${before}、${request}、${after}"
  exit 0
fi
echo "✗ protection-apply：套用後回讀與目標不符（見 ${after}）。" >&2
exit 1
