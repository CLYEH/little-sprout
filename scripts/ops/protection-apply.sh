#!/bin/bash
# 分支保護套用（LS-85 G1／LS-87 G1）：test／main 改成「required status checks＋禁 force push／刪除＋enforce_admins」、關閉 require PR——
# 晉升改 fast-forward push（scripts/ops/promote.sh）後，PR 只剩 feature→development 與 hotfix→main；每個進到 test／main 的 SHA
# 仍須四個 check（ci／db／lint／rules）全綠才推得上去（server-side：沒有綠 check 的 SHA 被 GH006 拒收）。
# LS-87：required checks 再加 commit status context `merge-review`（merge-reviewer 以 scripts/ops/post-status.sh 用 gh 使用者 token 貼，
# 不是 GitHub Actions → app_id -1＝任何來源皆可；GitHub required status checks 可混用 check-run 與 status context）——沒有
# merge-review success 的 head 併不進 development／main（gh pr merge 被拒）、沒有的 SHA 推不上 test／main（GH006）；head 再 push
# 舊 status 不隨新 SHA 走＝自動要求重審。development 只 PATCH required_status_checks（require PR 與其餘設定不動）。
# 冪等：重跑結果相同。
#
# 用法：protection-apply.sh <development|test|main> [--dry-run] [--out <dir>]
#   --dry-run  只 GET 現況＋印將套用的 JSON，不 PUT／PATCH
#   --out      證據目錄（預設 mktemp -d）：<dir>/protection-<b>-before.json、-request.json、-after.json（套用前後各 GET 一次，附 PR body）
# 套用時機：merge-review 列為 required 後，所有 open PR 的 head 立刻需要 status——先把在飛的 PR 併完（或逐一補貼）再套，
#   否則全部卡住（LS-87：實際套用由 orchestrator 在 back-merge PR 併入後執行）。
# restrictions（限制推送者）：GitHub 只對 organization repo 開放，本 repo 為 user-owned（PUT 帶 users 會 422）→ 一律 null；
#   「僅使用者本人可推」由 collaborators 清單承載，本腳本印出有 push 權限者供核對。
# required checks 的 app_id：test／main 四個都明寫 15368（GitHub Actions；現況已是）；merge-review 寫 -1（顯式「任何 app」——省略時
#   GitHub 會自動綁最近貼過的 app，狀態靠人貼、沒有 app）。development 只加 merge-review，其餘 check 的 context／app_id 照 GET 回來的
#   原樣送回（null 以同義的 -1 送出；省略反而會被自動綁 Actions）——票文 G1 只要求加 merge-review，不順手把 development 的
#   lint／rules 從 any 收緊成 15368（R2 M2）。
# exit 0＝套用且 GET 回讀與預期一致（或 dry-run）；1＝套用後回讀不符；2＝參數／gh／jq 錯誤。規約：docs/COLLABORATION.md §2、§7。
set -uo pipefail

branch=; DRY=0; OUT=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --out) [ -n "${2:-}" ] || { echo "✗ protection-apply：--out 缺值" >&2; exit 2; }; OUT=$2; shift ;;
    -h|--help) echo "用法：protection-apply.sh <development|test|main> [--dry-run] [--out <dir>]（說明見檔頭）"; exit 0 ;;
    -*) echo "✗ protection-apply：未知參數 $1" >&2; exit 2 ;;
    *) [ -z "$branch" ] || { echo "✗ protection-apply：只接受一個分支（多給了 $1）" >&2; exit 2; }; branch=$1 ;;
  esac
  shift
done
case "$branch" in
  test|main) MODE=put ;;        # 整份 PUT …/protection（關 require PR、enforce_admins、禁 force push／刪除）
  development) MODE=patch ;;    # 只 PATCH …/protection/required_status_checks（require PR 維持——feature 仍走 PR）
  *) echo "用法：protection-apply.sh <development|test|main> [--dry-run] [--out <dir>]" >&2; exit 2 ;;
esac
command -v gh >/dev/null 2>&1 || { echo "✗ protection-apply：需要 gh。" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "✗ protection-apply：需要 jq。" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ protection-apply：請在 repo 內執行（gh 由 origin 推 {owner}/{repo}）。" >&2; exit 2; }
if [ -z "$OUT" ]; then OUT=$(mktemp -d) || exit 2; fi
mkdir -p "$OUT" || exit 2

EP="repos/{owner}/{repo}/branches/${branch}/protection"
EP_CHECKS="${EP}/required_status_checks"
before="$OUT/protection-${branch}-before.json"
request="$OUT/protection-${branch}-request.json"
after="$OUT/protection-${branch}-after.json"

summary() {  # 一行摘要：require_pr／checks／enforce_admins／force_push／deletions／linear／restrictions
  jq -r '"require_pr=\(.required_pull_request_reviews != null) checks=\([.required_status_checks.checks[]? | "\(.context)@\(if .app_id == null or .app_id == -1 then "any" else .app_id end)"] | join(",")) strict=\(.required_status_checks.strict) enforce_admins=\(.enforce_admins.enabled) force_push=\(.allow_force_pushes.enabled) deletions=\(.allow_deletions.enabled) linear_history=\(.required_linear_history.enabled) restrictions=\(.restrictions != null)"' "$1"
}
# 目標狀態：merge-review@any（GET 回讀 -1 或 null 都算「任何 app」）＋五個 context 齊。test／main：四個 Actions check@15368，另驗
# require PR 關、enforce_admins、禁 force push／刪除；development：其餘四個 check 的 context／app_id 與 before 相同（只加 merge-review）
# ＋require PR 仍開（其餘欄位本腳本不動）
CHECKS_OK='(.required_status_checks.strict | not)
    and ([.required_status_checks.checks[].context] | sort == ["ci","db","lint","merge-review","rules"])
    and ([.required_status_checks.checks[] | select(.context != "merge-review") | .app_id] | all(. == 15368))
    and ([.required_status_checks.checks[] | select(.context == "merge-review") | .app_id] | all(. == null or . == -1))'
verify() {  # 回讀是否等於目標狀態
  case "$MODE" in
    put) jq -e "(.required_pull_request_reviews == null)
      and .enforce_admins.enabled
      and (.allow_force_pushes.enabled | not)
      and (.allow_deletions.enabled | not)
      and (.required_linear_history.enabled | not)
      and ${CHECKS_OK}
      and (.restrictions == null)" "$1" >/dev/null ;;
    patch) jq -e --slurpfile b "$before" '
      def others: [.required_status_checks.checks[] | select(.context != "merge-review") | {context, app_id: (.app_id // -1)}] | sort_by(.context);
      (.required_pull_request_reviews != null)
      and (.required_status_checks.strict | not)
      and ([.required_status_checks.checks[].context] | sort == ["ci","db","lint","merge-review","rules"])
      and ([.required_status_checks.checks[] | select(.context == "merge-review") | .app_id] | all(. == null or . == -1))
      and (others == ($b[0] | others))' "$1" >/dev/null ;;
  esac
}

gh api "$EP" > "$before" || { echo "✗ protection-apply：GET ${EP} 失敗（未登入？分支沒有保護規則？）" >&2; exit 2; }
echo "== branch protection ${branch}"
echo "  before: $(summary "$before")"

# test／main（PUT）的 checks 段；development 不用這份——由 before 產生、只加 merge-review（見 patch）
CHECKS_JSON='{
    "strict": false,
    "checks": [
      {"context": "ci",           "app_id": 15368},
      {"context": "db",           "app_id": 15368},
      {"context": "lint",         "app_id": 15368},
      {"context": "rules",        "app_id": 15368},
      {"context": "merge-review", "app_id": -1}
    ]
  }'
case "$MODE" in
  put)
    cat > "$request" <<EOF
{
  "required_status_checks": ${CHECKS_JSON},
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
    echo "  request: PUT ${EP}" ;;
  patch)
    # 只加 merge-review：其餘 check 照 before 原樣（context／app_id；null→-1 同義「任何 app」），不順手收緊（R2 M2）
    if ! jq '{strict: false, checks: ([.required_status_checks.checks[] | select(.context != "merge-review") | {context, app_id: (.app_id // -1)}] + [{context: "merge-review", app_id: -1}])}' "$before" > "$request"; then
      echo "✗ protection-apply：從 ${before} 產生 request 失敗" >&2; exit 2
    fi
    echo "  request: PATCH ${EP_CHECKS}（只加 merge-review；其餘 check 照現況、require PR 等其餘設定不動）" ;;
esac
sed 's/^/    /' "$request"
echo "  可推送者（collaborators 有 push 權限；user-owned repo 無 restrictions 可設）："
gh api "repos/{owner}/{repo}/collaborators" --jq '.[] | select(.permissions.push) | "    \(.login) admin=\(.permissions.admin)"' 2>/dev/null || echo "    （collaborators 讀取失敗）"

if verify "$before"; then echo "  現況已等於目標（冪等：重跑不改變）"; fi
if [ "$DRY" -eq 1 ]; then
  echo "  --dry-run：未套用。證據：${before}、${request}"
  exit 0
fi

case "$MODE" in
  put) gh api -X PUT "$EP" --input "$request" > "$OUT/protection-${branch}-put-response.json" ;;
  patch) gh api -X PATCH "$EP_CHECKS" --input "$request" > "$OUT/protection-${branch}-put-response.json" ;;
esac || {
  echo "✗ protection-apply：${MODE} ${EP} 失敗（回應見 ${OUT}/protection-${branch}-put-response.json）。若是 auto-mode 分類器擋住，交 orchestrator 執行本指令。" >&2
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
